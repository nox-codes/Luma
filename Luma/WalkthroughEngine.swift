//
//  WalkthroughEngine.swift
//  leanring-buddy
//
//  Central coordinator for guided walkthroughs. Owns the full lifecycle:
//  AI step planning → user confirmation → step-by-step execution → completion.
//
//  Each executing step:
//    1. Speaks the instruction via TTS
//    2. Points the Luma cursor at the named UI element via CursorGuide (AI screenshot + AX fallback)
//    3. Installs a persistent AXObserver that fires on UI events in the target app
//    4a. Fast path: if the AX label matches the expected element name → immediately complete
//    4b. Slow path: debounced AI screenshot validation ("COMPLETED or INCOMPLETE?") → complete on yes
//    5. On a wrong-element focus event, speaks a gentle correction and re-points the cursor
//    6. On timeout, nudges the user and re-points; reschedules the nudge
//
//  CONCURRENCY SAFETY:
//  All state is @MainActor. Async callbacks (AXObserver C callback → Task @MainActor,
//  Timer → Task @MainActor) carry a `generation` integer that is incremented every time
//  a step ends. Any callback whose generation doesn't match `currentStepGeneration` is
//  silently dropped, preventing stale events from previous steps from affecting newer ones.
//

import AppKit
import ApplicationServices
import Combine
import Foundation

// MARK: - WalkthroughEngine

@MainActor
final class WalkthroughEngine: ObservableObject {
    static let shared = WalkthroughEngine()

    @Published private(set) var state: WalkthroughState = .idle

    // MARK: - Computed UI Properties

    /// True when the engine is in any non-idle, non-complete state.
    var isRunning: Bool {
        switch state {
        case .idle, .complete: return false
        default: return true
        }
    }

    /// The instruction for the currently active step, or empty string when not executing.
    var currentInstruction: String {
        guard case .executing(let steps, let currentIndex) = state,
              currentIndex < steps.count else { return "" }
        return steps[currentIndex].instruction
    }

    /// (currentStepNumber, totalStepCount) — 1-based, both zero when not executing.
    var progress: (currentStepNumber: Int, totalStepCount: Int) {
        guard case .executing(let steps, let currentIndex) = state else { return (0, 0) }
        return (currentIndex + 1, steps.count)
    }

    // MARK: - Dependencies

    private let taskPlanner = TaskPlanner()
    private let cursorGuide = CursorGuide.shared
    private let ttsClient = NativeTTSClient.shared

    // MARK: - Generation Counter
    //
    // Every time a step ends (via completion, skip, or cancel), `currentStepGeneration`
    // is incremented. AX callbacks and timers capture their generation at the moment they
    // are created. When they execute (possibly after a step has already ended), they compare
    // their captured generation to `currentStepGeneration` and drop themselves if they differ.
    // This makes all async callbacks automatically inert once their step has ended.
    private var currentStepGeneration: Int = 0

    // MARK: - Pointing Task

    // Stored so we can cancel an in-flight AI pointing call when the step ends.
    // Without this, a slow AI response from step N could move the cursor to step N's
    // element while the user is already working on step N+1.
    private var activePointingTask: Task<Void, Never>?

    // MARK: - Mouse Event Monitor

    // Global monitor for left-click and right-click events. The AX observer and AX polling
    // only fire on keyboard-focus changes — sidebar clicks, right-clicks, and most direct
    // mouse interactions don't change kAXFocusedUIElementAttribute and are therefore missed.
    // This monitor catches those interactions and immediately triggers AX + AI validation.
    private var mouseEventMonitor: Any?

    // MARK: - AI Validation State

    private var isAIValidationInProgress: Bool = false
    private var lastAIValidationDate: Date = .distantPast

    /// Minimum seconds between consecutive AI screenshot validation calls.
    private let minimumSecondsBetweenAIValidations: TimeInterval = 1.5

    // MARK: - Typing Step State
    //
    // When a step instruction contains a typing keyword ("type", "write", "enter") followed
    // by quoted text, the normal AX label-match / dwell path is bypassed entirely. Instead:
    //   1. The focused AXUIElement is captured at step start as the polling target.
    //   2. A 0.5s polling timer reads kAXValueAttribute from that element every tick.
    //   3. The step completes only when the value contains the expected text AND at least
    //      minimumTypingStepElapsedSeconds have passed since the step started.
    //
    // Polling (not kAXValueChangedNotification) is used because value-changed events fire on
    // every keystroke, making it impossible to know when the user has finished typing.

    /// True while a typing step is active. Set to true when a typing step starts (in executeStep),
    /// cleared to false only by the polling timer once the expected text is found or the step times out.
    /// All methods that advance steps or fire timers guard on this flag — when it is true they drop
    /// themselves immediately so the polling timer is the sole owner of step completion.
    private var isTypingStepActive: Bool = false

    /// The text the user must type for the current step to complete.
    /// Extracted from quoted strings in the step instruction (e.g. "type \"Hello\" in…" → "Hello").
    /// Nil for non-typing steps — the normal AX label-match / dwell path is used instead.
    private var currentStepExpectedTypingText: String? = nil

    /// The AXUIElement captured by the polling timer on its first tick after the 1.5s delay.
    /// Left nil at step start intentionally — the delay ensures the user has switched to the
    /// correct field before we lock onto an element. Set to nil by stopActiveStepAndCleanUp.
    private var currentStepTypingTargetElement: AXUIElement? = nil

    /// The timestamp when the current typing step began executing.
    /// Enforces minimumTypingStepElapsedSeconds before the step can complete.
    private var currentStepTypingStartDate: Date? = nil

    /// Minimum seconds that must have passed since step start before a typing step can complete.
    /// Prevents completing on pre-existing text that was already in the field before the step ran.
    private let minimumTypingStepElapsedSeconds: TimeInterval = 1.0

    /// Computes the timeout for a typing step based on the length of the expected text.
    /// Minimum is 30 seconds; each character adds 1.5 seconds to accommodate longer sentences.
    /// e.g. "claude is the best ai" = 22 chars → max(30, 22 * 1.5) = 33 seconds.
    private func typingStepTimeoutSeconds(for expectedText: String) -> TimeInterval {
        max(30.0, Double(expectedText.count) * 1.5)
    }

    // MARK: - AX Match Dwell State
    //
    // Completing a step the instant keyboard focus lands on the target element causes
    // false positives when the user is tabbing past it or the focus briefly settles there
    // before they move on. Requiring the match to hold continuously for minimumAXMatchDwellSeconds
    // before completing prevents premature advancement.
    //
    // The AX polling timer (running every 0.5s) drives dwell progression: on each tick it
    // either extends the dwell or resets it if the match disappeared.
    // The AX observer fast path starts the dwell clock; the polling timer finishes it.

    /// The date when we first saw a continuous AX match for the current step.
    /// Nil when there is no in-progress dwell. Set to non-nil on the first matching
    /// AX event or poll tick, and reset to nil whenever the match disappears.
    private var axMatchDwellStartDate: Date? = nil

    /// How long a continuous AX match must hold before the step is marked complete.
    private let minimumAXMatchDwellSeconds: TimeInterval = 2.0

    // MARK: - AX Observer State

    /// The AXObserver installed for the current step's target app.
    /// Set to nil and removed from the run loop when the step ends.
    private var axObserver: AXObserver?

    // MARK: - AX Observer Context

