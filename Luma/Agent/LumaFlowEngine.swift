//
//  LumaFlowEngine.swift
//  leanring-buddy
//
//  Orchestrates a LumaFlow automation session. On entry it makes an upfront
//  planning call (rough step plan + estimated duration + required apps + warnings),
//  then runs an execution loop that:
//    1. Marks the step in-progress in the bubble
//    2. Makes a per-step dynamic replan call to get the exact action
//    3. Executes the action via LumaFlowActions
//    4. Observes the result (AX check + screenshot diff, up to 10s)
//    5. Decides: continue / retry / adapt / ask user / abort
//    6. Updates the step state
//
//  Called by CompanionManager when LumaIntentClassifier returns .visualAgent.
//
//  AX observation cache: 300ms validity between reads.
//  Screenshot diff:      200×150 px thumbnail hash.
//  Planning API call:    max_tokens 400, timeout 5s.
//  Replan API call:      max_tokens 200, timeout 3s.
//

import AppKit
import Combine
import Foundation

// MARK: - LumaFlowEngine

@MainActor
final class LumaFlowEngine {

    static let shared = LumaFlowEngine()
    private init() {}

    // MARK: - Active Session State

    private var activeContext: LumaFlowContext?
    private var activeRuntime: LumaFlowRuntime?
    private var activeSessionId: UUID?

    // MARK: - AX Cache

    private var lastAXSummary: String = ""
    private var lastAXReadTime: Date?
    private let axCacheValiditySeconds: Double = 0.3

    // MARK: - Screenshot Diff State

    private var previousScreenshotHash: Int?

    // MARK: - Public Entry Point

    /// Creates an agent session, runs the planning + execution loop, and drives the
    /// dock bubble via LumaFlowRuntime. Called by CompanionManager for `.visualAgent` paths.
    func startFlow(goal: String, companionManager: CompanionManager, isTransient: Bool = false) async {
        let context = LumaFlowContext(goal: goal)
        activeContext = context

        let runtime = LumaFlowRuntime()
        activeRuntime = runtime

        // Create and register the agent session
        let session = AgentSession()
        activeSessionId = session.id
        session.bind(to: runtime)
        session.isTransient = isTransient
        companionManager.agentSessions.append(session)
        companionManager.activeAgentSessionID = session.id
        companionManager.updateAgentDock()

        LumaLogger.log("[LumaFlow] Starting flow for goal: \(goal.prefix(80))")

        // --- Phase 1: Planning ---
        runtime.publishStatus(sessionId: session.id, status: .starting)
        runtime.publishEntry(AgentTranscriptEntry(role: .system, text: "Planning task: \(goal)"))

        guard let plan = await callPlanningAPI(goal: goal) else {
            runtime.publishEntry(AgentTranscriptEntry(role: .system, text: "Planning failed — no API profile configured or call timed out."))
            runtime.publishStatus(sessionId: session.id, status: .failed("Planning failed"))
            return
        }

        // Populate context from plan
        context.roughPlan = plan.steps.map { LumaFlowStep(label: $0) }
        context.estimatedDuration = plan.estimatedDuration
        context.requiresApps = plan.requiresApps
        context.warnings = plan.warnings

        // Emit plan as a plan-role transcript entry so it's visible in the bubble
        let planLines = plan.steps.enumerated().map { i, label in "\(i + 1). \(label)" }
        var planText = planLines.joined(separator: "\n")
        planText += "\n\n⏱ \(plan.estimatedDuration)"
        if !plan.requiresApps.isEmpty { planText += "\n📱 Requires: \(plan.requiresApps.joined(separator: ", "))" }
        runtime.publishEntry(AgentTranscriptEntry(role: .plan, text: planText))

        // Surface warnings
        if !plan.warnings.isEmpty {
            runtime.publishEntry(AgentTranscriptEntry(role: .system, text: "⚠️ " + plan.warnings.joined(separator: " · ")))
        }

        // --- Phase 2: Execution Loop ---
        runtime.publishStatus(sessionId: session.id, status: .running)
        await executeLoop(context: context, sessionId: session.id, runtime: runtime)

        // --- Phase 3: Completion ---
        if context.cancelRequested {
            runtime.publishEntry(AgentTranscriptEntry(role: .assistant, text: "Task cancelled after \(context.completedStepLabels.count) step(s)."))
            runtime.publishStatus(sessionId: session.id, status: .stopped)
        } else {
            let completedCount = context.roughPlan.filter { if case .completed = $0.state { return true }; return false }.count
            let totalCount = context.roughPlan.count
            runtime.publishEntry(AgentTranscriptEntry(
                role: .assistant,
                text: "✅ Done! Completed \(completedCount) of \(totalCount) steps.\n\nGoal: \(goal)"
            ))
            runtime.publishStatus(sessionId: session.id, status: .ready)
        }

        companionManager.updateAgentDock()
        activeContext = nil
        activeRuntime = nil
        activeSessionId = nil
        previousScreenshotHash = nil
    }

