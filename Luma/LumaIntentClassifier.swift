//
//  LumaIntentClassifier.swift
//  leanring-buddy
//
//  Reasoning layer that runs on every user input before any action is taken.
//  Calls Claude with max_tokens:300 to determine the best execution path,
//  then CompanionManager routes to the appropriate engine.
//
//  Replaces all hardcoded mode-switching (no more "hey luma agent" prefixes).
//

import AppKit
import Foundation

// MARK: - Execution Path

/// The engine Luma should use to fulfill the user's intent.
enum LumaExecutionPath: Equatable {
    /// Run a shell command via /bin/zsh — fastest for file ops, git, scripts.
    case cli(command: String)
    /// Operate a GUI app autonomously via AX + CGEvent (spawn an agent session).
    case visualAgent(goal: String)
    /// Walk the user through a multi-step process — user executes each step.
    case guide(topic: String)
    /// Answer a question or explain something — no system action needed.
    case response(query: String)
}

// MARK: - Classifier Confidence

/// How certain the classifier is about its routing decision.
enum ClassifierConfidence {
    /// Intent is unambiguous — execute immediately.
    case high
    /// Intent is clear but path has alternatives — execute with brief announcement.
    case medium
    /// Input is vague or missing context — ask a clarifying question first.
    case low
}

// MARK: - Classifier Result

struct LumaClassifierResult {
    /// Plain English description of what the user wants.
    let intent: String
    /// The recommended execution path and its payload.
    let path: LumaExecutionPath
    /// Confidence in the routing decision.
    let confidence: ClassifierConfidence
    /// True when the action is destructive, irreversible, or affects external services.
    let requiresConfirmation: Bool
    /// Human-readable prompt to show/speak before executing a confirmed action.
    let confirmationPrompt: String?
    /// True when the classifier needs more information before it can route correctly.
    let clarificationNeeded: Bool
    /// Question to ask the user when clarification is needed.
    let clarificationQuestion: String?
}

// MARK: - Classifier Result Helpers

extension LumaClassifierResult {
    /// Safe fallback that routes to the standard Claude response path on any error.
    static func fallback(for userInput: String) -> LumaClassifierResult {
        LumaClassifierResult(
            intent: userInput,
            path: .response(query: userInput),
            confidence: .medium,
            requiresConfirmation: false,
            confirmationPrompt: nil,
            clarificationNeeded: false,
            clarificationQuestion: nil
        )
    }

    /// Human-readable path name for logging.
    var pathName: String {
        switch path {
        case .cli:         return "cli"
        case .visualAgent: return "visual_agent"
        case .guide:       return "guide"
        case .response:    return "response"
        }
    }

    /// Human-readable confidence name for logging.
    var confidenceName: String {
        switch confidence {
        case .high:   return "high"
        case .medium: return "medium"
        case .low:    return "low"
        }
    }
}

// MARK: - Screen Context Cache

/// Snapshot of the frontmost app's AX state, valid for 500ms.
/// Reused across rapid successive inputs to avoid redundant AX traversal.
private struct CachedScreenContext {
    let activeAppName: String
    let activeWindowTitle: String
    /// Compact JSON array of up to 20 interactive AX elements in the focused window.
    let axTreeSummary: String
    let capturedAt: Date

    var isStale: Bool {
        Date().timeIntervalSince(capturedAt) > 0.5
    }
}

// MARK: - AX Element Summary (Encodable for JSON)

private struct AXElementSummary: Encodable {
    let role: String
    let label: String
    let x: Int
    let y: Int
}

// MARK: - LumaIntentClassifier

/// Singleton classifier. Call `classify(userInput:)` before any action is taken.
/// Gathers AX screen context, calls Claude, and returns a `LumaClassifierResult`.
@MainActor
final class LumaIntentClassifier {
    static let shared = LumaIntentClassifier()
    private init() {}

    // MARK: - State