    /// Carries the step generation and engine reference through the C callback's userData/refcon.
    /// C function pointers passed to AXObserverCreate cannot capture Swift context (they are
    /// @convention(c) and closures that capture variables don't satisfy that requirement). We
    /// work around this by heap-allocating a context object and passing its pointer as refcon
    /// to AXObserverAddNotification. The C callback reads it back with Unmanaged.fromOpaque.
    private final class WalkthroughObserverContext {
        // unowned: WalkthroughEngine is a singleton that outlives any observer
        unowned let engine: WalkthroughEngine
        let generation: Int

        init(engine: WalkthroughEngine, generation: Int) {
            self.engine = engine
            self.generation = generation
        }
    }

    /// Strong reference to the current observer context. Keeps the context alive for the
    /// duration of the observer's life. Set to nil in stopActiveStepAndCleanUp.
    private var axObserverContext: WalkthroughObserverContext?

    // MARK: - AX Polling State

    /// 0.3-second repeating timer that reads the system-wide focused element and checks
    /// it against the expected step element. This catches interactions (button clicks, menu
    /// selections) that don't reliably emit AXObserver notifications in every app.
    private var axPollingTimer: Timer?

    // MARK: - Nudge Timer State

    private var nudgeTimer: Timer?
    private var nudgeCount: Int = 0
    private let maximumInstructionNudgesBeforeSwitchingToPatientMessage: Int = 3
    /// After this many nudges, Luma disengages rather than continuing to repeat.
    /// Nudge-count-based (not time-based) so it scales correctly with any timeoutSeconds value.
    private let maximumTotalNudgesBeforeDisengaging: Int = 5

    // MARK: - Periodic Claude Verification State
    //
    // Claude is expensive — we only call it every claudeVerificationInterval successful steps
    // to confirm overall progress, rather than after every single step. NudgeEngine handles
    // all per-step corrections offline. Claude is also called once when the user is stuck
    // after three consecutive nudges (escalation).

    /// Number of successfully completed steps since the last Claude verification call.
    private var stepsSinceLastClaudeVerification: Int = 0

    /// Claude verifies overall walkthrough progress every this many completed steps.
    private let claudeVerificationInterval: Int = 5

    // MARK: - Correction Debounce

    private var lastCorrectionDate: Date = .distantPast
    private let minimumSecondsBetweenCorrections: TimeInterval = 2.0

    private init() {}

    // MARK: - Public API

    /// Asks the AI to plan steps for `goal` then shows them to the user for confirmation.
    /// State transitions: idle → planning → confirming (on success) / idle (on failure)
    func startWalkthrough(goal: String) async {
        state = .planning

        let frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"

        do {
            let walkthroughPlan = try await taskPlanner.planSteps(
                goal: goal,
                frontmostAppName: frontmostAppName
            )
            state = .confirming(walkthroughPlan.steps)
        } catch {
            LumaLogger.log("[Luma] WalkthroughEngine: step planning failed — \(error.localizedDescription)")
            state = .idle
        }
    }

    /// Plans steps for `goal` via AI and immediately starts executing — no confirmation dialog.
    /// Used when LumaTaskClassifier routes a transcript to the multi-step path. The user
    /// hears the first instruction as soon as planning succeeds.
    ///
    /// Returns `true` if planning succeeded and execution started, `false` if planning failed.
    /// CompanionManager uses the return value to fall back to the voice response path when
    /// this returns false — so the user always gets SOME response even if planning fails.
    ///
    /// State transitions: idle → planning → executing (skips confirming entirely)
    func startWalkthroughSilently(goal: String) async -> Bool {
        guard !isRunning else {
            LumaLogger.log("[Luma] WalkthroughEngine: startWalkthroughSilently ignored — engine already running")
            return false
        }

        state = .planning
        let frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"

        do {
            let walkthroughPlan = try await taskPlanner.planSteps(
                goal: goal,
                frontmostAppName: frontmostAppName
            )

            guard !walkthroughPlan.steps.isEmpty else {
                LumaLogger.log("[Luma] WalkthroughEngine: plan returned 0 steps — returning to idle")
                state = .idle
                return false
            }

            LumaLogger.log("[Luma] WalkthroughEngine: silent start — \(walkthroughPlan.steps.count) step(s) planned")
            state = .executing(steps: walkthroughPlan.steps, currentIndex: 0)
            executeStep(walkthroughPlan.steps[0], allSteps: walkthroughPlan.steps)
            return true
        } catch {
            LumaLogger.log("[Luma] WalkthroughEngine: silent planning failed — \(error.localizedDescription)")
            state = .idle
            return false
        }
    }

    /// Confirms the planned steps and starts executing from step 0.
    /// Must be called while in the `.confirming` state.
    func confirmAndBeginWalkthrough() {
        guard case .confirming(let steps) = state, !steps.isEmpty else {
            LumaLogger.log("[Luma] WalkthroughEngine: confirmAndBeginWalkthrough called from wrong state")
            return
        }

        state = .executing(steps: steps, currentIndex: 0)
        executeStep(steps[0], allSteps: steps)
    }

    /// Directly starts executing a pre-built list of steps without AI planning or user confirmation.
    /// Used by OfflineGuideManager to run offline guides that don't need an API call.
    func executeSteps(_ steps: [WalkthroughStep]) {
        guard !steps.isEmpty else {
            LumaLogger.log("[Luma] WalkthroughEngine: executeSteps called with empty array — ignored")
            return
        }
        state = .executing(steps: steps, currentIndex: 0)
        executeStep(steps[0], allSteps: steps)
    }

    /// Skips the current step and advances without requiring the user to perform the action.
    func skipCurrentStep() {
        guard case .executing(let steps, let currentIndex) = state else { return }
        stopActiveStepAndCleanUp()
        advanceToNextStep(steps: steps, completedIndex: currentIndex)
    }

    /// Cancels the walkthrough immediately and returns to idle.
    func cancelWalkthrough() {
        stopActiveStepAndCleanUp()
        cursorGuide.clearGuidance()
        stepsSinceLastClaudeVerification = 0
        state = .idle
        LumaLogger.log("[Luma] WalkthroughEngine: cancelled")
    }

    // MARK: - Step Lifecycle Cleanup