    /// Signals the active flow to cancel after the current step finishes.
    func cancelActiveFlow() {
        activeContext?.cancelRequested = true
        LumaLogger.log("[LumaFlow] Cancellation requested")
    }

    /// Returns true if there is a currently running flow session matching the given session ID.
    /// Used by CompanionManager to decide whether bubble follow-up text should be injected
    /// directly into the active flow rather than re-classified as a new task.
    func isFlowActiveForSession(_ sessionID: UUID) -> Bool {
        activeSessionId == sessionID && activeRuntime != nil
    }

    /// Injects a follow-up prompt from the bubble text field directly into the active flow
    /// session's recovery/ask-user loop, bypassing the full classifier pipeline.
    func sendFollowUp(_ prompt: String) {
        activeRuntime?.followUpSubject.send(prompt)
    }

    // MARK: - Execution Loop

    private func executeLoop(
        context: LumaFlowContext,
        sessionId: UUID,
        runtime: LumaFlowRuntime
    ) async {
        for index in context.roughPlan.indices {
            guard !context.cancelRequested else { break }

            context.roughPlan[index].state = .inProgress
            let step = context.roughPlan[index]

            // Emit command entry → drives AgentSession's taskSteps progress bar
            runtime.publishEntry(AgentTranscriptEntry(role: .command, text: "[flow] \(step.label)"))
            LumaLogger.log("[LumaFlow] Step \(index + 1)/\(context.roughPlan.count): \(step.label)")

            // For the very first step, ensure the primary required app is in front.
            // Subsequent app switching is handled by the replan via openApp actions.
            if index == 0, let primaryApp = context.requiresApps.first {
                await switchToApp(primaryApp)
            }

            let result = await executeStepWithRecovery(
                stepIndex: index,
                context: context,
                runtime: runtime
            )

            switch result {
            case .completed(let observation):
                context.roughPlan[index].state = .completed
                context.roughPlan[index].resultObservation = observation
                context.completedStepLabels.append(step.label)
                context.lastObservation = observation
                runtime.publishEntry(AgentTranscriptEntry(role: .assistant, text: "✓ \(step.label)\n\(observation)"))
                LumaLogger.log("[LumaFlow] ✓ Step complete: \(step.label)")

            case .failed(let reason):
                context.roughPlan[index].state = .failed(reason)
                context.lastObservation = "Failed: \(reason)"
                runtime.publishEntry(AgentTranscriptEntry(role: .system, text: "Step failed: \(step.label)\n\(reason)"))
                LumaLogger.log("[LumaFlow] ✗ Step failed: \(step.label) — \(reason)")
                // Non-fatal: continue to next step

            case .aborted(let reason):
                context.roughPlan[index].state = .failed(reason)
                context.lastObservation = "Aborted: \(reason)"
                runtime.publishEntry(AgentTranscriptEntry(role: .system, text: "🛑 Aborted: \(reason)"))
                LumaLogger.log("[LumaFlow] 🛑 Aborted: \(reason)")
                context.cancelRequested = true
                return

            case .waitingForUser(let question):
                context.roughPlan[index].state = .inProgress
                runtime.publishEntry(AgentTranscriptEntry(role: .assistant, text: "❓ \(question)\n\nType your reply in the input field below."))
                LumaLogger.log("[LumaFlow] Asking user: \(question)")
                // Wait up to 120s for user follow-up via the runtime's followUpSubject
                let userReply = await waitForUserReply(runtime: runtime, timeoutSeconds: 120)
                context.lastObservation = "User replied: \(userReply ?? "(no reply, continuing)")"
                // Re-attempt the step with the user's context injected
                // (observation is now updated — next loop iteration picks it up)
                continue
            }
        }
    }