    private var cachedContext: CachedScreenContext?
    /// Rolling log of the last 3 executed actions — injected into classifier context
    /// so Claude understands what Luma has recently done.
    private var recentActionLog: [String] = []
    private static let maximumRecentActionsToRetain = 3

    // MARK: - Public API

    /// Classifies `userInput` and returns a routing decision.
    /// Gathers screen context, calls Claude (max_tokens: 300), and parses the JSON result.
    /// Falls back to `.response` path on any API or parsing error.
    func classify(userInput: String) async -> LumaClassifierResult {
        let screenContext = gatherOrReuseCachedScreenContext()
        let recentActionsText = recentActionLog.isEmpty ? "none" : recentActionLog.joined(separator: "; ")

        guard let profile = ProfileManager.shared.activeProfile,
              let apiKey = ProfileManager.shared.loadActiveAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            LumaLogger.log("[LumaClassifier] No active profile/API key — defaulting to response path")
            return .fallback(for: userInput)
        }

        let userMessage = buildUserMessage(
            userInput: userInput,
            context: screenContext,
            recentActionsText: recentActionsText
        )

        do {
            let jsonText = try await callClassifierAPI(userMessage: userMessage, apiKey: apiKey, profile: profile)
            let result = parseClassifierJSON(jsonText, userInput: userInput)
            LumaLogger.log("[LumaClassifier] path=\(result.pathName) confidence=\(result.confidenceName) — \(result.intent.prefix(80))")
            return result
        } catch {
            LumaLogger.log("[LumaClassifier] API error: \(error.localizedDescription) — falling back to response path")
            return .fallback(for: userInput)
        }
    }

    /// Records a completed action so it appears in the context window of future classifier calls.
    func recordExecutedAction(_ description: String) {
        recentActionLog.append(description)
        if recentActionLog.count > Self.maximumRecentActionsToRetain {
            recentActionLog.removeFirst()
        }
    }

    // MARK: - Screen Context Gathering

    private func gatherOrReuseCachedScreenContext() -> CachedScreenContext {
        if let cached = cachedContext, !cached.isStale { return cached }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let appName = frontmostApp?.localizedName ?? "Unknown"
        let windowTitle = extractWindowTitle(for: frontmostApp)
        let axTreeJSON = buildAXTreeSummaryJSON(for: frontmostApp)

        let fresh = CachedScreenContext(
            activeAppName: appName,
            activeWindowTitle: windowTitle,
            axTreeSummary: axTreeJSON,
            capturedAt: Date()
        )
        cachedContext = fresh
        return fresh
    }

    private func extractWindowTitle(for app: NSRunningApplication?) -> String {
        guard let app else { return "Unknown" }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success else { return "Unknown" }
        let axWindow = windowRef as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty else { return "Unknown" }
        return title
    }

    private func buildAXTreeSummaryJSON(for app: NSRunningApplication?) -> String {
        guard let app else { return "[]" }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success else { return "[]" }
        let axWindow = windowRef as! AXUIElement
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return "[]" }

        let maximumElementsInSummary = 20
        var elements: [AXElementSummary] = []
        for child in children {
            guard elements.count < maximumElementsInSummary else { break }
            if let summary = extractAXElementSummary(from: child) {
                elements.append(summary)
            }
        }

        guard let data = try? JSONEncoder().encode(elements),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private func extractAXElementSummary(from element: AXUIElement) -> AXElementSummary? {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let roleString = roleRef as? String else { return nil }

        // Skip structural/container roles that don't add actionable context for the classifier
        let noisyRoles: Set<String> = ["AXGroup", "AXScrollArea", "AXSplitter", "AXScrollBar", "AXWebArea", "AXLayoutArea", "AXStaticText"]
        guard !noisyRoles.contains(roleString) else { return nil }

        // Extract the most human-readable label available from this element
        let labelAttributePriority = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXPlaceholderValueAttribute]
        var labelText = ""
        for attribute in labelAttributePriority {
            var labelRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &labelRef) == .success,
               let text = labelRef as? String, !text.isEmpty {
                labelText = String(text.prefix(60))
                break
            }
        }
        guard !labelText.isEmpty else { return nil }

        // Screen position gives Claude spatial context about element layout
        var positionRef: CFTypeRef?
        var elementX = 0, elementY = 0
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
           let posValue = positionRef {
            var point = CGPoint.zero
            AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
            elementX = Int(point.x)
            elementY = Int(point.y)
        }

        // Normalize role string: strip AX prefix for brevity ("AXButton" → "button")
        let normalizedRole = roleString.hasPrefix("AX")
            ? String(roleString.dropFirst(2)).lowercased()
            : roleString.lowercased()

        return AXElementSummary(role: normalizedRole, label: labelText, x: elementX, y: elementY)
    }

    // MARK: - API Call

    private static let classifierSystemPrompt = """
    You are Luma's intent classifier. Given user input and screen context, \
    determine the best execution path. Always respond in valid JSON only. \
    No preamble, no markdown, no backticks.

    Execution paths:
    - cli: use for ALL coding, programming, and software engineering tasks \
      (write code, fix bugs, add features, refactor, create files, edit source code, \
      explain code, run tests, build projects, git operations, install packages, \
      scripts, terminal commands, file operations). The CLI runtime uses Claude Code \
      which is purpose-built for coding. Opening GUI apps is NOT cli.
    - visual_agent: use ONLY for GUI automation — clicking UI elements, filling \
      forms, navigating browsers, cross-app workflows, sending messages in apps, \
      and opening/launching applications ("open WhatsApp", "launch Safari"). \
      Do NOT use for anything involving writing or editing code.
    - guide: user explicitly asks how to do something themselves, or the task \
      requires the user's own credentials/login that Luma must not touch. \
      Do NOT use guide for simple app launches or automation tasks.
    - response: question, explanation, conversation, no action needed

    Confidence rules:
    - high: intent is unambiguous, path is obvious, context is clear
    - medium: intent is clear but path has alternatives
    - low: input is vague, missing context, or ambiguous

    Set requiresConfirmation true ONLY for genuinely destructive or irreversible actions:
    - Permanently deleting files, folders, or data
    - Wiping or formatting a disk/drive
    - Uninstalling applications
    - Force-quitting processes with data loss risk
    Do NOT set requiresConfirmation for sending messages, filling forms, clicking buttons,
    opening apps, or any action the user explicitly described in their instruction.

    JSON schema:
    {
      "intent": "string — plain english what user wants",
      "path": "cli | visual_agent | guide | response",
      "pathDetail": "string — specific goal/command/topic/query for that path",
      "confidence": "high | medium | low",
      "requiresConfirmation": boolean,
      "confirmationPrompt": "string or null",
      "clarificationNeeded": boolean,
      "clarificationQuestion": "string or null"
    }
    """

    private func buildUserMessage(
        userInput: String,
        context: CachedScreenContext,
        recentActionsText: String
    ) -> String {
        """
        User input: "\(userInput)"
        Active app: "\(context.activeAppName)"
        Active window title: "\(context.activeWindowTitle)"
        AX tree summary: \(context.axTreeSummary)
        Recent Luma actions: "\(recentActionsText)"
        """
    }

    private func callClassifierAPI(
        userMessage: String,
        apiKey: String,
        profile: LumaAPIProfile
    ) async throws -> String {
        let endpointURLString: String
        let requestBody: [String: Any]
        let cheapModel = Self.cheapModelID(for: profile)

        if profile.provider == .anthropic {
            endpointURLString = "\(profile.effectiveBaseURL)/messages"
            requestBody = [
                "model": cheapModel,
                "max_tokens": 300,
                "system": Self.classifierSystemPrompt,
                "messages": [["role": "user", "content": userMessage]]
            ]
        } else {
            endpointURLString = "\(profile.effectiveBaseURL)/chat/completions"
            requestBody = [
                "model": cheapModel,
                "max_tokens": 300,
                "messages": [
                    ["role": "system", "content": Self.classifierSystemPrompt],
                    ["role": "user", "content": userMessage]
                ]
            ]
        }

        guard let endpointURL = URL(string: endpointURLString) else {
            throw ClassifierAPIError.invalidEndpointURL
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 8-second hard timeout — classifier must never block the input pipeline for long
        request.timeoutInterval = 8

        let authHeaderValue = profile.provider.requiresBearerPrefix ? "Bearer \(apiKey)" : apiKey
        request.setValue(authHeaderValue, forHTTPHeaderField: profile.provider.authHeaderName)
        if profile.provider == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClassifierAPIError.unreadableResponse
        }

        if profile.provider == .anthropic {
            // Anthropic response: { "content": [{ "type": "text", "text": "..." }] }
            guard let contentArray = json["content"] as? [[String: Any]],
                  let text = contentArray.first?["text"] as? String else {
                throw ClassifierAPIError.unreadableResponse
            }
            return text
        } else {
            // OpenAI-compatible: { "choices": [{ "message": { "content": "..." } }] }
            guard let choices = json["choices"] as? [[String: Any]],
                  let content = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
                throw ClassifierAPIError.unreadableResponse
            }
            return content
        }
    }

    // MARK: - JSON Parsing

    private func parseClassifierJSON(_ rawJSON: String, userInput: String) -> LumaClassifierResult {
        // Strip any accidental markdown fences Claude might include despite instructions
        let cleaned = rawJSON
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            LumaLogger.log("[LumaClassifier] JSON parse failed — fallback to response path")
            return .fallback(for: userInput)
        }

        let intent        = json["intent"] as? String ?? userInput
        let pathString    = json["path"] as? String ?? "response"
        let pathDetail    = json["pathDetail"] as? String ?? userInput
        let confidenceStr = json["confidence"] as? String ?? "medium"
        let needsConfirm  = json["requiresConfirmation"] as? Bool ?? false
        let confirmPrompt = json["confirmationPrompt"] as? String
        let needsClarify  = json["clarificationNeeded"] as? Bool ?? false
        let clarifyQ      = json["clarificationQuestion"] as? String

        let path: LumaExecutionPath
        switch pathString {
        case "cli":          path = .cli(command: pathDetail)
        case "visual_agent": path = .visualAgent(goal: pathDetail)
        case "guide":        path = .guide(topic: pathDetail)
        default:             path = .response(query: pathDetail)
        }

        let confidence: ClassifierConfidence
        switch confidenceStr {
        case "high": confidence = .high
        case "low":  confidence = .low
        default:     confidence = .medium
        }

        return LumaClassifierResult(
            intent: intent,
            path: path,
            confidence: confidence,
            requiresConfirmation: needsConfirm,
            confirmationPrompt: confirmPrompt,
            clarificationNeeded: needsClarify,
            clarificationQuestion: clarifyQ
        )
    }

    // MARK: - Cheap Model Selection

    /// Returns the cheapest/fastest model suitable for classifier calls on the given profile.
    /// Classification only needs JSON schema following — no creative or reasoning depth.
    private static func cheapModelID(for profile: LumaAPIProfile) -> String {
        switch profile.provider {
        case .anthropic:  return "claude-haiku-4-5-20251001"
        case .openRouter: return "google/gemini-2.5-flash:free"
        case .google:     return "gemini-2.5-flash"
        case .custom:     return profile.selectedModel.isEmpty ? "gpt-4o-mini" : profile.selectedModel
        }
    }

    // MARK: - Bubble Mini Classifier

    /// Ultra-fast single-word routing decision for text typed into an agent bubble.
    /// Avoids the full classify() pipeline (no voice state, no confirmation loops).
    /// Returns in <150ms using a tiny cheap model with max_tokens: 10.
    func classifyBubbleInput(
        prompt: String,
        currentSessionTitle: String,
        sessionIsActive: Bool
    ) async -> BubbleInputRoute {
        guard let profile = ProfileManager.shared.activeProfile,
              let apiKey = ProfileManager.shared.loadActiveAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            // No API profile — treat as a new task so it goes through normal routing
            return .newTask
        }

        let systemPrompt = """
        You are a routing classifier for an AI assistant bubble. Given user text and context,
        respond with EXACTLY ONE WORD — no punctuation, no explanation:
        - continue  → the input adds context or follow-up to the current active task
        - newtask   → completely new task to execute (different from what the agent is doing)
        - question  → the user is asking a question to answer directly, not requesting an action

        Current agent session: "\(currentSessionTitle)"
        Session is active/running: \(sessionIsActive)
        """

        let cheapModel = Self.cheapModelID(for: profile)
        let endpointString: String
        let requestBody: [String: Any]

        if profile.provider == .anthropic {
            endpointString = "\(profile.effectiveBaseURL)/messages"
            requestBody = [
                "model": cheapModel, "max_tokens": 10,
                "system": systemPrompt,
                "messages": [["role": "user", "content": prompt]]
            ]
        } else {
            endpointString = "\(profile.effectiveBaseURL)/chat/completions"
            requestBody = [
                "model": cheapModel, "max_tokens": 10,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user",   "content": prompt]
                ]
            ]
        }

        guard let endpointURL = URL(string: endpointString),
              let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return .newTask
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 4  // Must be fast — user is waiting for bubble to react
        let authValue = profile.provider.requiresBearerPrefix ? "Bearer \(apiKey)" : apiKey
        request.setValue(authValue, forHTTPHeaderField: profile.provider.authHeaderName)
        if profile.provider == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpBody = bodyData

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .newTask
        }

        let rawText: String?
        if profile.provider == .anthropic {
            rawText = (json["content"] as? [[String: Any]])?.first?["text"] as? String
        } else {
            rawText = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        }

        let word = (rawText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        LumaLogger.log("[BubbleClassifier] '\(prompt.prefix(40))' → \(word)")

        switch word {
        case "continue": return .continueFlow
        case "question": return .question
        default:         return .newTask
        }
    }

    // MARK: - Errors

    private enum ClassifierAPIError: Error {
        case invalidEndpointURL
        case unreadableResponse
    }
}