    /// Tears down everything associated with the current step and increments the generation counter.
    /// Must be called before starting a new step and before cancelling.
    private func stopActiveStepAndCleanUp() {
        // Increment generation: any in-flight callbacks from the current step will see their
        // captured generation no longer matches and will silently drop themselves.
        currentStepGeneration += 1

        // Cancel any in-flight AI pointing call (e.g. slow API response for a previous step's element)
        activePointingTask?.cancel()
        activePointingTask = nil

        // Remove the AX observer from the run loop so no new callbacks will fire.
        // Swift's ARC releases the AXObserver object when axObserver is set to nil.
        if let existingObserver = axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(existingObserver),
                .commonModes
            )
        }
        axObserver = nil

        // Release the observer context — the C callback can no longer fire after the observer
        // was removed from the run loop above, and any in-flight Task closures captured
        // primitive values from the context (not the context itself), so this is safe.
        axObserverContext = nil

        // Remove the global mouse event monitor — no further clicks should trigger validation
        if let existingMonitor = mouseEventMonitor {
            NSEvent.removeMonitor(existingMonitor)
            mouseEventMonitor = nil
        }

        // Cancel the AX polling timer
        axPollingTimer?.invalidate()
        axPollingTimer = nil

        // Cancel the nudge timer
        nudgeTimer?.invalidate()
        nudgeTimer = nil

        // Reset all per-step mutable state
        nudgeCount = 0
        isAIValidationInProgress = false
        isTypingStepActive = false
        lastCorrectionDate = .distantPast
        lastAIValidationDate = .distantPast
        axMatchDwellStartDate = nil
        currentStepExpectedTypingText = nil
        currentStepTypingTargetElement = nil
        currentStepTypingStartDate = nil
    }

    // MARK: - Element Pointing

    /// Points the Luma cursor at `elementName` using LumaImageProcessingEngine (AX + visual fusion).
    /// Falls back to CursorGuide's AI screenshot path if LIPE finds nothing above its
    /// confidence threshold. `bubbleText` is shown in the small speech bubble when the cursor arrives.
    private func pointAtStepElement(
        elementName: String,
        appBundleID: String?,
        isMenuBar: Bool,
        bubbleText: String?
    ) async {
        guard !elementName.isEmpty else { return }

        let candidate = await LumaImageProcessingEngine.shared.findElement(
            query: elementName,
            appBundleID: isMenuBar ? nil : appBundleID,
            isMenuBar: isMenuBar
        )

        if let confirmedCandidate = candidate {
            LumaImageProcessingEngine.shared.pointCursor(at: confirmedCandidate, bubbleText: bubbleText)
        } else {
            // LIPE confidence too low — fall back to the AI screenshot path which asks
            // the model to visually locate the element when AX and on-device vision fail.
            await cursorGuide.pointAtElementViaAIScreenshot(
                named: elementName,
                inApp: isMenuBar ? nil : appBundleID,
                bubbleText: bubbleText
            )
        }
    }

    // MARK: - Step Execution

    /// Sets up everything needed for the user to work on `step`.
    private func executeStep(_ step: WalkthroughStep, allSteps: [WalkthroughStep]) {
        // stopActiveStepAndCleanUp increments the generation counter.
        // Capture the NEW value immediately so this step's callbacks carry the right generation.
        stopActiveStepAndCleanUp()
        let stepGeneration = currentStepGeneration

        // Detect typing steps before any watchers are installed.
        // stopActiveStepAndCleanUp already reset all typing state to nil,
        // so these assignments are the authoritative set for this step.
        currentStepExpectedTypingText = extractExpectedTypingText(from: step.instruction)
        if let expectedTypingText = currentStepExpectedTypingText {
            // Record when this step started. The polling timer uses this to enforce the
            // 1.5s delay before the first poll tick and the minimum elapsed time before
            // completing. currentStepTypingTargetElement is intentionally NOT captured here —
            // capturing immediately risks locking onto the wrong field (e.g. Spotlight or the
            // previously focused element). The poller captures it lazily on the first tick
            // after the 1.5s delay, by which time the user has landed in the correct field.
            currentStepTypingStartDate = Date()

            // Lock out all other step-advancement paths for the duration of this typing step.
            // The nudge and AI validation timers are killed here — the polling timer is the
            // sole authority on when a typing step completes. They would race and advance the
            // step before the user has finished typing if left running.
            isTypingStepActive = true
            nudgeTimer?.invalidate()
            nudgeTimer = nil
            isAIValidationInProgress = false

            LumaLogger.log("[Luma] WalkthroughEngine: typing step detected — waiting for '\(expectedTypingText)' (element capture deferred 1.5s)")
        }

        let humanReadableStepNumber = step.index + 1
        LumaLogger.log("[Luma] WalkthroughEngine: step \(humanReadableStepNumber)/\(allSteps.count) — '\(step.instruction)' (gen \(stepGeneration))")

        // 1. Speak the instruction so the user knows what to do
        ttsClient.speak("Step \(humanReadableStepNumber). \(step.instruction)")

        // Bubble text for the small speech bubble shown next to the Luma cursor.
        // Kept short so it fits the bubble — the full instruction plays via TTS.
        let stepBubbleText = step.elementName.isEmpty ? "here!" : "→ \(step.elementName)"

        // 2. Point the cursor. Stored as a cancellable Task so we can abort it if the step
        //    ends before the element is found (e.g. user completes the step quickly).
        //    Uses LIPE (AX + visual fusion) with CursorGuide AI as fallback.
        activePointingTask = Task {
            await self.pointAtStepElement(
                elementName: step.elementName,
                appBundleID: step.appBundleID,
                isMenuBar: step.isMenuBar,
                bubbleText: stepBubbleText
            )
        }

        // 3. Install the AX observer to detect when the user interacts with the target
        startWatching(for: step, allSteps: allSteps, generation: stepGeneration)

        // 4. Start AX polling (0.5s) to catch keyboard-driven interactions the observer misses
        startAXPolling(for: step, allSteps: allSteps, generation: stepGeneration)

        // 5. Start the nudge timer in case the user doesn't act within timeoutSeconds
        startNudgeTimer(for: step, allSteps: allSteps, generation: stepGeneration)

        // 6. Start global mouse event monitoring.
        //    Sidebar clicks, right-clicks, and direct mouse interactions don't change
        //    AX keyboard focus, so the AXObserver and polling timer miss them entirely.
        //    This monitor fires immediately on any click and triggers fast AI validation.
        startMouseEventMonitoring(for: step, allSteps: allSteps, generation: stepGeneration)
    }

    // MARK: - AX Observer Management

    /// Creates and installs an AXObserver on the target app.
    /// Passes `generation` as context so stale callbacks from a previous step's observer
    /// are silently ignored even if they arrive after the step has ended.
    private func startWatching(for step: WalkthroughStep, allSteps: [WalkthroughStep], generation: Int) {
        // Determine which process to watch.
        // NSRunningApplication.runningApplications(withBundleIdentifier:) is case-sensitive,
        // so "com.apple.Notes" and "com.apple.notes" would not match each other. Instead we
        // do a case-insensitive linear scan of all running apps so AI-generated bundle IDs
        // with wrong capitalization still resolve to the correct process.
        let targetPID: pid_t
        if let stepBundleID = step.appBundleID {
            let normalizedStepBundleID = stepBundleID.lowercased()
            if let targetApp = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier?.lowercased() == normalizedStepBundleID
            }) {
                targetPID = targetApp.processIdentifier
            } else if let frontmostApp = NSWorkspace.shared.frontmostApplication {
                targetPID = frontmostApp.processIdentifier
            } else {
                LumaLogger.log("[Luma] WalkthroughEngine: cannot start watching — no target app found")
                return
            }
        } else if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            targetPID = frontmostApp.processIdentifier
        } else {
            LumaLogger.log("[Luma] WalkthroughEngine: cannot start watching — no target app found")
            return
        }

        // Allocate the context that carries both the engine reference and the step generation.
        // axObserverContext holds a strong reference, keeping the object alive for the observer's lifetime.
        let observerContext = WalkthroughObserverContext(engine: self, generation: generation)
        axObserverContext = observerContext
        // passUnretained is safe here — axObserverContext (the property above) is the owning reference.
        let contextPointer = Unmanaged.passUnretained(observerContext).toOpaque()

        var newObserver: AXObserver?

        // The C callback must be a non-capturing closure (@convention(c)).
        // We pass `generation` and `engine` through the userData/refcon pointer (contextPointer)
        // rather than capturing them, which would require a context-capturing closure and fail to compile.
        let createResult = AXObserverCreate(targetPID, { _, element, notification, userData in
            guard let userData = userData else { return }
            let context = Unmanaged<WalkthroughObserverContext>.fromOpaque(userData).takeUnretainedValue()

            // Extract values from the context synchronously here in the C callback.
            // The Task closure captures these scalars/references — not the context object itself —
            // so releasing axObserverContext later in stopActiveStepAndCleanUp is safe.
            let capturedEngine = context.engine
            let capturedGeneration = context.generation
            let capturedNotification = notification as String

            Task { @MainActor in
                capturedEngine.handleAccessibilityNotification(
                    element: element,
                    notification: capturedNotification,
                    generation: capturedGeneration
                )
            }
        }, &newObserver)

        guard createResult == .success, let createdObserver = newObserver else {
            LumaLogger.log("[Luma] WalkthroughEngine: AXObserverCreate failed (error \(createResult.rawValue)) for PID \(targetPID)")
            return
        }

        let appElement = AXUIElementCreateApplication(targetPID)

        // Register for AX notifications. More notification types means fewer interactions slip
        // through to the slower AI validation path.
        // Note: AXMenuOpened/AXMenuClosed must be registered on the system-wide element to fire
        // reliably — they silently fail on an app-level element. Menu interactions are caught by
        // the AX polling timer instead.
        let notificationsToRegister: [String] = [
            kAXFocusedUIElementChangedNotification,     // keyboard nav, most button clicks
            kAXValueChangedNotification,                // text field edits, checkbox toggles
            kAXWindowCreatedNotification,               // new windows / dialogs opening
            kAXSelectedTextChangedNotification,         // text selection in documents
            kAXUIElementDestroyedNotification,          // element removed (e.g. popover closed)
            kAXFocusedWindowChangedNotification,        // window focus switched
            kAXSelectedChildrenChangedNotification,     // list/outline selection changed
        ]

        for notificationName in notificationsToRegister {
            AXObserverAddNotification(createdObserver, appElement, notificationName as CFString, contextPointer)
        }

        // .commonModes ensures callbacks fire even during menu tracking (NSEventTrackingRunLoopMode).
        // .defaultMode pauses during menu tracking, which is exactly when we need to detect completions.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .commonModes)
        axObserver = createdObserver

        LumaLogger.log("[Luma] WalkthroughEngine: watching PID \(targetPID) for '\(step.elementName)'")
    }

    // MARK: - Mouse Event Monitoring

    /// Installs a global NSEvent monitor for left-click and right-click events.
    ///
    /// Why this is needed: the AXObserver and AX polling timer only detect changes in
    /// keyboard focus (kAXFocusedUIElementAttribute). Most mouse-driven interactions —
    /// Finder sidebar clicks, right-clicks opening context menus, System Settings category
    /// selection — do NOT change keyboard focus and are therefore invisible to those paths.
    ///
    /// This monitor fires on any mouse click, immediately runs the AX check in case focus
    /// did change, then schedules an AI screenshot validation 0.6s later so the UI has
    /// time to visually settle (context menu to appear, sidebar to update, etc.) before
    /// the screenshot is taken.
    private func startMouseEventMonitoring(for step: WalkthroughStep, allSteps: [WalkthroughStep], generation: Int) {
        if let existingMonitor = mouseEventMonitor {
            NSEvent.removeMonitor(existingMonitor)
        }

        mouseEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseDown]
        ) { [weak self] clickedEvent in
            Task { @MainActor [weak self] in
                guard let self = self,
                      generation == self.currentStepGeneration else { return }

                // Use AX hit-testing to identify exactly which element was clicked.
                // This gives us ground-truth label data without taking a screenshot,
                // so we can reject wrong-element clicks immediately without any AI call.
                let clickLocationInAppKitCoords = NSEvent.mouseLocation
                let clickedElementLabel = self.getAXElementLabel(atAppKitPoint: clickLocationInAppKitCoords)

                if let label = clickedElementLabel, !label.isEmpty {
                    // We have an AX label — compare directly against the expected element name.
                    // Accept if the label contains the target OR the target contains the label
                    // (handles cases like label="Downloads" when target="Downloads Folder").
                    let labelLowercased = label.lowercased()
                    let targetLowercased = step.elementName.lowercased()
                    let isCorrectElement = labelLowercased == targetLowercased
                        || labelLowercased.contains(targetLowercased)
                        || (targetLowercased.contains(labelLowercased) && label.count > 3)

                    if isCorrectElement {
                        // Exact match — complete the step without any AI call.
                        if case .executing(let currentSteps, let currentIndex) = self.state {
                            self.completeCurrentStep(steps: currentSteps, currentIndex: currentIndex)
                        }
                    }
                    // Wrong element — silently ignore. No AI validation needed.
                    return
                }

                // No AX label available (some elements don't expose one, e.g. canvas areas,
                // custom controls). Wait 0.6s for the UI to settle after the click, then fire
                // AI screenshot validation as a last resort.
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard generation == self.currentStepGeneration else { return }

                guard !self.isTypingStepActive,
                      !self.isAIValidationInProgress,
                      Date().timeIntervalSince(self.lastAIValidationDate) >= self.minimumSecondsBetweenAIValidations,
                      case .executing(let currentSteps, let currentIndex) = self.state,
                      currentIndex < currentSteps.count else { return }

                let currentStep = currentSteps[currentIndex]
                self.isAIValidationInProgress = true
                self.lastAIValidationDate = Date()

                Task {
                    await self.validateStepCompletionViaAIScreenshot(
                        step: currentStep,
                        steps: currentSteps,
                        currentIndex: currentIndex,
                        generation: generation
                    )
                }
            }
        }
    }

    /// Returns the AX accessibility label of the UI element at the given AppKit screen point.
    /// AppKit uses bottom-left origin (Y increases upward); AX/Quartz uses top-left origin
    /// (Y increases downward), so we flip Y relative to the main screen height before querying.
    /// Tries kAXTitleAttribute, then kAXDescriptionAttribute, then kAXValueAttribute in order.
    private func getAXElementLabel(atAppKitPoint appKitPoint: CGPoint) -> String? {
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let axX = Float(appKitPoint.x)
        let axY = Float(mainScreenHeight - appKitPoint.y)

        let systemWideElement = AXUIElementCreateSystemWide()
        var axElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWideElement, axX, axY, &axElement) == .success,
              let axElement = axElement else { return nil }

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &titleRef)
        if let title = titleRef as? String, !title.isEmpty { return title }

        var descriptionRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXDescriptionAttribute as CFString, &descriptionRef)
        if let description = descriptionRef as? String, !description.isEmpty { return description }

        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueRef)
        if let value = valueRef as? String, !value.isEmpty { return value }

        return nil
    }

    // MARK: - AX Polling

    /// Starts a 0.5-second repeating timer that reads the system-wide focused element and
    /// compares it to the expected step element. This catches button clicks and menu selections
    /// that don't always emit AXObserver focus-changed notifications.
    private func startAXPolling(for step: WalkthroughStep, allSteps: [WalkthroughStep], generation: Int) {
        axPollingTimer?.invalidate()
        // 0.5s interval instead of 0.3s — the mouse event monitor now handles real-time
        // click detection, so the polling timer is a secondary fallback for keyboard-driven
        // interactions. Reducing frequency cuts synchronous AXUIElementCopyAttributeValue
        // calls on the main thread, which was causing perceptible lag when the target app
        // (e.g. System Settings, Finder under memory pressure) was slow to respond.
        axPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkFocusedElementForStepCompletion(step: step, allSteps: allSteps, generation: generation)
            }
        }
    }

    /// Reads the system-wide focused element via AX and checks whether it matches the current step's
    /// expected element. If it does, marks the step complete. This runs every 0.3 seconds as a
    /// fast supplement to the AXObserver — it catches interactions (clicks, menu picks) that don't
    /// always emit a focus-changed notification.
    private func checkFocusedElementForStepCompletion(
        step: WalkthroughStep,
        allSteps: [WalkthroughStep],
        generation: Int
    ) {
        guard generation == currentStepGeneration,
              case .executing(let steps, let currentIndex) = state,
              currentIndex < steps.count else { return }

        let currentStep = steps[currentIndex]

        // Read the currently focused element from the system-wide AX tree.
        // Done before any per-path guards so both the typing path and the label-match
        // path can share this single AX call.
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        ) == .success,
              let focusedElement = focusedElementRef else { return }

        let currentlyFocusedElement = focusedElement as! AXUIElement

        // --- Typing step path ---
        // Runs before the elementName guard so typing steps complete even when
        // elementName is empty (some typing steps have no specific target element).
        if let expectedTypingText = currentStepExpectedTypingText {
            let secondsSinceStepStart = Date().timeIntervalSince(currentStepTypingStartDate ?? .distantPast)

            // Wait 1.5s after step start before reading or polling anything.
            // This gives the user time to dismiss Spotlight, click into the correct field,
            // and start typing. Capturing the element immediately at step start would lock
            // onto the wrong element (e.g. Spotlight search or the previous field).
            let typingPollerStartDelaySeconds: TimeInterval = 1.5
            guard secondsSinceStepStart >= typingPollerStartDelaySeconds else { return }

            // First tick after the delay: capture whichever element now has keyboard focus.
            // By this point the user has had time to navigate to the intended field.
            // currentStepTypingTargetElement was intentionally left nil at step start.
            if currentStepTypingTargetElement == nil {
                currentStepTypingTargetElement = currentlyFocusedElement
                LumaLogger.log("[Luma] Typing poller: capturing focused element after delay")
            }

            // Collect typed text from all available AX sources. Rich text editors like
            // Notes expose their content via AXTextArea descendants of the window rather
            // than through the focused element's AXValue, so a single-source read misses them.
            let currentValue = readTypedTextFromAllSources(currentlyFocusedElement: currentlyFocusedElement)
            let isMatch = !currentValue.isEmpty
                && currentValue.lowercased().contains(expectedTypingText.lowercased())

            // Log every tick as required — truncate long values (e.g. full Notes documents)
            LumaLogger.log("[Luma] Typing poll: current='\(String(currentValue.prefix(80)))' expected='\(expectedTypingText)' match=\(isMatch)")

            if isMatch && secondsSinceStepStart >= minimumTypingStepElapsedSeconds {
                LumaLogger.log("[Luma] WalkthroughEngine: typing step complete — '\(expectedTypingText)' found after \(String(format: "%.1f", secondsSinceStepStart))s")
                // Clear the flag before advancing — advanceToNextStep guards on it,
                // so we must clear it here (as the exclusive owner) before calling complete.
                isTypingStepActive = false
                completeCurrentStep(steps: steps, currentIndex: currentIndex)
                return
            }

            // Safety timeout: give up and advance so the walkthrough never stalls.
            // Timeout scales with expected text length — longer sentences get more time.
            if secondsSinceStepStart >= typingStepTimeoutSeconds(for: expectedTypingText) {
                LumaLogger.log("[Luma] WalkthroughEngine: typing step timed out after \(String(format: "%.0f", secondsSinceStepStart))s — advancing anyway")
                isTypingStepActive = false
                completeCurrentStep(steps: steps, currentIndex: currentIndex)
                return
            }

            return
        }

        // Non-typing path: guard on elementName then do label match + dwell.
        guard !currentStep.elementName.isEmpty else { return }

        let axElement = currentlyFocusedElement

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &titleRef)
        let elementTitle = (titleRef as? String) ?? ""

        var descriptionRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXDescriptionAttribute as CFString, &descriptionRef)
        let elementDescription = (descriptionRef as? String) ?? ""

        let elementLabel = elementTitle.isEmpty ? elementDescription : elementTitle

        guard !elementLabel.isEmpty else {
            // No label on the focused element — treat as no match and reset any active dwell
            // so we don't complete from a previous match that can no longer be verified.
            if axMatchDwellStartDate != nil {
                axMatchDwellStartDate = nil
                LumaLogger.log("[Luma] WalkthroughEngine: AX poll dwell reset — focused element has no label")
            }
            return
        }

        let labelLower = elementLabel.lowercased()
        let expectedLower = currentStep.elementName.lowercased()

        let isMatch = labelLower == expectedLower
            || labelLower.contains(expectedLower)
            || (expectedLower.contains(labelLower) && labelLower.count > 3)

        if isMatch {
            // Safety: the typing path above should have returned already, but if
            // isTypingStepActive is true here the polling timer must not fire a completion.
            guard !isTypingStepActive else { return }

            if axMatchDwellStartDate == nil {
                // First time we see this match — start the dwell clock
                axMatchDwellStartDate = Date()
                LumaLogger.log("[Luma] WalkthroughEngine: AX poll dwell started on '\(elementLabel)'")
            } else if Date().timeIntervalSince(axMatchDwellStartDate!) >= minimumAXMatchDwellSeconds {
                // Match held continuously for the required dwell — safe to complete
                LumaLogger.log("[Luma] WalkthroughEngine: AX poll dwell complete on '\(elementLabel)' — step complete")
                completeCurrentStep(steps: steps, currentIndex: currentIndex)
            }
        } else {
            // Focused element no longer matches — reset dwell so the next match
            // must hold for a full minimumAXMatchDwellSeconds before completing.
            if axMatchDwellStartDate != nil {
                axMatchDwellStartDate = nil
                LumaLogger.log("[Luma] WalkthroughEngine: AX poll dwell reset — '\(elementLabel)' doesn't match '\(currentStep.elementName)'")
            }
        }
    }

    // MARK: - AX Event Handling

    /// Called by the AXObserver C callback (via Task @MainActor) on every UI event in the target app.
    ///
    /// Two-path validation:
    ///   Fast path — AX label matches expected element name → complete immediately
    ///   Slow path — debounced AI screenshot validation for events that AX can't label (button
    ///               clicks, context menu selections, dialog openings, etc.)
    private func handleAccessibilityNotification(element: AXUIElement, notification: String, generation: Int) {
        // Drop any callback whose generation doesn't match the current step.
        // This eliminates all races from stale observers and in-flight Task closures.
        guard generation == currentStepGeneration else { return }

        guard case .executing(let steps, let currentIndex) = state,
              currentIndex < steps.count else { return }

        let currentStep = steps[currentIndex]

        // If the step has no specific element requirement, any action in the right app counts
        if currentStep.elementName.isEmpty {
            completeCurrentStep(steps: steps, currentIndex: currentIndex)
            return
        }

        // --- Read the element's accessible label ---
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let rawTitle = (titleRef as? String) ?? ""

        var descriptionRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descriptionRef)
        let rawDescription = (descriptionRef as? String) ?? ""

        // Prefer title; fall back to description for elements that only have one
        let elementLabel = rawTitle.isEmpty ? rawDescription : rawTitle

        LumaLogger.log("[Luma] AX event: \(notification) on '\(elementLabel)'")

        // --- Typing step: delegate all completion to the polling timer ---
        // For typing steps, kAXValueChangedNotification fires on every individual keystroke,
        // making it impossible to know when the user has finished. Completion is handled
        // exclusively by the 0.5s polling timer in checkFocusedElementForStepCompletion,
        // which also enforces a minimum elapsed time. Returning here suppresses both the
        // label-match path and AI screenshot validation during active typing.
        if currentStepExpectedTypingText != nil {
            return
        }

        // --- Fast path: AX label matches ---
        // Three conditions (in order of precision):
        //   1. Exact match
        //   2. Label contains the expected name (e.g. "Save As..." matches "Save")
        //   3. Expected name contains the label, but only for labels > 3 chars
        //      (e.g. "File" label matches step element "File menu")
        if !elementLabel.isEmpty {
            let labelLower = elementLabel.lowercased()
            let expectedLower = currentStep.elementName.lowercased()

            let isMatch = labelLower == expectedLower
                || labelLower.contains(expectedLower)
                || (expectedLower.contains(labelLower) && labelLower.count > 3)

            if isMatch {
                // Start the dwell clock rather than completing immediately.
                // Completing on the first focus event causes false positives when the user
                // is tabbing past the target element. The AX polling timer will complete
                // the step once minimumAXMatchDwellSeconds of continuous match have elapsed.
                if axMatchDwellStartDate == nil {
                    axMatchDwellStartDate = Date()
                    LumaLogger.log("[Luma] WalkthroughEngine: fast-path dwell started on '\(elementLabel)'")
                }
                return
            }

            // Known label but not the target — speak a gentle correction.
            // Only for focus events (not value/window events which are less user-intentional).
            // Not while an AI validation is in progress (avoids contradictory feedback).
            if notification == kAXFocusedUIElementChangedNotification && !isAIValidationInProgress {
                let timeSinceLastCorrection = Date().timeIntervalSince(lastCorrectionDate)
                if timeSinceLastCorrection >= minimumSecondsBetweenCorrections {
                    lastCorrectionDate = Date()
                    ttsClient.speak("We need \(currentStep.elementName). \(currentStep.instruction)")
                    let correctionBubbleText = "→ \(currentStep.elementName)"
                    activePointingTask?.cancel()
                    activePointingTask = Task {
                        await self.pointAtStepElement(
                            elementName: currentStep.elementName,
                            appBundleID: currentStep.appBundleID,
                            isMenuBar: currentStep.isMenuBar,
                            bubbleText: correctionBubbleText
                        )
                    }
                }
            }
        }

        // --- Slow path: AI screenshot validation ---
        // Fires on ANY AX event (not just focus changes) so it catches button clicks, menu
        // selections, dialog opens — things that don't always emit a labelled focus event.
        // Debounced: at most one AI call every minimumSecondsBetweenAIValidations seconds.
        let timeSinceLastValidation = Date().timeIntervalSince(lastAIValidationDate)
        guard !isAIValidationInProgress && timeSinceLastValidation >= minimumSecondsBetweenAIValidations else { return }

        isAIValidationInProgress = true
        lastAIValidationDate = Date()

        Task {
            await self.validateStepCompletionViaAIScreenshot(
                step: currentStep,
                steps: steps,
                currentIndex: currentIndex,
                generation: generation
            )
        }
    }

    // MARK: - AI Screenshot Validation

    /// Captures the screen and asks the AI whether the user has completed the current step.
    /// Advances the walkthrough if the AI confirms completion.
    ///
    /// Checks `generation == currentStepGeneration` three times:
    ///   1. Before capturing the screenshot (early exit if already advanced)
    ///   2. After the capture (step may have been skipped/cancelled during the await)
    ///   3. After the API call returns (same reason)
    private func validateStepCompletionViaAIScreenshot(
        step: WalkthroughStep,
        steps: [WalkthroughStep],
        currentIndex: Int,
        generation: Int
    ) async {
        defer {
            // Always clear the in-progress flag, even on early return or error
            isAIValidationInProgress = false
        }

        // Typing steps own their own completion path — AI validation must not race with
        // the polling timer. The flag is cleared by the poller before it calls complete.
        guard !isTypingStepActive else {
            LumaLogger.log("[Luma] WalkthroughEngine: AI validation blocked — typing step is active")
            return
        }

        // Pre-check before expensive work
        guard generation == currentStepGeneration,
              case .executing(_, let activeIndex) = state,
              activeIndex == currentIndex else { return }

        do {
            // Guard: only validate when the target app is frontmost.
            // AI validation takes a full screenshot. If another app (e.g. Xcode) is frontmost,
            // the screenshot shows that app's content instead of the target app, causing the
            // model to read incorrect UI and produce false COMPLETED or INCOMPLETE verdicts.
            // Skipping here lets the AX polling and observer paths continue watching for the
            // correct interaction without burning an API call on a useless screenshot.
            if let targetBundleID = step.appBundleID {
                let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if frontmostBundleID?.lowercased() != targetBundleID.lowercased() {
                    LumaLogger.log("[Luma] WalkthroughEngine: skipping AI validation — frontmost '\(frontmostBundleID ?? "nil")' ≠ target '\(targetBundleID)'")
                    return
                }
            }

            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

            // Post-capture check — the user may have skipped or cancelled during the async await
            guard generation == currentStepGeneration,
                  case .executing(_, let activeIndex) = state,
                  activeIndex == currentIndex else { return }

            let imageTuples = screenCaptures.map { (data: $0.imageData, label: $0.label) }

            let targetElementDescription = step.elementName.isEmpty
                ? "(no specific element — any relevant action counts)"
                : "\"\(step.elementName)\""

            let validationSystemPrompt = """
            You are validating whether a macOS user completed a specific walkthrough step.

            Instruction given to the user: "\(step.instruction)"
            Target UI element: \(targetElementDescription)

            Look at the screenshot and answer: has this specific step been completed?

            Answer COMPLETED only if there is clear visual evidence the action was taken:
            - A context menu is currently open (proves a right-click happened)
            - A new dialog, sheet, alert, or window has appeared as a direct result of the action
            - The main content area now shows content that would only appear after interacting with the target (e.g. a folder's contents are visible after clicking that folder)
            - A sidebar item or list row matching the target is clearly highlighted/selected AND the content area reflects that selection
            - The target element shows a clear activated or pressed state that it would not have in its idle state

            Answer INCOMPLETE if:
            - No context menu, dialog, or new content is visible
            - The screen looks like a normal idle state — elements are visible but not interacted with
            - The target element is present on screen but shows no sign of having been clicked
            - You are not certain that the action described in the instruction has actually occurred

            Do not answer COMPLETED just because the target element is visible. It must show evidence of being actively interacted with.

            Reply with one word only: COMPLETED or INCOMPLETE
            """

            // Validation only needs 1 word ("COMPLETED" or "INCOMPLETE") — keep token budget tiny
            // so this call returns fast and doesn't waste quota.
            let (aiResponse, _) = try await APIClient.shared.analyzeImage(
                images: imageTuples,
                systemPrompt: validationSystemPrompt,
                conversationHistory: [],
                userPrompt: "Has the user completed the step?",
                maxOutputTokens: 16
            )

            let trimmedResponse = aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            LumaLogger.log("[Luma] WalkthroughEngine AI validation: '\(trimmedResponse)'")

            // Post-API check — avoid acting on a result for a step that's already gone
            guard generation == currentStepGeneration,
                  case .executing(_, let activeIndex) = state,
                  activeIndex == currentIndex else { return }

            // Re-check here because isTypingStepActive may have become true AFTER the
            // guard at the top of this function passed but BEFORE the async API call returned.
            // Without this site-of-action check, a COMPLETED verdict from a slow API response
            // can advance the step while the polling timer is still waiting for typed text.
            guard !isTypingStepActive else {
                LumaLogger.log("[Luma] Ignoring AI validation result — typing step active")
                return
            }

            if trimmedResponse.hasPrefix("COMPLETED") {
                completeCurrentStep(steps: steps, currentIndex: currentIndex)
            }
        } catch {
            LumaLogger.log("[Luma] WalkthroughEngine AI validation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Step Completion

    /// Marks the current step as done, speaks the confirmation, then advances after a short pause.
    private func completeCurrentStep(steps: [WalkthroughStep], currentIndex: Int) {
        // Capture isTypingStepActive NOW — before stopActiveStepAndCleanUp resets it to false.
        // stopActiveStepAndCleanUp runs synchronously below and clears the flag, so checking
        // self.isTypingStepActive inside the Task (0.4s later) would always see false, making
        // the guard there meaningless. Capturing here lets the Task know whether completion
        // was triggered erroneously while a typing step was still active.
        //
        // Added at: completeCurrentStep(), Task block before advanceToNextStep() call
        let wasTypingStepActiveAtCompletionTime = isTypingStepActive

        stopActiveStepAndCleanUp()
        ttsClient.speak("Got it.")

        // Use Task @MainActor + sleep instead of DispatchQueue.main.asyncAfter.
        // This keeps us inside Swift's structured concurrency and actor model, avoiding the
        // actor-isolation gap that asyncAfter creates between dispatch and execution.
        let capturedSteps = steps
        let capturedIndex = currentIndex

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000) // 0.4 seconds — halved from 0.8s
            // Guard on the flag value captured before cleanup — isTypingStepActive is already
            // false by now because stopActiveStepAndCleanUp ran synchronously above.
            guard !wasTypingStepActiveAtCompletionTime else {
                LumaLogger.log("[Luma] Nudge timer blocked — typing step active")
                return
            }
            self.advanceToNextStep(steps: capturedSteps, completedIndex: capturedIndex)
        }
    }

    // MARK: - Step Advancement

    /// Moves to the step after `completedIndex`, or completes the walkthrough if that was the last.
    ///
    /// Guards on both the state AND the index to prevent double-advancement.
    /// Without the index guard, a stale Task from a previous completion can call advanceToNextStep
    /// on a step that's already been advanced (e.g., after a quick skip), skipping an extra step.
    private func advanceToNextStep(steps: [WalkthroughStep], completedIndex: Int) {
        // While a typing step is active, the polling timer is the exclusive owner of step
        // completion. Any advance call from a stale timer or notification must be dropped.
        guard !isTypingStepActive else {
            LumaLogger.log("[Luma] WalkthroughEngine: advanceToNextStep blocked — typing step is active")
            return
        }

        // Only advance if the engine is still executing the step we think it is.
        // This guard catches races where completeCurrentStep fires twice or where
        // skipCurrentStep was called during the 0.8s sleep.
        guard case .executing(let currentSteps, let currentIndex) = state,
              currentIndex == completedIndex else {
            LumaLogger.log("[Luma] WalkthroughEngine: advanceToNextStep dropped (state changed before advancing)")
            return
        }

        let nextIndex = completedIndex + 1

        if nextIndex >= currentSteps.count {
            finishWalkthrough()
            return
        }

        state = .executing(steps: currentSteps, currentIndex: nextIndex)
        executeStep(currentSteps[nextIndex], allSteps: currentSteps)
    }

    // MARK: - Completion

    private func finishWalkthrough() {
        stopActiveStepAndCleanUp()
        cursorGuide.clearGuidance()
        stepsSinceLastClaudeVerification = 0
        state = .complete
        ttsClient.speak("You did it! Task complete.")

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000) // 2.5 seconds
            if case .complete = self.state {
                self.state = .idle
            }
        }
    }

    // MARK: - Nudge Timer

    /// Schedules a one-shot timer that fires `fireNudge` after `step.timeoutSeconds`.
    /// The timer reschedules itself after each nudge so nudges keep repeating until the step ends.
    private func startNudgeTimer(for step: WalkthroughStep, allSteps: [WalkthroughStep], generation: Int) {
        nudgeTimer?.invalidate()
        nudgeTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(step.timeoutSeconds),
            repeats: false
        ) { [weak self] _ in
            // Dispatch to main actor via Task to stay within Swift's actor model
            Task { @MainActor [weak self] in
                self?.fireNudge(for: step, allSteps: allSteps, generation: generation)
            }
        }
    }

    /// Speaks a reminder and re-points the cursor, then reschedules the nudge timer.
    /// After maximumTotalNudgesBeforeDisengaging nudges, disengages so the user isn't pestered.
    ///
    /// Function name: fireNudge(for:allSteps:generation:)
    private func fireNudge(for step: WalkthroughStep, allSteps: [WalkthroughStep], generation: Int) {
        // FIRST guard — typing steps kill the nudge timer when they start (executeStep),
        // but a Task already dispatched from the timer callback may still be in-flight.
        // Check isTypingStepActive before anything else so no nudge logic runs at all.
        guard !isTypingStepActive else {
            LumaLogger.log("[Luma] Nudge timer blocked — typing step active")
            return
        }

        // Drop nudges from previous steps using the generation counter
        guard generation == currentStepGeneration,
              case .executing = state else { return }

        nudgeCount += 1

        // Disengage after too many nudges — nudge-count-based so it works correctly with
        // any timeoutSeconds value (time-based logic broke when timeoutSeconds dropped to 15).
        if nudgeCount > maximumTotalNudgesBeforeDisengaging {
            ttsClient.speak("Disengaging — call me back when you need help.")
            cancelWalkthrough()
            return
        }

        if nudgeCount >= maximumInstructionNudgesBeforeSwitchingToPatientMessage {
            ttsClient.speak("Take your time, I'm here when you're ready.")
        } else {
            ttsClient.speak("Still on step \(step.index + 1). \(step.instruction)")
        }

        // Re-point the cursor so the user can find the target element
        if !step.elementName.isEmpty {
            let nudgeBubbleText = "→ \(step.elementName)"
            activePointingTask?.cancel()
            activePointingTask = Task {
                await self.pointAtStepElement(
                    elementName: step.elementName,
                    appBundleID: step.appBundleID,
                    isMenuBar: step.isMenuBar,
                    bubbleText: nudgeBubbleText
                )
            }
        }

        // Reschedule — nudges keep firing until the step ends
        startNudgeTimer(for: step, allSteps: allSteps, generation: generation)
    }

    // MARK: - Typing Step Detection

    /// Inspects `instruction` for a typing keyword ("type", "write", or "enter") followed
    /// by a quoted string, and returns the quoted text if found.
    ///
    /// Examples that match:
    ///   "Type \"Hello World\" in the search field"  →  "Hello World"
    ///   "Enter 'John Smith' in the name box"        →  "John Smith"
    ///   "Write \"notes here\" and save"             →  "notes here"
    ///
    /// Returns nil when the instruction is not a typing step or contains no quoted text,
    /// so the normal AX label-match / dwell path handles completion instead.
    private func extractExpectedTypingText(from instruction: String) -> String? {
        let lowercased = instruction.lowercased()

        // Navigation steps that contain typing keywords but are NOT typing steps.
        // "Open Spotlight and type..." or "Press Cmd+Space" steps use the keyboard
        // to launch a launcher, not to enter text into a document or field.
        let isNavigationStep = lowercased.contains("spotlight")
            || lowercased.contains("command + space")
            || lowercased.contains("cmd + space")

        guard !isNavigationStep else { return nil }

        // Check for at least one typing keyword anywhere in the instruction.
        // Using " " suffix and prefix checks avoids false matches on substrings
        // like "reenter" or "typeface".
        let hasTypingKeyword = lowercased.contains("type ")
            || lowercased.contains("write ")
            || lowercased.contains("enter ")
            || lowercased.hasPrefix("type")
            || lowercased.hasPrefix("write")
            || lowercased.hasPrefix("enter")

        guard hasTypingKeyword else { return nil }

        // Extract the first double-quoted string (e.g. "Hello World")
        if let doubleQuoteRange = instruction.range(of: #""[^"]+""#, options: .regularExpression) {
            var quoted = String(instruction[doubleQuoteRange])
            quoted.removeFirst() // opening "
            quoted.removeLast()  // closing "
            if !quoted.isEmpty { return quoted }
        }

        // Fall back to single-quoted string (e.g. 'Hello World')
        if let singleQuoteRange = instruction.range(of: #"'[^']+'"#, options: .regularExpression) {
            var quoted = String(instruction[singleQuoteRange])
            quoted.removeFirst() // opening '
            quoted.removeLast()  // closing '
            if !quoted.isEmpty { return quoted }
        }

        // Keyword present but no quoted text — not a typing step we can validate precisely
        return nil
    }

    // MARK: - Typing Text Discovery

    /// Reads typed text from every available AX source and returns the longest non-empty string.
    ///
    /// Why multiple sources: rich text editors like Notes use an AXTextArea element that is a
    /// descendant of the window, not the focused element. A single kAXValueAttribute read on the
    /// focused element returns nothing (or the label of a container). Checking all sources ensures
    /// text is found regardless of how the app exposes its editor.
    ///
    /// Sources checked in order:
    ///   1. kAXValue of the element captured at step start
    ///   2. kAXValue of the current system-wide focused element
    ///   3. kAXSelectedText of the current focused element (fallback for apps that don't expose full value)
    ///   4. kAXValue of the first AXTextArea found in the frontmost window's subtree
    private func readTypedTextFromAllSources(currentlyFocusedElement: AXUIElement) -> String {
        var candidates: [String] = []

        // Source 1: value of the element captured after the 1.5s delay
        if let capturedElement = currentStepTypingTargetElement {
            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(capturedElement, kAXValueAttribute as CFString, &valueRef)
            if let value = valueRef as? String, !value.isEmpty {
                candidates.append(value)
            }
        }

        // Source 2: value of the current system-wide focused element
        var focusedValueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(currentlyFocusedElement, kAXValueAttribute as CFString, &focusedValueRef)
        if let value = focusedValueRef as? String, !value.isEmpty {
            candidates.append(value)
        }

        // Source 3: selected text of the focused element — some editors expose only the
        // active selection via kAXSelectedText rather than the full document via kAXValue
        var selectedTextRef: CFTypeRef?
        AXUIElementCopyAttributeValue(currentlyFocusedElement, kAXSelectedTextAttribute as CFString, &selectedTextRef)
        if let value = selectedTextRef as? String, !value.isEmpty {
            candidates.append(value)
        }

        // Source 4: AXTextArea descendant of the frontmost window
        // Notes wraps its rich text canvas in an AXTextArea several levels below the window.
        if let textAreaValue = findAXTextAreaValueInFrontmostWindow() {
            candidates.append(textAreaValue)
        }

        // Return the longest candidate — a full document is more likely to contain
        // the target substring than a short selection or a field label.
        return candidates.max(by: { $0.count < $1.count }) ?? ""
    }

    /// Searches the frontmost application's focused window for an AXTextArea element
    /// and returns its kAXValue. Notes and other rich-text editors use AXTextArea for
    /// the editing canvas, which is a descendant of the window rather than the focused element.
    private func findAXTextAreaValueInFrontmostWindow() -> String? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)

        var focusedWindowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowRef
        ) == .success, let focusedWindow = focusedWindowRef else { return nil }

        return findAXTextAreaValueRecursively(in: focusedWindow as! AXUIElement, depth: 0)
    }

    /// Recursively walks `element`'s AX children looking for an AXTextArea with a non-empty
    /// kAXValue. Returns the first match found (depth-first). Capped at depth 15 to prevent
    /// runaway traversal on apps with deeply nested AX trees.
    private func findAXTextAreaValueRecursively(in element: AXUIElement, depth: Int) -> String? {
        guard depth < 15 else { return nil }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String, role == kAXTextAreaRole as String {
            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
            if let value = valueRef as? String, !value.isEmpty {
                return value
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenRef
        ) == .success, let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children {
            if let found = findAXTextAreaValueRecursively(in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    // MARK: - NudgeEngine Integration

    /// Called by step-completion paths to record success and trigger periodic Claude verification.
    /// Uses NudgeEngine for the spoken "step complete" message — no API call for routine advances.
    func handleStepSuccess() {
        guard !isTypingStepActive else {
            LumaLogger.log("[Luma] WalkthroughEngine: handleStepSuccess blocked — typing step is active")
            return
        }

        nudgeCount = 0
        stepsSinceLastClaudeVerification += 1
        NudgeEngine.speak(.stepComplete)

        if stepsSinceLastClaudeVerification >= claudeVerificationInterval {
            stepsSinceLastClaudeVerification = 0
            verifyProgressWithClaude()
        }
    }

    /// Called when a step fails or the user takes an incorrect action.
    /// After three consecutive nudges, escalates to Claude once instead of continuing to repeat.
    func handleStepFailure(situation: NudgeSituation) {
        nudgeCount += 1

        if nudgeCount >= 3 {
            // Stuck — speak the escalation message, reset the nudge counter, and call Claude once.
            nudgeCount = 0
            NudgeEngine.speak(.stuckAfterThreeNudges)
            escalateToClaude()
            return
        }

        // Offline nudge — no API call
        NudgeEngine.speak(situation)
    }

    /// Triggers a one-off AI screenshot validation to check whether the user has made
    /// any progress. Used when the user is stuck and the normal nudge cycle has stalled.
    /// Reuses the existing validateStepCompletionViaAIScreenshot path — no new AI call logic.
    private func escalateToClaude() {
        guard case .executing(let steps, let currentIndex) = state else { return }
        let capturedGeneration = currentStepGeneration
        let currentStep = steps[currentIndex]

        LumaLogger.log("[Luma] WalkthroughEngine: escalating to Claude after 3 nudges — step \(currentIndex + 1)")

        Task {
            await validateStepCompletionViaAIScreenshot(
                step: currentStep,
                steps: steps,
                currentIndex: currentIndex,
                generation: capturedGeneration
            )
        }
    }

    /// Periodic Claude check called every claudeVerificationInterval successful steps.
    /// Takes a screenshot and validates the current step to confirm overall walkthrough health.
    /// If the current step is already complete, the existing advance logic handles it normally.
    private func verifyProgressWithClaude() {
        guard case .executing(let steps, let currentIndex) = state else { return }
        let capturedGeneration = currentStepGeneration
        let currentStep = steps[currentIndex]

        LumaLogger.log("[Luma] WalkthroughEngine: periodic Claude verification at step \(currentIndex + 1) (every \(claudeVerificationInterval) steps)")

        Task {
            await validateStepCompletionViaAIScreenshot(
                step: currentStep,
                steps: steps,
                currentIndex: currentIndex,
                generation: capturedGeneration
            )
        }
    }
}