    // MARK: - Step Execution with Recovery

    /// Executes a step by looping micro-actions until Claude returns "done" or a limit is hit.
    ///
    /// Each replan call returns ONE atomic action (click, type, wait, etc.). Claude decides
    /// when the step's full goal is accomplished by returning `{"actionType": "done"}`.
    /// This allows a single step like "Open chat with John" to span multiple sub-actions:
    ///   click search → type "John" → click contact row → click message input → done.
    private func executeStepWithRecovery(
        stepIndex: Int,
        context: LumaFlowContext,
        runtime: LumaFlowRuntime
    ) async -> LumaFlowStepResult {

        /// Maximum number of individual micro-actions allowed within a single step
        /// before declaring the step failed (safety valve against infinite loops).
        let maximumMicroActionsPerStep = 12
        /// Maximum consecutive replan API failures before giving up on the step.
        let maximumConsecutiveReplanFailures = 3

        var microActionCount = 0
        var consecutiveReplanFailureCount = 0

        while microActionCount < maximumMicroActionsPerStep {
            guard !context.cancelRequested else { return .aborted("Cancelled") }

            microActionCount += 1
            context.roughPlan[stepIndex].attemptCount = microActionCount

            // Get the next micro-action from Claude — screenshot + AX tree included in call
            guard let action = await callReplanWithVision(step: context.roughPlan[stepIndex], context: context) else {
                consecutiveReplanFailureCount += 1
                LumaLogger.log("[LumaFlow] Replan failed for '\(context.roughPlan[stepIndex].label)' (failure \(consecutiveReplanFailureCount))")
                if consecutiveReplanFailureCount >= maximumConsecutiveReplanFailures {
                    // Notify the user via voice before giving up so they know what blocked
                    let blockedStepLabel = context.roughPlan[stepIndex].label
                    NativeTTSClient.shared.speak("I'm having trouble with \(blockedStepLabel) — the AI isn't responding. Moving on.")
                    return .failed("Replan API failed \(maximumConsecutiveReplanFailures) consecutive times for '\(blockedStepLabel)'")
                }
                context.lastObservation = "Replan API timed out — retrying"
                continue
            }
            consecutiveReplanFailureCount = 0

            switch action.actionType.lowercased() {
            case "done":
                // Claude signals this step's goal is fully accomplished — move to next step.
                LumaLogger.log("[LumaFlow] Step '\(context.roughPlan[stepIndex].label)' done after \(microActionCount) micro-action(s)")
                return .completed(context.lastObservation)

            case "ask":
                return .waitingForUser(action.askQuestion ?? "What should I do next?")

            case "abort":
                return .aborted(action.abortReason ?? "Claude requested abort")

            default:
                break
            }

            // Execute the micro-action
            do {
                let executionObservation = try await LumaFlowActionExecutor.execute(action)
                context.lastObservation = executionObservation
                LumaLogger.log("[LumaFlow] Micro-action \(microActionCount) '\(action.actionType)': \(executionObservation)")

                // Settle delay: give the UI time to update before re-reading AX tree.
                // 800ms is enough for most native apps; Claude can insert explicit "wait"
                // actions for slow web apps or heavy transitions.
                try? await Task.sleep(nanoseconds: 800_000_000)

                // Invalidate AX cache so next replan sees fresh element state
                lastAXReadTime = nil

                // Update screen-change context so Claude knows if anything happened
                let newHash = captureScreenshotHash()
                context.didLastScreenChange = (newHash != previousScreenshotHash)
                previousScreenshotHash = newHash

            } catch LumaFlowActionError.abortRequested(let reason) {
                return .aborted(reason)
            } catch {
                consecutiveReplanFailureCount += 1
                context.lastObservation = "Action error: \(error.localizedDescription)"
                LumaLogger.log("[LumaFlow] Micro-action error: \(error.localizedDescription)")
                if consecutiveReplanFailureCount >= maximumConsecutiveReplanFailures {
                    // Notify the user via voice so they know what blocked the agent
                    let blockedStepLabel = context.roughPlan[stepIndex].label
                    NativeTTSClient.shared.speak("I couldn't complete \(blockedStepLabel). Moving to the next step.")
                    return .failed("Step '\(blockedStepLabel)' failed: \(error.localizedDescription)")
                }
            }
        }

        return .failed("Step '\(context.roughPlan[stepIndex].label)' exceeded \(maximumMicroActionsPerStep) micro-actions without completing")
    }