// MARK: - Bubble Input Route

/// Routing decision returned by the bubble mini classifier.
enum BubbleInputRoute {
    /// Input is a follow-up or clarification for the currently active flow — inject directly.
    case continueFlow
    /// Input is a completely new task — run the full classifier pipeline.
    case newTask
    /// Input is a question — answer it inline in the bubble transcript without spawning a task.
    case question
}

// MARK: - LumaCLIExecutor

/// Executes shell commands via /bin/zsh for the `.cli` execution path.
/// Captures combined stdout + stderr and returns it as a truncated string.
enum LumaCLIExecutor {
    /// Maximum characters returned from command output — keeps responses speakable.
    private static let maximumOutputCharacters = 2000

    /// Runs `command` in /bin/zsh and returns combined stdout/stderr.
    /// Throws if the process cannot be launched.
    static func run(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            // Use -l (login shell) so .zprofile is sourced and the user's full PATH
            // is available — Homebrew, Node, Python, etc. are not on the system PATH
            // that non-login shells inherit from a sandboxed macOS app process.
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { _ in
                let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                // Combine non-empty streams; prefer stdout, append stderr as context
                let combined = [stdout, stderr]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                let finalOutput = combined.count > maximumOutputCharacters
                    ? String(combined.prefix(maximumOutputCharacters)) + "\n…(output truncated)"
                    : combined
                continuation.resume(returning: finalOutput.isEmpty ? "(command produced no output)" : finalOutput)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