    // MARK: - Observation Loop

    /// Polls AX tree + screenshot diff for up to 10 seconds to confirm `expected`.
    private func observeResult(expected: String, context: LumaFlowContext) async -> LumaFlowObservationResult {
        let deadline = Date().addingTimeInterval(10)

        // Capture baseline screenshot hash before polling
        previousScreenshotHash = captureScreenshotHash()

        while Date() < deadline {
            guard !context.cancelRequested else { return .timeout }

            // AX check: look for expected text in the current app's tree
            if !expected.isEmpty && checkAXTreeForText(expected) {
                return .success
            }

            // Screenshot diff: is the screen still changing?
            let newHash = captureScreenshotHash()
            let screenChanged = (newHash != previousScreenshotHash)
            context.didLastScreenChange = screenChanged
            previousScreenshotHash = newHash

            if screenChanged {
                // Screen is updating — poll faster (500ms)
                try? await Task.sleep(nanoseconds: 500_000_000)
            } else {
                // Screen stable — poll slower (1s)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        return .timeout
    }

    // MARK: - AX Tree Checker

    /// Returns true if any visible AX element's text contains the expected string.
    private func checkAXTreeForText(_ expected: String) -> Bool {
        guard !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let lowercased = expected.lowercased()

        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appRoot = AXUIElementCreateApplication(app.processIdentifier)
        return axElementHasText(lowercased, in: appRoot, depth: 0)
    }

    private func axElementHasText(_ text: String, in element: AXUIElement, depth: Int) -> Bool {
        guard depth <= 8 else { return false }

        for attr in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] as [CFString] {
            var ref: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attr, &ref)
            if let str = ref as? String, str.lowercased().contains(text) { return true }
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return false }
        return children.contains { axElementHasText(text, in: $0, depth: depth + 1) }
    }

    // MARK: - AX Summary for Replan Prompt

    private func buildAXSummaryForPrompt() -> String {
        // 300ms cache to avoid redundant tree walks between replan calls
        if let lastTime = lastAXReadTime, Date().timeIntervalSince(lastTime) < axCacheValiditySeconds {
            return lastAXSummary
        }

        guard let app = NSWorkspace.shared.frontmostApplication else { return "(no foreground app)" }
        let appRoot = AXUIElementCreateApplication(app.processIdentifier)
        var elements: [String] = []
        collectAXElements(from: appRoot, into: &elements, depth: 0)

        lastAXSummary = elements.isEmpty ? "(empty tree)" : elements.joined(separator: "\n")
        lastAXReadTime = Date()
        return lastAXSummary
    }

    private func collectAXElements(from element: AXUIElement, into results: inout [String], depth: Int) {
        guard depth <= 6, results.count < 20 else { return }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        let containerRoles: Set<String> = ["AXGroup", "AXScrollArea", "AXWebArea", "AXSplitGroup", "AXToolbar"]
        if !containerRoles.contains(role) {
            for attr in [kAXTitleAttribute, kAXDescriptionAttribute] as [CFString] {
                var ref: CFTypeRef?
                AXUIElementCopyAttributeValue(element, attr, &ref)
                if let label = ref as? String, !label.isEmpty {
                    results.append("\(role): \(label)")
                    break
                }
            }
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        if let children = childrenRef as? [AXUIElement] {
            for child in children { collectAXElements(from: child, into: &results, depth: depth + 1) }
        }
    }

    // MARK: - Screenshot Hash

    /// Captures main display, downsamples to 200×150, returns hash for diff comparison.
    private func captureScreenshotHash() -> Int {
        guard let cgImage = CGDisplayCreateImage(CGMainDisplayID()) else { return 0 }
        // Resize via NSImage
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 200, height: 150))
        guard let tiff = nsImage.tiffRepresentation else { return 0 }
        // Sample every 64th byte for speed
        var hash = 0
        tiff.withUnsafeBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: bytes.count, by: 64) {
                hash = hash &* 31 &+ Int(bytes[i])
            }
        }
        return hash
    }

    // MARK: - App Switching

    private func switchToApp(_ appName: String) async {
        // Try to activate a running instance first
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == appName.lowercased()
        }) {
            runningApp.activate(options: [.activateIgnoringOtherApps])
            LumaLogger.log("[LumaFlow] Activated running app: \(appName)")
        } else {
            // App not running — open it by name
            let appURL = URL(fileURLWithPath: "/Applications/\(appName).app")
            if FileManager.default.fileExists(atPath: appURL.path) {
                NSWorkspace.shared.open(appURL)
                LumaLogger.log("[LumaFlow] Opened app: \(appName)")
            }
        }

        // Wait up to 5s for the app to become frontmost
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.localizedName?.lowercased() == appName.lowercased() { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - User Reply Wait

    /// Waits for a user follow-up prompt from the dock bubble input field.
    private func waitForUserReply(runtime: LumaFlowRuntime, timeoutSeconds: Double) async -> String? {
        await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            var resumed = false

            cancellable = runtime.followUpSubject
                .first()
                .sink { reply in
                    guard !resumed else { return }
                    resumed = true
                    cancellable?.cancel()
                    continuation.resume(returning: reply)
                }

            // Timeout fallback
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard !resumed else { return }
                resumed = true
                cancellable?.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Planning API Call

    private func callPlanningAPI(goal: String) async -> LumaFlowPlan? {
        let systemPrompt = """
        You are Luma Flow, a macOS automation agent. Given a goal, create a rough step plan. \
        Never use emojis. Steps should be short action labels only (3–8 words each).
        Each step may require multiple micro-actions — plan at a logical level, not per-click.
        Respond in JSON only — no extra text:
        {
          "steps": ["Open WhatsApp", "Find John in contacts", "Send message hi"],
          "estimatedDuration": "~30 seconds",
          "requiresApps": ["WhatsApp"],
          "warnings": []
        }
        """
        return await callClaudeForJSON(
            systemPrompt: systemPrompt,
            userMessage: goal,
            maxTokens: 400,
            timeoutSeconds: 5,
            parseAs: LumaFlowPlan.self
        )
    }

    // MARK: - Vision Replan Call (per micro-action)

    /// Calls Claude with a screenshot of the current screen + AX summary + step context.
    /// Returns the next atomic action to execute. Claude can see what's actually on screen,
    /// so it doesn't have to guess — this is what makes the execution reliable.
    private func callReplanWithVision(step: LumaFlowStep, context: LumaFlowContext) async -> LumaFlowActionRequest? {
        guard let profile = ProfileManager.shared.activeProfile,
              let apiKey = ProfileManager.shared.loadActiveAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            LumaLogger.log("[LumaFlow] No API profile — cannot call replan")
            return nil
        }

        let axSummary = buildAXSummaryForPrompt()
        let completedList = context.completedStepLabels.isEmpty ? "none" : context.completedStepLabels.joined(separator: ", ")
        let (appName, windowTitle) = currentAppAndWindow()

        // System prompt: role + JSON schema only. No dynamic context here —
        // all state goes in the user message so there are no conflicting instructions.
        let systemPrompt = """
        You are Luma Flow, a macOS automation agent. You receive a screenshot and current UI state, \
        then output ONE action as JSON. No explanation, no markdown — raw JSON only. Never use emojis.

        Action types: click | clickAt | type | scroll | shortcut | openApp | wait | ask | abort | done
        - done: the current step's goal is fully accomplished, move to next step
        - openApp: open an app by name via NSWorkspace (reliable, never use Spotlight)
        - click: click a UI element by its AX label
        - clickAt: click at fractional screen coordinates (xFraction, yFraction 0.0–1.0, top-left origin).
          USE THIS when click fails or no matching AX element exists — read the position from the screenshot.
          Example: to click the WhatsApp search bar at roughly 50% across, 12% down → xFraction:0.5, yFraction:0.12
        - type: type text into the focused/target field
        - shortcut: press a keyboard shortcut e.g. "Return", "Cmd+Return"
        - wait: pause for waitSeconds (use after openApp or heavy transitions)

        JSON schema (output exactly this, all unused fields null):
        {"actionType":"...","targetElementLabel":null,"targetElementRole":null,"shortcut":null,"typeText":null,"waitSeconds":null,"askQuestion":null,"abortReason":null,"xFraction":null,"yFraction":null,"observation":"what you expect to see after","nextMicroStep":"next action label"}
        """

        // User message: all dynamic context in one place, no duplication
        let userText = """
        GOAL: \(context.goal)
        CURRENT STEP: \(step.label)
        COMPLETED STEPS: \(completedList)
        ACTIVE APP: \(appName) — WINDOW: \(windowTitle)
        LAST ACTION RESULT: \(context.lastObservation)
        SCREEN CHANGED AFTER LAST ACTION: \(context.didLastScreenChange)
        AX ELEMENTS VISIBLE:
        \(axSummary)

        The screenshot shows the current screen. Decide the next single action.
        If the step "\(step.label)" is already done based on what you see, output: {"actionType":"done","observation":"step complete","nextMicroStep":""}
        """

        // Capture screen as JPEG for vision
        let screenshotData = captureScreenshotForVision()

        let cheapModel = Self.cheapModelForProfile(profile)
        let endpointString: String
        let requestBody: [String: Any]

        if profile.provider == .anthropic {
            endpointString = "\(profile.effectiveBaseURL)/messages"
            var userContent: [[String: Any]] = []
            if let jpeg = screenshotData {
                userContent.append([
                    "type": "image",
                    "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]
                ])
            }
            userContent.append(["type": "text", "text": userText])
            requestBody = [
                "model": cheapModel, "max_tokens": 350,
                "system": systemPrompt,
                "messages": [["role": "user", "content": userContent]]
            ]
        } else {
            // OpenAI-compatible (OpenRouter, Google via OpenAI compat, custom)
            endpointString = "\(profile.effectiveBaseURL)/chat/completions"
            var userContent: [[String: Any]] = []
            if let jpeg = screenshotData {
                userContent.append([
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]
                ])
            }
            userContent.append(["type": "text", "text": userText])
            requestBody = [
                "model": cheapModel, "max_tokens": 350,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userContent]
                ]
            ]
        }

        guard let endpointURL = URL(string: endpointString),
              let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else { return nil }

        var request = URLRequest(url: endpointURL, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let authValue = profile.provider.requiresBearerPrefix ? "Bearer \(apiKey)" : apiKey
        request.setValue(authValue, forHTTPHeaderField: profile.provider.authHeaderName)
        if profile.provider == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpBody = bodyData

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                LumaLogger.log("[LumaFlow] Replan: response JSON unreadable")
                return nil
            }

            // Log API-level errors (rate limits, auth failures, etc.)
            if let error = json["error"] as? [String: Any] {
                LumaLogger.log("[LumaFlow] Replan API error: \((error["message"] as? String) ?? "unknown")")
                return nil
            }

            let rawText: String?
            if profile.provider == .anthropic {
                rawText = (json["content"] as? [[String: Any]])?.first?["text"] as? String
            } else {
                rawText = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
            }

            guard let text = rawText else {
                LumaLogger.log("[LumaFlow] Replan: no text content in response")
                return nil
            }

            let jsonString = extractFirstJSONObject(from: text)
            guard let jsonData = jsonString.data(using: .utf8),
                  let action = try? JSONDecoder().decode(LumaFlowActionRequest.self, from: jsonData) else {
                LumaLogger.log("[LumaFlow] Replan decode failed. Raw: \(text.prefix(300))")
                return nil
            }

            LumaLogger.log("[LumaFlow] Replan → \(action.actionType) \(action.targetElementLabel ?? "")")
            return action

        } catch {
            LumaLogger.log("[LumaFlow] Replan network error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Screenshot Capture for Vision

    /// Captures the main display and returns it as JPEG data suitable for vision API calls.
    /// Scales to at most 1280px wide to keep token usage reasonable while staying readable.
    private func captureScreenshotForVision() -> Data? {
        guard let cgImage = CGDisplayCreateImage(CGMainDisplayID()) else { return nil }

        let originalWidth = cgImage.width
        let originalHeight = cgImage.height
        let targetWidth = min(originalWidth, 1280)
        let scale = Double(targetWidth) / Double(originalWidth)
        let targetHeight = Int(Double(originalHeight) * scale)

        guard let colorSpace = cgImage.colorSpace,
              let drawContext = CGContext(
                  data: nil, width: targetWidth, height: targetHeight,
                  bitsPerComponent: cgImage.bitsPerComponent, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: cgImage.bitmapInfo.rawValue
              ) else { return nil }

        drawContext.interpolationQuality = .medium
        drawContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let resized = drawContext.makeImage() else { return nil }
        let nsImage = NSImage(cgImage: resized, size: NSSize(width: targetWidth, height: targetHeight))
        guard let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.65]) else { return nil }
        return jpeg
    }

    // MARK: - Planning API Call (text-only, no vision needed)

    private func callClaudeForJSON<T: Decodable>(
        systemPrompt: String,
        userMessage: String,
        maxTokens: Int,
        timeoutSeconds: Double,
        parseAs type: T.Type
    ) async -> T? {
        guard let profile = ProfileManager.shared.activeProfile,
              let apiKey = ProfileManager.shared.loadActiveAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else { return nil }

        let cheapModel = Self.cheapModelForProfile(profile)
        let endpointString: String
        let requestBody: [String: Any]

        if profile.provider == .anthropic {
            endpointString = "\(profile.effectiveBaseURL)/messages"
            requestBody = [
                "model": cheapModel, "max_tokens": maxTokens,
                "system": systemPrompt,
                "messages": [["role": "user", "content": userMessage]]
            ]
        } else {
            endpointString = "\(profile.effectiveBaseURL)/chat/completions"
            requestBody = [
                "model": cheapModel, "max_tokens": maxTokens,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userMessage]
                ]
            ]
        }

        guard let endpointURL = URL(string: endpointString),
              let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else { return nil }

        var request = URLRequest(url: endpointURL, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let authValue = profile.provider.requiresBearerPrefix ? "Bearer \(apiKey)" : apiKey
        request.setValue(authValue, forHTTPHeaderField: profile.provider.authHeaderName)
        if profile.provider == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpBody = bodyData

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

            let rawText: String?
            if profile.provider == .anthropic {
                rawText = (json["content"] as? [[String: Any]])?.first?["text"] as? String
            } else {
                rawText = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
            }

            guard let text = rawText else { return nil }
            let jsonString = extractFirstJSONObject(from: text)
            guard let jsonData = jsonString.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(T.self, from: jsonData)

        } catch {
            LumaLogger.log("[LumaFlow] API error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - JSON Extraction Helper

    /// Extracts the first complete JSON object from a string that may contain markdown,
    /// code fences, or leading/trailing explanation text from the model.
    private func extractFirstJSONObject(from text: String) -> String {
        // Strip code fences first
        let stripped = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Find the first { and its matching closing }
        guard let start = stripped.firstIndex(of: "{") else { return stripped }
        var depth = 0
        var current = start
        while current < stripped.endIndex {
            let char = stripped[current]
            if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(stripped[start...current])
                }
            }
            current = stripped.index(after: current)
        }
        return stripped
    }

    // MARK: - Helpers

    private static func cheapModelForProfile(_ profile: LumaAPIProfile) -> String {
        switch profile.provider {
        case .anthropic:  return "claude-haiku-4-5-20251001"
        case .openRouter: return "google/gemini-2.5-flash:free"
        case .google:     return "gemini-2.5-flash"
        case .custom:     return profile.selectedModel.isEmpty ? "gpt-4o-mini" : profile.selectedModel
        }
    }

    private func currentAppAndWindow() -> (appName: String, windowTitle: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ("Unknown", "Unknown") }
        let appName = app.localizedName ?? "Unknown"

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        var windowTitle = ""
        if let windowElement = windowRef {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(windowElement as! AXUIElement, kAXTitleAttribute as CFString, &titleRef)
            windowTitle = (titleRef as? String) ?? ""
        }

        return (appName, windowTitle)
    }
}
