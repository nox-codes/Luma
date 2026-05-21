//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

extension Notification.Name {
    /// Posted when screen recording permission transitions from denied to granted
    /// during a live session. Observers should reinitialize their ScreenCaptureKit
    /// state rather than requiring an app restart.
    static let lumaScreenRecordingPermissionGranted = Notification.Name("lumaScreenRecordingPermissionGranted")
}

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

/// Tracks whether the classifier is currently idle or executing a task.
/// Used to forward agent follow-ups to the active session rather than
/// re-running the full classification pipeline.
enum LumaSystemState: Equatable {
    case idle
    /// Currently executing the given path.
    case executing(path: LumaExecutionPath)
}

/// A completed or interrupted user request kept as read-only background context
/// for future AI prompts. Injected as "Previously..." entries in the system prompt
/// so the AI treats prior tasks as done — never as active to-dos.
struct LumaCompletedTask {
    /// What the user originally asked for.
    let userRequest: String
    /// The AI's spoken response, or nil if the task was interrupted before a response was delivered.
    let outcome: String?
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let tutorialManager = PostOnboardingTutorialManager()
    /// Fires after 30 seconds of no interaction and hides all visible Luma UI.
    /// The menu bar icon stays visible. Suspended during onboarding.
    let idleTimer = LumaIdleTimer(interval: 30)
    /// Agent completion summary to surface in the pointer-phrase speech bubble
    /// that appears next to the cursor. Set when a task transitions running→ready;
    /// auto-cleared after 6 seconds so the bubble fades away naturally.
    @Published var agentSummaryBubbleText: String?

    /// Shared API client that routes requests to whichever profile the user configured.
    /// Reads the active profile from ProfileManager on each request so profile switches
    /// take effect immediately without restarting the app.
    private let apiClient: APIClient = .shared

    /// Native macOS TTS — fully local, no external API calls.
    private let nativeTTSClient = NativeTTSClient()

    /// The user request currently being processed by the AI pipeline.
    /// Replaced each time a new request arrives — only one request is ever active.
    /// Archived to taskHistory (as interrupted) when a new request preempts it.
    private var activeTaskRequest: String?

    /// Completed and interrupted requests kept as read-only context for AI prompts.
    /// Injected into the system prompt as "Previously..." entries so the AI treats them
    /// as background context rather than active to-dos. Bounded to 10 entries.
    private var taskHistory: [LumaCompletedTask] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    /// True when voice input is unavailable (mic or speech recognition denied) so
    /// the panel shows a text field the user can type into instead of holding the hotkey.
    @Published private(set) var showTextInputFallback: Bool = false

    /// The last API error message, shown in the panel so the user can diagnose issues
    /// without needing to open Xcode. Cleared at the start of each new request.
    @Published private(set) var lastAPIErrorMessage: String? = nil

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var permissionProblemCancellable: AnyCancellable?
    /// Watches UserDefaults for the onboarding completion flag so the idle timer
    /// can resume the moment the user finishes onboarding.
    private var onboardingCompletedCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// Observer for the CursorGuide pointAt notification, which LIPE and CursorGuide post
    /// when they want the Luma cursor overlay to animate to a target element.
    /// Kept so we can remove it cleanly in stop().
    private var elementPointingObserver: NSObjectProtocol?

    /// Observer for macOS system screenshot shortcuts (Cmd+Shift+3/4/5).
    /// When detected the overlay hides for 2 seconds so it doesn't appear in the screenshot.
    private var screenshotShortcutObserver: NSObjectProtocol?
    private var agentTaskCompletedObserver: NSObjectProtocol?
    private var screenRecordingPermissionObserver: NSObjectProtocol?

    /// Task that restores the overlay visibility after the screenshot hide delay.
    private var screenshotHideRestoreTask: Task<Void, Never>?

    // MARK: - Intent Classifier State

    /// Tracks whether the system is currently executing a classified task.
    /// When `.executing`, new voice messages are forwarded as follow-ups to
    /// the active path rather than re-run through the classifier — prevents
    /// mid-task messages from clashing with a running agent or CLI command.
    @Published private(set) var systemExecutionState: LumaSystemState = .idle

    /// When set, the next voice input is a clarification answer for this original input.
    /// The two strings are combined before re-running the classifier.
    private var pendingClassifierOriginalInput: String?
    /// When set, the next voice input should be interpreted as a yes/no confirmation
    /// for the stored pending action (destructive/irreversible operations).
    /// The closure runs the action; nil means the user cancelled.
    private var pendingConfirmationAction: (() async -> Void)?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    // MARK: - Agent Sessions (v3)

    @Published var agentSessions: [AgentSession] = []
    @Published var activeAgentSessionID: UUID?
    @Published var isAgentModeEnabled: Bool = UserDefaults.standard.bool(forKey: "luma.agentMode.enabled")

    private var agentDockManager = LumaAgentDockWindowManager()
    /// Cancellables for observing each agent session's status/transcript changes.
    private var agentSessionObservationCancellables: [UUID: Set<AnyCancellable>] = [:]
    /// Whether an agent is currently recording voice via toggle (not push-to-talk).
    @Published var agentVoiceRecordingSessionID: UUID?
    /// Task for the active agent voice recording session.
    private var agentVoiceRecordingTask: Task<Void, Never>?

    /// The currently active agent session. Non-optional — start() guarantees
    /// at least one session exists via ensureDefaultAgentSession().
    var activeAgentSession: AgentSession {
        if let id = activeAgentSessionID,
           let session = agentSessions.first(where: { $0.id == id }) {
            return session
        }
        guard let first = agentSessions.first else {
            // Failsafe: return a disconnected session if called before start()
            return AgentSession()
        }
        return first
    }


    /// Legacy property kept for backwards compatibility — CompanionManager.selectedModel
    /// is no longer used for API calls (APIClient reads the model from ProfileManager.activeProfile).
    /// Kept as an observable so any UI binding to it doesn't crash.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? ""

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        apiClient.model = model
    }

    /// User preference for whether the Luma cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isLumaCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isLumaCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isLumaCursorEnabled")

    func setLumaCursorEnabled(_ enabled: Bool) {
        isLumaCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isLumaCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        LumaLogger.log("[Luma] start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()

        // Wire the idle timer's timeout to hide Luma's visible UI.
        idleTimer.onTimeout = { [weak self] in
            guard let self else { return }
            LumaLogger.log("[LumaIdleTimer] 30s idle — hiding Luma UI")
            self.overlayWindowManager.hideOverlay()
            self.isOverlayVisible = false
            NotificationCenter.default.post(name: .lumaDismissPanel, object: nil)
        }

        // Suspend the idle timer while onboarding is in progress.
        if !hasCompletedOnboarding {
            idleTimer.suspend()
        }

        // Resume the idle timer the moment onboarding finishes.
        onboardingCompletedCancellable = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let isOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
                if isOnboarded && self.idleTimer.isSuspended {
                    self.idleTimer.resume()
                    LumaLogger.log("[LumaIdleTimer] Onboarding complete — idle timer resumed")
                }
            }

        // Reinitialize ScreenCaptureKit when the user grants screen recording permission
        // during a live session so captures work immediately without an app restart.
        screenRecordingPermissionObserver = NotificationCenter.default.addObserver(
            forName: .lumaScreenRecordingPermissionGranted,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await CompanionScreenCaptureUtility.reinitializeCapture()
            }
        }

        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindPermissionProblemObservation()
        // Sync the persisted model selection into the API client so the first
        // request doesn't send an empty model string. Without this, apiClient.model
        // stays "" until the user opens the model picker and changes it.
        apiClient.model = selectedModel

        // APIClient.shared is already initialized as a singleton — its TLS warmup
        // fires on first access. Touch it here so the warmup handshake completes
        // well before the user's first push-to-talk interaction.
        _ = apiClient

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isLumaCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
            idleTimer.start()
        }

        // Listen for the pointAt notification from CursorGuide / LumaImageProcessingEngine.
        // These singletons post this notification when they want the Luma cursor overlay to
        // animate to a UI element. Setting detectedElementScreenLocation triggers the
        // BlueCursorView onChange handler which starts the bezier flight animation.
        elementPointingObserver = NotificationCenter.default.addObserver(
            forName: CursorGuide.pointAtNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            #if DEBUG
            EnergyDebugLogger.notifFired("pointAt")
            #endif
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let nsValue = notification.userInfo?[CursorGuide.targetPointUserInfoKey] as? NSValue else { return }
                let appKitPoint = nsValue.pointValue

                // Find which screen contains this AppKit point so BlueCursorView knows
                // which overlay window should animate (only the one on that screen does).
                let containingScreen = NSScreen.screens.first { $0.frame.contains(appKitPoint) }
                    ?? NSScreen.main

                self.detectedElementBubbleText = notification.userInfo?[CursorGuide.bubbleTextUserInfoKey] as? String
                self.detectedElementDisplayFrame = containingScreen?.frame
                // Setting this last triggers the onChange in BlueCursorView.
                self.detectedElementScreenLocation = appKitPoint
            }
        }

        // Hide the overlay for 2 seconds when the user presses a system screenshot shortcut
        // (Cmd+Shift+3/4/5) so Luma doesn't appear in their screenshot.
        screenshotShortcutObserver = NotificationCenter.default.addObserver(
            forName: GlobalPushToTalkShortcutMonitor.systemScreenshotShortcutDetectedNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            #if DEBUG
            EnergyDebugLogger.notifFired("screenshotShortcut")
            #endif
            Task { @MainActor [weak self] in
                guard let self, self.isOverlayVisible else { return }

                // Cancel any pending restore from a previous screenshot key press
                self.screenshotHideRestoreTask?.cancel()

                // Hide immediately so the overlay is gone before the system captures the screen
                self.overlayWindowManager.hideOverlay()
                self.isOverlayVisible = false

                // Restore after 2 seconds — long enough for the user to drag their selection
                self.screenshotHideRestoreTask = Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    self.overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                    self.isOverlayVisible = true
                }
            }
        }

        // Agent sessions are spawned on demand by the intent classifier or explicit
        // user voice commands. No sessions are created or restored at launch.

        // Listen for agent task completion to speak results and update overlay
        agentTaskCompletedObserver = NotificationCenter.default.addObserver(
            forName: AgentSession.taskCompletedNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            #if DEBUG
            EnergyDebugLogger.notifFired("agentTaskCompleted")
            #endif
            Task { @MainActor [weak self] in
                guard let self else { return }
                // "title" is only used for logging; the summary is already clean (tags
                // stripped, ≤150 chars) as produced by AgentSession.announceTaskCompletion.
                let agentTitle = notification.userInfo?["title"] as? String ?? "Agent"
                let summary = notification.userInfo?["summary"] as? String ?? "Task completed."

                // Ensure the cursor overlay is visible so the bubble can be shown
                if !self.isOverlayVisible {
                    self.overlayWindowManager.hasShownOverlayBefore = true
                    self.overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                    self.isOverlayVisible = true
                }

                // Speak the completion summary — no title prefix, just the one-liner.
                // Do NOT trigger cursor pointing on agent completion. The cursor should
                // stay in follow-cursor mode; pointing is only for UI element references.
                self.nativeTTSClient.speak(summary)

                // Show the completion summary in the pointer-phrase speech bubble
                // next to the cursor — the same blue bubble used for element pointing.
                // Auto-clears after 6 seconds so the bubble fades away naturally.
                self.agentSummaryBubbleText = summary
                Task {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    self.agentSummaryBubbleText = nil
                }

                // If the summary references a file path that exists on disk, open
                // it automatically so the user sees the result immediately
                if let filePath = Self.extractFilePathFromAgentSummary(summary),
                   FileManager.default.fileExists(atPath: filePath) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
                    LumaLogger.log("[Luma] Auto-opened result file: \(filePath)")
                }

                // Update dock to show new status
                self.updateAgentDock()

                // Auto-dismiss transient sessions (spawned by the classifier for a single task).
                // Persistent sessions (user-requested agents) remain until the user dismisses them.
                if let completedSessionId = notification.userInfo?["sessionId"] as? UUID,
                   let completedSession = self.agentSessions.first(where: { $0.id == completedSessionId }),
                   completedSession.isTransient {
                    // Small delay so the user can read the completion bubble before it disappears.
                    Task { [weak self] in
                        guard let self else { return }
                        try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds
                        // Only dismiss if the session is still completed/failed — if the user
                        // sent a follow-up prompt during this window, the session may be running
                        // again. In that case, promote it to persistent so it isn't killed mid-task.
                        if let sessionToCheck = self.agentSessions.first(where: { $0.id == completedSessionId }) {
                            if sessionToCheck.status == .running {
                                sessionToCheck.isTransient = false
                                LumaLogger.log("[Luma] Transient session promoted to persistent — received follow-up during auto-dismiss window: \(completedSessionId)")
                                return
                            }
                        }
                        await self.dismissAgentSession(id: completedSessionId)
                        LumaLogger.log("[Luma] Auto-dismissed transient agent session: \(completedSessionId)")
                    }
                }

                // Persist updated session state
                self.persistAllAgentSessions()

                LumaLogger.log("[Luma] Agent task completed — \(agentTitle): \(summary.prefix(80))")
            }
        }
    }

    /// Scans an agent completion summary for a file path that can be opened.
    /// Checks quoted paths first ("~/foo.txt"), then bare paths starting with / or ~.
    /// Returns the first path whose file actually exists on disk.
    private static func extractFilePathFromAgentSummary(_ summary: String) -> String? {
        let patterns = [
            #"[\"'`]([~\/][^\s\"'`\n]+)[\"'`]"#,   // quoted: "/path" or '~/path'
            #"(?:^|\s)(\/[^\s\n]+)"#,                // bare absolute: /some/path
            #"(?:^|\s)(~\/[^\s\n]+)"#                // bare tilde: ~/some/path
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(summary.startIndex..., in: summary)
            guard let match = regex.firstMatch(in: summary, range: range),
                  let captureRange = Range(match.range(at: 1), in: summary) else { continue }
            let rawPath = String(summary[captureRange])
            let expandedPath = (rawPath as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expandedPath) {
                return expandedPath
            }
        }
        return nil
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .lumaDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        LumaAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .lumaDismissPanel, object: nil)
        LumaAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            LumaLogger.log("[Luma] ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            LumaLogger.log("[Luma] Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        idleTimer.stop()
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()
        screenshotHideRestoreTask?.cancel()
        screenshotHideRestoreTask = nil
        if let observer = elementPointingObserver {
            NotificationCenter.default.removeObserver(observer)
            elementPointingObserver = nil
        }
        if let observer = screenshotShortcutObserver {
            NotificationCenter.default.removeObserver(observer)
            screenshotShortcutObserver = nil
        }

        if let observer = agentTaskCompletedObserver {
            NotificationCenter.default.removeObserver(observer)
            agentTaskCompletedObserver = nil
        }

        if let observer = screenRecordingPermissionObserver {
            NotificationCenter.default.removeObserver(observer)
            screenRecordingPermissionObserver = nil
        }

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil

        // Persist agent sessions before tearing them down so they can be restored on next launch
        persistAllAgentSessions()

        // Tear down agent sessions
        agentDockManager.hide()
        agentSessionObservationCancellables.removeAll()
        for session in agentSessions {
            Task { await session.stop() }
        }
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        #if DEBUG
        EnergyDebugLogger.refreshSubcall("AXIsProcessTrusted")
        #endif
        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        #if DEBUG
        EnergyDebugLogger.refreshSubcall("CGPreflightScreenCaptureAccess")
        #endif
        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        #if DEBUG
        EnergyDebugLogger.refreshSubcall("AVCaptureDevice.authorizationStatus")
        #endif
        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            LumaLogger.log("[Luma] Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            LumaAnalytics.trackPermissionGranted(permission: "accessibility")
            NotificationCenter.default.post(
                name: .lumaPermissionGranted,
                object: nil,
                userInfo: ["permission": LumaRequiredPermission.accessibility.rawValue]
            )
            LumaLogger.log("[Luma] Posted lumaPermissionGranted for accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            LumaAnalytics.trackPermissionGranted(permission: "screen_recording")
            // Notify observers that screen recording was just granted so they can
            // reinitialize ScreenCaptureKit without requiring an app restart.
            NotificationCenter.default.post(name: .lumaScreenRecordingPermissionGranted, object: nil)
            LumaLogger.log("[Luma] Screen recording permission granted — posting reinit notification")
            NotificationCenter.default.post(
                name: .lumaPermissionGranted,
                object: nil,
                userInfo: ["permission": LumaRequiredPermission.screenRecording.rawValue]
            )
            LumaLogger.log("[Luma] Posted lumaPermissionGranted for screenRecording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            LumaAnalytics.trackPermissionGranted(permission: "microphone")
            NotificationCenter.default.post(
                name: .lumaPermissionGranted,
                object: nil,
                userInfo: ["permission": LumaRequiredPermission.microphone.rawValue]
            )
            LumaLogger.log("[Luma] Posted lumaPermissionGranted for microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            LumaAnalytics.trackAllPermissionsGranted()

            // All permissions just became available — show the overlay without
            // requiring a restart. Guard against showing it if onboarding hasn't
            // been completed yet (the onboarding flow shows the overlay itself).
            if hasCompletedOnboarding && isLumaCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }
        }

        // Once every permission is confirmed and onboarding is done, the 1.5 Hz
        // permission-polling timer has nothing left to discover. System permission
        // states (accessibility, screen recording, microphone) only change when
        // the user explicitly acts in System Settings, and the app must be
        // restarted or re-focused for macOS to surface the change anyway.
        // Stopping here eliminates the constant AXIsProcessTrusted /
        // CGPreflightScreenCaptureAccess syscalls that are the primary source
        // of Luma's idle energy impact.
        if allPermissionsGranted && hasCompletedOnboarding {
            accessibilityCheckTimer?.invalidate()
            accessibilityCheckTimer = nil
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                LumaLogger.log("[Luma] Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    LumaAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isLumaCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                LumaLogger.log("[Luma] Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            #if DEBUG
            EnergyDebugLogger.timerFired("permissionPoll@1.5s")
            #endif
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    /// Observes the dictation manager's permission problem so the panel can
    /// switch to a text input field when voice is unavailable.
    private func bindPermissionProblemObservation() {
        permissionProblemCancellable = buddyDictationManager.$currentPermissionProblem
            .receive(on: DispatchQueue.main)
            .sink { [weak self] permissionProblem in
                guard let self else { return }
                self.showTextInputFallback = permissionProblem != nil
                if let permissionProblem {
                    LumaLogger.log("[Luma] Voice unavailable (\(permissionProblem)) — showing text input fallback")
                } else {
                    LumaLogger.log("[Luma] Voice permissions restored — hiding text input fallback")
                }
            }
    }

    /// Clears the last API error message, hiding the error banner in the panel.
    func dismissLastAPIError() {
        lastAPIErrorMessage = nil
    }

    /// Submits a typed message through the same AI response pipeline as a
    /// voice transcript. Used when microphone or speech recognition is denied.
    func submitTextInput(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        // Text input counts as an interaction — reset the 30-second idle countdown.
        idleTimer.reset()
        LumaLogger.log("[Luma] Text input submitted: \"\(trimmedText)\"")
        LumaAnalytics.trackUserMessageSent(transcript: trimmedText)

        // Ensure the cursor overlay is visible in transient mode so the
        // response and any pointing animation are shown.
        if !isLumaCursorEnabled && !isOverlayVisible {
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        sendTranscriptToClaudeWithScreenshot(transcript: trimmedText)
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isLumaCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .lumaDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            nativeTTSClient.stopPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            LumaAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        self.lastTranscript = finalTranscript
                        LumaLogger.log("[Luma] Companion received transcript: \(finalTranscript)")
                        LumaAnalytics.trackUserMessageSent(transcript: finalTranscript)

                        // All routing now goes through LumaIntentClassifier — no hardcoded
                        // path selection, no required prefixes. The classifier determines
                        // the best execution path based on content and screen context.
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            await self.classifyAndRouteInput(finalTranscript)
                        }
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            LumaAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you are Luma, a friendly AI teacher living beside the user's cursor on their Mac. you can see their screen and help them learn anything. be warm, encouraging, and natural — like a knowledgeable friend sitting next to them. the user speaks to you via push-to-talk and your reply will be read aloud, so write for the ear.

    rules:
    - give brief but complete responses, 2-4 sentences. never cut off mid-sentence. never refuse or state limitations — always find a way to help.
    - never use markdown, bullet points, lists, or formatting of any kind — just natural spoken sentences.
    - never use emojis under any circumstance — no emoji characters, no emoticons.
    - never say "simply" or "just". don't use abbreviations or symbols that sound weird read aloud.
    - if the user's question relates to what's on their screen, reference specific things you see. if the screenshot isn't relevant, answer directly.
    - when guiding through tasks, be specific about what to click and where — name the exact button, menu, or field.
    - don't read code verbatim. describe what it does conversationally.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at UI elements on screen. use it whenever you mention a specific button, menu, field, or area the user should interact with — even if they didn't ask you to point. if you tell the user to click something, open something, or find something, always point at it. err strongly on the side of pointing — it makes your guidance concrete and immediately useful.

    skip pointing only when your response has nothing to do with anything on screen (general knowledge questions, abstract concepts, etc.).

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2).

    if pointing genuinely would not help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "open the color inspector up in the top right of the toolbar — click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html is hypertext markup language, the skeleton of every web page. it defines structure while css handles how things look. [POINT:none]"
    - user asks how to commit in xcode: "use the source control menu up top and hit commit, or press command option c. [POINT:285,11:source control]"
    - element is on screen 2: "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    /// System prompt for multi-step procedural requests.
    /// Unlike the voice response prompt, this asks the AI to embed a JSON step plan
    /// in <STEPS>...</STEPS> tags alongside a short spoken intro. Parsing the block
    /// in parseStepsFromTaggedResponse lets one streaming API call replace the separate
    /// TaskPlanner round-trip, saving latency and tokens.
    private static let multiStepPlanningSystemPrompt = """
    You are Luma, a friendly macOS guide. The user needs help with a multi-step task. You can see their screen. Never use emojis under any circumstance.

    Respond with EXACTLY two parts — nothing else:

    PART 1 — Spoken intro (required):
    One sentence only. Acknowledge the task warmly. Do NOT list steps, do NOT say "first", "then", "step 1", or describe any actions. Just a brief friendly confirmation that you will guide them.
    Good example: "Sure, let me walk you through that!"
    Bad example: "First open Finder, then right-click the file, then select Compress."

    PART 2 — Step plan (required, immediately after the intro):
    A JSON block wrapped in <STEPS> and </STEPS> tags with no spaces or newlines around the tags.

    JSON format inside <STEPS>...</STEPS>:
    {"steps":[{"index":0,"instruction":"What to say to the user for this step","elementName":"exact AX label","elementRole":"AXButton|AXMenuItem|AXMenuBarItem|AXTextField|null","appBundleID":"com.apple.finder or null","isMenuBar":false,"timeoutSeconds":15}]}

    Rules for the JSON:
    - elementName: shortest label that uniquely identifies the element in macOS AX (e.g. "Compress" not "Compress 'Downloads'"). macOS strips contextual suffixes from AX titles.
    - For context menu interactions: two steps — (1) right-click the target item, elementName = the item name; (2) select from the menu, elementName = the menu item label, isMenuBar = false
    - isMenuBar = true for: app menus (File, Edit, View) and menu bar system items (Wi-Fi, Battery, Control Center, Clock)
    - appBundleID: "com.apple.finder" for Finder; "com.apple.controlcenter" for Control Center; null if not app-specific
    - If a step has no specific UI element to click: elementName = ""
    - instruction: one natural spoken sentence for that step only — what the user should do right now

    CRITICAL: You MUST output the <STEPS>...</STEPS> block. Never skip it. Never replace it with plain text steps.
    """

    // MARK: - Intent Classifier Routing

    /// Single entry point for all user voice input in companion mode.
    /// Runs LumaIntentClassifier to determine the best execution path,
    /// handles clarification and confirmation loops, then dispatches to
    /// the appropriate engine (CLI, agent, walkthrough, or Claude response).
    private func classifyAndRouteInput(_ transcript: String) async {
        // Any user input resets the 30-second idle countdown.
        idleTimer.reset()

        // Check for explicit agent spawn request BEFORE running the full classifier.
        // "Luma agent", "new agent", or "spawn agent" always spawns a persistent agent,
        // bypassing classification — the user is making a direct structural request.
        let lowercasedTranscript = transcript.lowercased()
        let isExplicitAgentRequest = lowercasedTranscript.contains("luma agent")
            || lowercasedTranscript.contains("new agent")
            || lowercasedTranscript.contains("spawn agent")
        if isExplicitAgentRequest {
            LumaLogger.log("[LumaClassifier] Explicit agent request detected — spawning persistent agent")
            // isTransient is false (default) — this agent persists until dismissed by the user
            _ = createAndSelectNewAgentSession()
            updateAgentDock()
            voiceState = .idle
            return
        }

        // SYSTEM STATE GUARD — if a visual agent session is actively running, forward
        // the new voice input to it as a follow-up prompt so the agent has full context.
        // For all other paths (CLI, guide, response), a new request always replaces the
        // current task: fall through to the classifier and let sendTranscriptToClaudeWithScreenshot
        // cancel and archive the previous task before starting the new one.
        if case .executing(let activePath) = systemExecutionState {
            if case .visualAgent = activePath,
               let activeSession = agentSessions.first(where: { $0.status == .running || $0.status == .starting }) {
                LumaLogger.log("[LumaClassifier] Visual agent running — forwarding follow-up to active session")
                await activeSession.submitPrompt(transcript)
                return
            }
            // CLI / guide / response: fall through so the new request replaces the current task.
            LumaLogger.log("[LumaClassifier] New request received — re-classifying to replace current task")
        }

        // If we were waiting for a clarification answer, combine it with the
        // original input and re-classify. This lets the classifier pick up full context.
        if let pendingInput = pendingClassifierOriginalInput {
            pendingClassifierOriginalInput = nil
            let combinedInput = "\(pendingInput) (context: \(transcript))"
            LumaLogger.log("[LumaClassifier] Re-classifying with clarification appended")
            await classifyAndRouteInput(combinedInput)
            return
        }

        // If we were waiting for a yes/no confirmation, interpret this input as the answer.
        if let confirmAction = pendingConfirmationAction {
            pendingConfirmationAction = nil
            let lowercased = transcript.lowercased()
            let userConfirmed = lowercased.contains("yes") || lowercased.contains("confirm")
                || lowercased.contains("proceed") || lowercased.contains("do it")
                || lowercased.contains("sure") || lowercased.contains("go ahead")
            if userConfirmed {
                await confirmAction()
            } else {
                voiceState = .responding
                try? await nativeTTSClient.speakText("Got it, I won't do that.")
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
            return
        }

        // Run the classifier — show spinner while we wait for the Claude call
        voiceState = .processing
        let result = await LumaIntentClassifier.shared.classify(userInput: transcript)

        // Clarification needed — ask, store original, wait for next input
        if result.clarificationNeeded, let question = result.clarificationQuestion {
            pendingClassifierOriginalInput = transcript
            voiceState = .responding
            try? await nativeTTSClient.speakText(question)
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            return
        }

        // Low confidence without clarification question — generic prompt for more detail
        if result.confidence == .low {
            pendingClassifierOriginalInput = transcript
            voiceState = .responding
            let genericPrompt = result.clarificationQuestion ?? "Could you give me a bit more detail about what you'd like to do?"
            try? await nativeTTSClient.speakText(genericPrompt)
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            return
        }

        // Confirmation required — speak prompt, store action, wait for yes/no
        if result.requiresConfirmation, let confirmPrompt = result.confirmationPrompt {
            let pathToExecute = result.path
            let intentDescription = result.intent
            pendingConfirmationAction = { [weak self] in
                guard let self else { return }
                await self.executeClassifiedPath(pathToExecute, intent: intentDescription, originalTranscript: transcript)
            }
            voiceState = .responding
            try? await nativeTTSClient.speakText("\(confirmPrompt) Say yes to proceed, or no to cancel.")
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            return
        }

        // For medium confidence on non-response paths, briefly announce the action
        if result.confidence == .medium {
            if case .response = result.path { /* no announcement — just answer */ }
            else {
                voiceState = .responding
                try? await nativeTTSClient.speakText("I'll \(result.intent) — starting now.")
                await nativeTTSClient.waitUntilFinished()
            }
        }

        await executeClassifiedPath(result.path, intent: result.intent, originalTranscript: transcript)
    }

    /// Dispatches to the engine appropriate for the classified execution path.
    /// Records the executed action so future classifier calls have recent history.
    /// Sets systemExecutionState to .executing for the duration and resets to
    /// .idle when the path completes so the classifier guard releases correctly.
    private func executeClassifiedPath(
        _ path: LumaExecutionPath,
        intent: String,
        originalTranscript: String
    ) async {
        // Mark system as executing so new voice input routes as follow-up, not re-classify
        systemExecutionState = .executing(path: path)
        defer { systemExecutionState = .idle }

        switch path {

        case .cli(let command):
            // Route coding/scripting tasks to Claude Code (or API fallback) via the
            // same agent infrastructure as manual agent spawning. This ensures tasks
            // like "write a python script" go to the Claude Code desktop agent rather
            // than running raw shell commands via CLIAgentRuntime.
            LumaLogger.log("[LumaClassifier] → cli (Claude Code): \(command.prefix(80))")

            // Enable agent mode if not already on so the dock becomes visible
            if !isAgentModeEnabled {
                isAgentModeEnabled = true
                UserDefaults.standard.set(true, forKey: "luma.agentMode.enabled")
            }

            // Create a standard agent session — no markAsCLISession, same as a
            // manually spawned agent so it gets Claude Code / API runtime, not zsh.
            let claudeCodeSession = AgentSession()
            agentSessions.append(claudeCodeSession)
            activeAgentSessionID = claudeCodeSession.id
            // Mark as transient — auto-dismissed after task completion.
            claudeCodeSession.isTransient = true

            // Auto-detect Claude Code CLI; fall back to API runtime if not installed
            let claudeCodeRuntime = AgentRuntimeManager.shared.createRuntime()
            claudeCodeSession.bind(to: claudeCodeRuntime)

            // Refresh the dock so the new bubble appears immediately
            updateAgentDock()

            // Warm up and submit the task (async — completes on its own)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let systemContext = AgentMemoryIntegration.loadSummarizedMemoryForSystemContext()
                await claudeCodeSession.warmUp()
                await claudeCodeSession.submitPrompt(command, systemContext: systemContext)

                // Once done, speak a brief completion phrase
                voiceState = .responding
                let spokenSummary = "Done. Check the agent bubble for the full output."
                try? await nativeTTSClient.speakText(spokenSummary)
                await nativeTTSClient.waitUntilFinished()
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }

            LumaIntentClassifier.shared.recordExecutedAction("sent to Claude Code: \(command.prefix(60))")
            voiceState = .idle

        case .visualAgent(let goal):
            // Hand off to LumaFlowEngine which runs the full plan→execute→observe loop.
            // The engine creates its own AgentSession and drives the dock bubble via
            // LumaFlowRuntime. This replaces direct AgentVoiceIntegration spawning.
            LumaLogger.log("[LumaClassifier] → visual_agent → LumaFlowEngine: \(goal.prefix(80))")
            if !isAgentModeEnabled {
                isAgentModeEnabled = true
                UserDefaults.standard.set(true, forKey: "luma.agentMode.enabled")
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await LumaFlowEngine.shared.startFlow(goal: goal, companionManager: self, isTransient: true)
            }
            LumaIntentClassifier.shared.recordExecutedAction("started flow for: \(goal.prefix(60))")
            voiceState = .idle
            scheduleTransientHideIfNeeded()

        case .guide(let topic):
            // Route to the walkthrough / multi-step guide pipeline via existing Claude call.
            // sendTranscriptToClaudeWithScreenshot uses its on-device classifier to detect
            // multi-step requests and hands them to WalkthroughEngine automatically.
            LumaLogger.log("[LumaClassifier] → guide: \(topic.prefix(80))")
            LumaIntentClassifier.shared.recordExecutedAction("started guide on: \(topic.prefix(60))")
            sendTranscriptToClaudeWithScreenshot(transcript: topic)

        case .response(let query):
            // Route to standard Claude vision response pipeline
            LumaLogger.log("[LumaClassifier] → response: \(query.prefix(80))")
            LumaIntentClassifier.shared.recordExecutedAction("answered: \(query.prefix(60))")
            sendTranscriptToClaudeWithScreenshot(transcript: query)
        }
    }

    // MARK: - Task History Management

    /// Moves activeTaskRequest to taskHistory with the given outcome, then clears it.
    /// Pass nil as outcome when the task is interrupted (cancelled before a response was delivered),
    /// or the AI's spoken response when the task completes successfully.
    /// Noop if no task is currently active.
    private func archiveActiveTask(outcome: String?) {
        guard let request = activeTaskRequest else { return }
        activeTaskRequest = nil
        taskHistory.append(LumaCompletedTask(userRequest: request, outcome: outcome))
        // Cap at 10 entries to prevent unbounded context growth
        if taskHistory.count > 10 {
            taskHistory.removeFirst(taskHistory.count - 10)
        }
        LumaLogger.log("[Luma] Task archived — history now has \(taskHistory.count) entries")
    }

    /// Builds the "Previously, the user asked to..." context block that is injected into
    /// the system prompt before every AI request. Returns an empty string when there is
    /// no history yet (first request in a session). Each entry explicitly labels prior tasks
    /// as completed or interrupted so the AI never treats them as active to-dos.
    private func buildTaskHistoryContext() -> String {
        guard !taskHistory.isEmpty else { return "" }
        let historyLines = taskHistory.map { task -> String in
            if let outcome = task.outcome {
                return "Previously, the user asked to: \"\(task.userRequest)\". Result: \"\(outcome)\""
            } else {
                return "Previously, the user asked to: \"\(task.userRequest)\". Result: interrupted before completion."
            }
        }.joined(separator: "\n")
        return "Recent conversation context (treat as background context only — not active to-dos):\n" + historyLines
    }

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to the AI,
    /// and plays the response aloud via native TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// The response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        // Archive the previous task as interrupted — it did not complete before this new request.
        // This moves it to taskHistory where it becomes read-only "Previously..." context.
        archiveActiveTask(outcome: nil)

        // Mark this request as the single active task. Only one task is ever active at a time.
        activeTaskRequest = transcript

        // If a walkthrough is currently running, cancel it before handling the new request.
        // This prevents the old walkthrough's timers, AX observers, and polling from
        // interfering with the new request — and resets isTypingStepActive to false.
        if WalkthroughEngine.shared.isRunning {
            LumaLogger.log("[Luma] New request received — cancelling active walkthrough")
            WalkthroughEngine.shared.cancelWalkthrough()
        }

        currentResponseTask?.cancel()
        nativeTTSClient.stopPlayback()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing
            // Clear any previous API error so the panel doesn't show stale info
            lastAPIErrorMessage = nil

            // Compress the transcript before guide matching and Claude routing.
            // Reduces token usage by ~50-60% on an average voice query while preserving intent.
            // The original transcript is kept for conversation history so context is human-readable.
            let compressedTranscript = LumaMLEngine.shared.compressPrompt(transcript)

            // Offline fallback: only use offline guides when the user is actually offline.
            // When online, always route to live AI even if an offline guide keyword matches.
            // Messages are split and sequenced — "You're offline." plays first and finishes
            // before the follow-up is spoken, so the two sentences never overlap.
            if !OfflineGuideManager.shared.isOnline {
                if let guideMatch = OfflineGuideManager.shared.findGuideByKeyword(for: compressedTranscript) {
                    OfflineGuideManager.shared.executeGuide(guideMatch.guide)
                    voiceState = .idle
                    scheduleTransientHideIfNeeded()
                    return
                }

                lastAPIErrorMessage = LumaWriteEngine.shared.errorMessage(for: .offline)
                try? await nativeTTSClient.speakText("You're offline.")
                await nativeTTSClient.waitUntilFinished()
                try? await Task.sleep(nanoseconds: 400_000_000)
                try? await nativeTTSClient.speakText("This task is not available offline. Please connect to the internet.")
                voiceState = .idle
                scheduleTransientHideIfNeeded()
                return
            }

            // Classify the transcript on-device to decide how to route it.
            // .multiStep → WalkthroughEngine (AI plans steps, executes silently)
            // .singleStep / .question / .unknown → existing Claude voice response flow
            // Classification is instant (keyword heuristics) so there's no perceived delay.
            let taskClassification = await LumaOnDeviceAI.shared.classifyTask(compressedTranscript)
            LumaLogger.log("[Luma] Task classification: .\(taskClassification.taskType) confidence=\(String(format: "%.2f", taskClassification.confidence)) — \(taskClassification.reason)")

            // Determine whether this is a multi-step request so we can pick the right system prompt.
            // Multi-step requests use multiStepPlanningSystemPrompt which asks the AI to embed a
            // <STEPS>...</STEPS> JSON plan in the same streaming response — one API call total
            // instead of a separate TaskPlanner round-trip.
            let isMultiStepRequest = taskClassification.taskType == .multiStep && !WalkthroughEngine.shared.isRunning

            do {
                // Capture all connected screens so the AI has full context.
                // If screen content permission isn't granted yet (or capture fails
                // for any other reason), fall back to a text-only request rather
                // than surfacing a generic "couldn't reach the AI" error.
                var screenCaptures: [CompanionScreenCapture] = []
                let labeledImages: [(data: Data, label: String)]
                do {
                    screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                    labeledImages = screenCaptures.map { capture in
                        let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                        return (data: capture.imageData, label: capture.label + dimensionInfo)
                    }
                } catch {
                    // Screen capture unavailable — proceed without screenshot.
                    // This happens when Screen Content permission hasn't been granted.
                    LumaLogger.log("[Luma] Screen capture failed, proceeding without screenshot: \(error)")
                    labeledImages = []
                }

                guard !Task.isCancelled else { return }

                // Build the system prompt: memory + outlook prefix → base persona → task history.
                // The full context prefix (memory.md + behavioral outlook) is prepended so the AI
                // always has a complete picture of the user before choosing how to respond.
                // History is injected into the system prompt rather than sent as conversation
                // message turns — this ensures the AI sees previous tasks as completed background
                // context only, and never as active instructions to execute simultaneously.
                let baseSystemPrompt = isMultiStepRequest
                    ? Self.multiStepPlanningSystemPrompt
                    : Self.companionVoiceResponseSystemPrompt
                let taskHistoryContext = buildTaskHistoryContext()
                let baseWithHistory = taskHistoryContext.isEmpty
                    ? baseSystemPrompt
                    : baseSystemPrompt + "\n\n" + taskHistoryContext
                let fullContextPrefix = AgentMemoryIntegration.fullSystemContextPrefix()
                let systemPromptWithHistory = fullContextPrefix.map { $0 + "\n\n" + baseWithHistory }
                    ?? baseWithHistory

                let (fullResponseText, _) = try await apiClient.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: systemPromptWithHistory,
                    conversationHistory: [],  // history is in systemPrompt; not sent as message turns
                    userPrompt: compressedTranscript,
                    maxOutputTokens: isMultiStepRequest ? 2048 : 1024,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )

                // Observe this interaction asynchronously to update the user's behavioral outlook.
                // Fire-and-forget — never blocks the voice response or TTS playback.
                LumaUserOutlookManager.shared.observeInteractionAsync(
                    userInput: compressedTranscript,
                    aiResponse: fullResponseText
                )

                guard !Task.isCancelled else { return }

                // For multi-step requests: extract the <STEPS>...</STEPS> block from the response
                // and hand the steps directly to WalkthroughEngine. The AI has already embedded
                // the step plan in the same streaming response — no second API call needed.
                // If no valid step plan is found, fall through to the normal voice response path.
                if isMultiStepRequest {
                    let extractedSteps = Self.parseStepsFromTaggedResponse(fullResponseText)
                    if !extractedSteps.isEmpty {
                        let spokenIntroText = Self.stripStepsTagFromResponse(fullResponseText)
                        LumaLogger.log("[Luma] Multi-step: \(extractedSteps.count) step(s) extracted — starting walkthrough")
                        if !spokenIntroText.isEmpty {
                            try? await nativeTTSClient.speakText(spokenIntroText)
                            voiceState = .responding
                            // Wait for the intro to finish before WalkthroughEngine starts speaking.
                            // Both use separate AVSpeechSynthesizer instances so without this wait
                            // the step 1 instruction overlaps the intro simultaneously.
                            await nativeTTSClient.waitUntilFinished()
                        }
                        voiceState = .idle
                        scheduleTransientHideIfNeeded()
                        WalkthroughEngine.shared.executeSteps(extractedSteps)
                        return
                    }
                    // The model didn't produce a valid <STEPS> block — speaking the full response
                    // text would read out a structured step plan which sounds terrible via TTS.
                    // Instead, say a brief generic intro and use TaskPlanner (dedicated JSON-only
                    // prompt) to build the step plan. This is the reliable fallback for weaker
                    // models that ignore the <STEPS> format instruction.
                    LumaLogger.log("[Luma] Multi-step: no valid <STEPS> block — falling back to TaskPlanner")
                    try? await nativeTTSClient.speakText("Sure, let me guide you through that.")
                    voiceState = .idle
                    scheduleTransientHideIfNeeded()
                    Task {
                        do {
                            let frontmostAppNameForPlanner = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
                            let plan = try await TaskPlanner().planSteps(goal: compressedTranscript, frontmostAppName: frontmostAppNameForPlanner)
                            if !plan.steps.isEmpty {
                                WalkthroughEngine.shared.executeSteps(plan.steps)
                            }
                        } catch {
                            LumaLogger.log("[Luma] TaskPlanner fallback failed: \(error.localizedDescription)")
                        }
                    }
                    return
                }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    LumaAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    LumaLogger.log("[Luma] Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    LumaLogger.log("[Luma] Element pointing: \(parseResult.elementLabel ?? "no element")")

                    // Auto-cursor fallback: if Claude did not embed a [POINT:x,y] coordinate,
                    // scan the spoken text for action words referencing a UI element and use
                    // CursorGuide to locate and point at it via the accessibility tree.
                    if let autoTargetElementName = Self.extractElementNameFromActionPhrase(spokenText: spokenText) {
                        LumaLogger.log("[Luma] Auto-cursor: no explicit coordinate — searching AX tree for '\(autoTargetElementName)'")
                        await CursorGuide.shared.pointAtElement(withTitle: autoTargetElementName, inApp: nil)
                    }
                }

                // Archive the completed task with its spoken response as the outcome.
                // Future requests will see this as a "Previously..." entry in the system prompt.
                archiveActiveTask(outcome: spokenText)

                LumaAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS — gated by the "Auto-read responses" setting
                // (UserDefaults key luma.voice.autoReadResponses, default true).
                // When disabled, the response is shown visually but not spoken aloud.
                let shouldAutoReadResponse = UserDefaults.standard.object(forKey: NativeTTSClient.autoReadResponsesKey) as? Bool ?? true
                if shouldAutoReadResponse && !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await nativeTTSClient.speakText(spokenText)
                        // speakText queues the utterance and returns immediately —
                        // switch to responding state so the UI knows audio is playing
                        voiceState = .responding
                    } catch {
                        LumaAnalytics.trackTTSError(error: error.localizedDescription)
                        LumaLogger.log("[Luma] Native TTS error: \(error)")
                        speakCreditsErrorFallback()
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                LumaAnalytics.trackResponseError(error: error.localizedDescription)
                LumaLogger.log("[Luma] Companion response error (\(type(of: error))): \(error.localizedDescription)")
                LumaLogger.log("[Luma] Full error: \(error)")
                // Map the raw API error to a brief human-readable message via LumaWriteEngine.
                // Raw error strings from the API (e.g. "The operation couldn't be completed") are
                // never shown — LumaWriteEngine always produces a short, friendly alternative.
                let lumaErrorType = Self.mapErrorToLumaErrorType(error)
                lastAPIErrorMessage = LumaWriteEngine.shared.errorMessage(for: lumaErrorType)
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Luma" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isLumaCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing.
            // Also wait for any active walkthrough — WalkthroughEngine uses NativeTTSClient.shared
            // (a different instance from CompanionManager's nativeTTSClient) so we check both.
            while nativeTTSClient.isPlaying || NativeTTSClient.shared.isPlaying || WalkthroughEngine.shared.isRunning {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
            idleTimer.stop()
        }
    }

    /// Speaks a fallback error message using native TTS when the AI API fails
    /// (e.g. no profile configured, bad API key, network error).
    private func speakCreditsErrorFallback() {
        voiceState = .responding
        Task {
            try? await nativeTTSClient.speakText("Sorry, I couldn't reach the AI. Please check your API profile in Settings.")
        }
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Step Plan Tag Parsing

    /// Extracts WalkthroughSteps from a <STEPS>...</STEPS> block embedded in the AI response.
    /// Returns an empty array if the block is absent or the JSON inside is malformed.
    /// Logs the failure reason so it's visible in Xcode's console for debugging.
    static func parseStepsFromTaggedResponse(_ responseText: String) -> [WalkthroughStep] {
        guard let stepsOpenRange = responseText.range(of: "<STEPS>"),
              let stepsCloseRange = responseText.range(of: "</STEPS>"),
              stepsOpenRange.upperBound < stepsCloseRange.lowerBound else {
            LumaLogger.log("[Luma] parseStepsFromTaggedResponse: no <STEPS>...</STEPS> block in response")
            return []
        }

        let jsonContent = String(responseText[stepsOpenRange.upperBound..<stepsCloseRange.lowerBound])

        // Anchor on "steps" key to locate the correct JSON object — same robust approach as TaskPlanner.
        // This handles any extra whitespace or characters the model adds inside the tags.
        guard let stepsKeyRange = jsonContent.range(of: "\"steps\""),
              let objectStartIndex = jsonContent[..<stepsKeyRange.lowerBound].lastIndex(of: "{"),
              let objectEndIndex = jsonContent.lastIndex(of: "}") else {
            LumaLogger.log("[Luma] parseStepsFromTaggedResponse: could not locate JSON object. Block: \(jsonContent)")
            return []
        }

        let jsonString = String(jsonContent[objectStartIndex...objectEndIndex])

        guard let jsonData = jsonString.data(using: .utf8) else {
            LumaLogger.log("[Luma] parseStepsFromTaggedResponse: could not encode JSON as UTF-8")
            return []
        }

        do {
            let plan = try JSONDecoder().decode(WalkthroughPlan.self, from: jsonData)
            LumaLogger.log("[Luma] parseStepsFromTaggedResponse: decoded \(plan.steps.count) step(s)")
            return plan.steps
        } catch {
            LumaLogger.log("[Luma] parseStepsFromTaggedResponse: decode failed — \(error.localizedDescription). JSON: \(jsonString)")
            return []
        }
    }

    /// Returns the response text with the <STEPS>...</STEPS> block removed.
    /// Used to get the clean spoken intro text before handing the steps to WalkthroughEngine.
    static func stripStepsTagFromResponse(_ responseText: String) -> String {
        guard let stepsOpenRange = responseText.range(of: "<STEPS>"),
              let stepsCloseRange = responseText.range(of: "</STEPS>") else {
            return responseText
        }
        let textBeforeSteps = String(responseText[..<stepsOpenRange.lowerBound])
        let textAfterSteps = String(responseText[stepsCloseRange.upperBound...])
        return (textBeforeSteps + textAfterSteps).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scans the spoken response text for action words (click, open, select, etc.)
    /// followed by a UI element name, and returns the element name so CursorGuide
    /// can automatically locate and point at it via the accessibility tree.
    /// Returns nil when no recognisable action phrase is detected, or when the
    /// match resolves to a keyboard shortcut rather than a named UI element.
    static func extractElementNameFromActionPhrase(spokenText: String) -> String? {
        // Match action verbs followed by an optional article and a short element name.
        // Capture group 1 holds the element name candidate.
        let actionVerbPattern = #"(?:click(?:ing)?|open(?:ing)?|select(?:ing)?|find(?:ing)?|tap(?:ping)?|press(?:ing)?|navigate to|go to|head to|look for)\s+(?:the\s+|on\s+)?([A-Za-z][A-Za-z\s]{1,40}?)(?:\s*[.,;!?—]|$)"#

        guard let actionRegex = try? NSRegularExpression(pattern: actionVerbPattern, options: [.caseInsensitive]),
              let firstMatch = actionRegex.firstMatch(in: spokenText, range: NSRange(spokenText.startIndex..., in: spokenText)),
              let captureRange = Range(firstMatch.range(at: 1), in: spokenText) else {
            return nil
        }

        let rawCapturedElementName = String(spokenText[captureRange]).trimmingCharacters(in: .whitespaces)

        // Exclude keyboard shortcut references — these are not AX-searchable element names.
        // e.g. "press Command R", "press Enter", "press Escape"
        let keyboardShortcutPrefixes = ["command", "option", "control", "shift", "return", "enter", "escape", "tab", "space", "delete", "backspace"]
        if keyboardShortcutPrefixes.contains(where: { rawCapturedElementName.lowercased().hasPrefix($0) }) {
            return nil
        }

        // Limit to the first three words to avoid over-capturing trailing sentence fragments
        let elementNameWords = rawCapturedElementName.components(separatedBy: .whitespaces).prefix(3)
        let elementName = elementNameWords.joined(separator: " ")

        // Don't return a name that is just a common article or stop word with nothing meaningful
        guard elementName.count >= 3 else { return nil }

        return elementName
    }

    // MARK: - Error Classification

    /// Maps a raw API Error to the closest LumaWriteEngine ErrorType by inspecting
    /// the error description for well-known substrings. This keeps raw API error strings
    /// out of the UI — LumaWriteEngine always produces a short human-readable message.
    private static func mapErrorToLumaErrorType(_ error: Error) -> ErrorType {
        let description = error.localizedDescription.lowercased()

        if description.contains("offline") || description.contains("network connection")
            || description.contains("internet") || description.contains("not connected") {
            return .offline
        }

        if description.contains("rate limit") || description.contains("429")
            || description.contains("too many requests") {
            return .rateLimited
        }

        if description.contains("api key") || description.contains("unauthorized")
            || description.contains("401") || description.contains("no profile")
            || description.contains("invalid key") {
            return .noAPIKey
        }

        if description.contains("model") && (description.contains("not found") || description.contains("404")) {
            return .modelNotFound
        }

        if description.contains("could not connect") || description.contains("connection")
            || description.contains("timed out") || description.contains("unreachable") {
            return .connectionFailed(providerName: "AI")
        }

        return .unknown(error.localizedDescription)
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Luma flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            LumaAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            LumaAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're luma, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    LumaLogger.log("[Luma] Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await apiClient.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    LumaLogger.log("[Luma] Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                LumaLogger.log("[Luma] Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                LumaLogger.log("[Luma] Onboarding demo error: \(error)")
            }
        }
    }

    // MARK: - Agent Session Lifecycle

    private let agentAccentThemeRotation: [LumaAccentTheme] = [.blue, .mint, .amber, .rose]

    /// Ensures at least one agent session exists. Called during start().
    private func ensureDefaultAgentSession() {
        guard agentSessions.isEmpty else { return }
        createAndSelectNewAgentSession()
    }

    /// Creates a new agent session with a rotated accent theme, binds a runtime, and selects it.
    @discardableResult
    func createAndSelectNewAgentSession() -> AgentSession {
        let maxAgents = AgentSettingsManager.shared.maxAgentCount
        if agentSessions.count >= maxAgents {
            // Dismiss oldest non-running session to make room
            if let oldestIdleSession = agentSessions.first(where: { $0.status != .running }) {
                Task { await dismissAgentSession(id: oldestIdleSession.id) }
            } else {
                LumaLogger.log("[Luma] Agent limit reached (\(maxAgents)), all sessions busy")
            }
        }

        let themeIndex = agentSessions.count % agentAccentThemeRotation.count
        let theme = agentAccentThemeRotation[themeIndex]

        let session = AgentSession(accentTheme: theme)
        let runtime = AgentRuntimeManager.shared.createRuntime()
        session.bind(to: runtime)

        agentSessions.append(session)
        activeAgentSessionID = session.id
        // Spawning an agent counts as an interaction — reset the 30-second idle countdown.
        idleTimer.reset()

        // Observe this session's status changes so the dock refreshes automatically
        observeAgentSessionStatus(session)

        LumaLogger.log("[Luma] Spawned agent session: \(session.id)")
        updateAgentDock()

        return session
    }

    func dismissAgentSession(id: UUID) async {
        guard let session = agentSessions.first(where: { $0.id == id }) else { return }
        await session.stop()
        agentSessions.removeAll(where: { $0.id == id })

        // Stop observing status for this session
        agentSessionObservationCancellables.removeValue(forKey: id)

        // Erase persisted data for the terminated agent
        erasePersistedAgentSession(id: id)

        if activeAgentSessionID == id {
            activeAgentSessionID = agentSessions.first?.id
        }

        updateAgentDock()
        LumaLogger.log("[Luma] Dismissed agent session: \(id)")
    }

    /// Subscribes to a session's status and transcript publishers so the dock auto-refreshes on state changes.
    private func observeAgentSessionStatus(_ session: AgentSession) {
        var cancellables = Set<AnyCancellable>()

        session.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateAgentDock()
            }
            .store(in: &cancellables)

        session.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateAgentDock()
            }
            .store(in: &cancellables)

        agentSessionObservationCancellables[session.id] = cancellables
    }

    func selectAgentSession(_ id: UUID) {
        guard agentSessions.contains(where: { $0.id == id }) else { return }
        activeAgentSessionID = id
    }

    func cycleActiveAgent() {
        guard agentSessions.count > 1, let currentID = activeAgentSessionID else { return }
        guard let currentIndex = agentSessions.firstIndex(where: { $0.id == currentID }) else { return }
        let nextIndex = (currentIndex + 1) % agentSessions.count
        activeAgentSessionID = agentSessions[nextIndex].id
    }

    func switchToAgentAtIndex(_ index: Int) {
        guard index >= 0, index < agentSessions.count else { return }
        activeAgentSessionID = agentSessions[index].id
    }

    func submitAgentPromptFromUI(_ prompt: String) {
        // If no session exists (e.g., all were dismissed), create one automatically
        // so the user doesn't need to manually spawn an agent before typing.
        let session: AgentSession
        if let existingSession = agentSessions.first(where: { $0.id == activeAgentSessionID }) ?? agentSessions.first {
            session = existingSession
        } else {
            session = createAndSelectNewAgentSession()
        }
        let systemContext = AgentMemoryIntegration.loadSummarizedMemoryForSystemContext()
        Task {
            await session.submitPrompt(prompt, systemContext: systemContext)
            await MainActor.run { updateAgentDock() }
        }
        // Update dock immediately so status shows "running"
        updateAgentDock()
    }

    func updateAgentDock() {
        if agentSessions.isEmpty || !isAgentModeEnabled {
            agentDockManager.hide()
        } else {
            agentDockManager.show(
                sessions: agentSessions,
                onDismissAgent: { [weak self] sessionID in
                    Task { await self?.dismissAgentSession(id: sessionID) }
                },
                onRunSuggestedAction: { [weak self] sessionID, action in
                    self?.activeAgentSessionID = sessionID
                    self?.submitAgentPromptFromUI(action)
                },
                onVoiceFollowUp: { [weak self] sessionID in
                    self?.activeAgentSessionID = sessionID
                    self?.buddyDictationManager.cancelCurrentDictation()
                },
                onSubmitTextFromDock: { [weak self] sessionID, text in
                    self?.submitAgentPromptForSession(sessionID: sessionID, prompt: text)
                },
                onVoiceToggle: { [weak self] sessionID in
                    self?.toggleAgentVoiceRecording(sessionID: sessionID)
                }
            )
        }
    }

    /// Handles text typed into any agent bubble's follow-up input field.
    /// If there is an active LumaFlow for this session, the text is injected into it directly.
    /// For all other session types (ClaudeCode, API), the text is submitted straight to the
    /// session runtime — Claude Code is smart enough to handle any request without pre-routing.
    func submitAgentPromptForSession(sessionID: UUID, prompt: String) {
        activeAgentSessionID = sessionID
        guard let session = agentSessions.first(where: { $0.id == sessionID }) else { return }

        // Active LumaFlow: inject as follow-up into the running step loop
        if LumaFlowEngine.shared.isFlowActiveForSession(sessionID) {
            LumaFlowEngine.shared.sendFollowUp(prompt)
            updateAgentDock()
            return
        }

        // Claude Code / API agent: submit directly — no additional routing layer
        let systemContext = AgentMemoryIntegration.loadSummarizedMemoryForSystemContext()
        Task {
            await session.submitPrompt(prompt, systemContext: systemContext)
        }
        updateAgentDock()
    };

    /// Toggles voice recording for a specific agent session. Click once to start, click again to stop.
    func toggleAgentVoiceRecording(sessionID: UUID) {
        if agentVoiceRecordingSessionID == sessionID {
            // Stop recording and send the transcript
            stopAgentVoiceRecording()
        } else {
            // Stop any existing recording first
            if agentVoiceRecordingSessionID != nil {
                stopAgentVoiceRecording()
            }
            startAgentVoiceRecording(sessionID: sessionID)
        }
    }

    private func startAgentVoiceRecording(sessionID: UUID) {
        agentVoiceRecordingSessionID = sessionID
        agentDockManager.setVoiceRecordingAgent(sessionID)

        agentVoiceRecordingTask = Task {
            await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                currentDraftText: "",
                updateDraftText: { _ in },
                submitDraftText: { [weak self] finalTranscript in
                    guard let self else { return }
                    let trimmedTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Always clear recording state first, even for empty transcripts, so
                    // the mic button returns to idle regardless of whether text was captured.
                    self.agentVoiceRecordingSessionID = nil
                    self.agentDockManager.setVoiceRecordingAgent(nil)
                    guard !trimmedTranscript.isEmpty else { return }
                    self.submitAgentPromptForSession(sessionID: sessionID, prompt: trimmedTranscript)
                }
            )
            // startPushToTalkFromKeyboardShortcut returns after the audio engine starts.
            // If isRecordingFromKeyboardShortcut is still false at that point, the recording
            // never actually began (e.g., a prior session was still finalizing). Clear the
            // sessionID here so the mic button returns to idle instead of staying stuck.
            if !buddyDictationManager.isRecordingFromKeyboardShortcut,
               agentVoiceRecordingSessionID == sessionID {
                agentVoiceRecordingSessionID = nil
                agentDockManager.setVoiceRecordingAgent(nil)
            }
        }
    }

    private func stopAgentVoiceRecording() {
        buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        agentVoiceRecordingTask?.cancel()
        agentVoiceRecordingTask = nil
        agentVoiceRecordingSessionID = nil
        agentDockManager.setVoiceRecordingAgent(nil)
    }

    // MARK: - Agent Session Persistence

    private static let persistedAgentSessionsKey = "luma.agents.persistedSessions"
    private static let persistedAgentDragPositionsKey = "luma.agents.persistedDragPositions"

    /// Codable snapshot of an agent session for persistence across app restarts.
    struct PersistedAgentSessionData: Codable {
        let id: UUID
        let title: String
        let accentThemeRawValue: String
        let model: String
        let workingDirectoryPath: String
        let iconShapeRawValue: String
        let glowColorRed: Double
        let glowColorGreen: Double
        let glowColorBlue: Double
        let transcriptEntries: [PersistedTranscriptEntry]
    }

    struct PersistedTranscriptEntry: Codable {
        let id: UUID
        let roleRawValue: String
        let text: String
        let createdAt: Date
    }

    /// Saves all current agent sessions and their drag positions to UserDefaults.
    func persistAllAgentSessions() {
        let persistedSessions = agentSessions.map { session -> PersistedAgentSessionData in
            // Extract RGB from the glow color (SwiftUI Color doesn't have direct RGB access,
            // so we use the known palette from AgentSession.randomGlowColors)
            let glowComponents = session.glowColor.cgColorComponents
            let entries = session.entries.map { entry in
                PersistedTranscriptEntry(
                    id: entry.id,
                    roleRawValue: entry.role.rawValue,
                    text: entry.text,
                    createdAt: entry.createdAt
                )
            }
            return PersistedAgentSessionData(
                id: session.id,
                title: session.title,
                accentThemeRawValue: session.accentTheme.rawValue,
                model: session.model,
                workingDirectoryPath: session.workingDirectoryPath,
                iconShapeRawValue: session.iconShape.rawValue,
                glowColorRed: glowComponents.red,
                glowColorGreen: glowComponents.green,
                glowColorBlue: glowComponents.blue,
                transcriptEntries: entries
            )
        }

        if let encodedSessions = try? JSONEncoder().encode(persistedSessions) {
            UserDefaults.standard.set(encodedSessions, forKey: Self.persistedAgentSessionsKey)
        }

        // Persist drag positions
        let positionEntries = agentDockManager.dragPositions.map { (key, value) in
            [key.uuidString: [value.width, value.height]]
        }
        if let encodedPositions = try? JSONEncoder().encode(positionEntries) {
            UserDefaults.standard.set(encodedPositions, forKey: Self.persistedAgentDragPositionsKey)
        }

        LumaLogger.log("[Luma] Persisted \(persistedSessions.count) agent session(s)")
    }

    /// Restores agent sessions from UserDefaults on launch.
    func restorePersistedAgentSessions() {
        guard let sessionData = UserDefaults.standard.data(forKey: Self.persistedAgentSessionsKey),
              let persistedSessions = try? JSONDecoder().decode([PersistedAgentSessionData].self, from: sessionData),
              !persistedSessions.isEmpty else {
            return
        }

        for persisted in persistedSessions {
            let accentTheme = LumaAccentTheme(rawValue: persisted.accentThemeRawValue) ?? .blue
            let iconShape = AgentIconShape(rawValue: persisted.iconShapeRawValue) ?? .triangle
            let glowColor = Color(
                red: persisted.glowColorRed,
                green: persisted.glowColorGreen,
                blue: persisted.glowColorBlue
            )

            let session = AgentSession(
                id: persisted.id,
                title: persisted.title,
                accentTheme: accentTheme,
                model: persisted.model,
                workingDirectoryPath: persisted.workingDirectoryPath,
                restoredIconShape: iconShape,
                restoredGlowColor: glowColor
            )

            // Restore transcript entries
            for entry in persisted.transcriptEntries {
                let role = TranscriptRole(rawValue: entry.roleRawValue) ?? .system
                session.restoreTranscriptEntry(AgentTranscriptEntry(
                    id: entry.id,
                    role: role,
                    text: entry.text,
                    createdAt: entry.createdAt
                ))
            }

            let runtime = AgentRuntimeManager.shared.createRuntime()
            session.bind(to: runtime)
            agentSessions.append(session)
            observeAgentSessionStatus(session)
        }

        activeAgentSessionID = agentSessions.first?.id

        // Restore drag positions
        if let positionData = UserDefaults.standard.data(forKey: Self.persistedAgentDragPositionsKey),
           let positionEntries = try? JSONDecoder().decode([[String: [Double]]].self, from: positionData) {
            var positions: [UUID: CGSize] = [:]
            for entry in positionEntries {
                for (uuidString, values) in entry {
                    if let uuid = UUID(uuidString: uuidString), values.count == 2 {
                        positions[uuid] = CGSize(width: values[0], height: values[1])
                    }
                }
            }
            agentDockManager.restoreDragPositions(positions)
        }

        updateAgentDock()
        LumaLogger.log("[Luma] Restored \(agentSessions.count) agent session(s)")

        // Clear persisted data now that it's loaded — will be re-persisted on quit
        UserDefaults.standard.removeObject(forKey: Self.persistedAgentSessionsKey)
    }

    /// Removes persisted data for a specific agent session (called on termination/dismiss).
    private func erasePersistedAgentSession(id: UUID) {
        // Re-persist all remaining sessions (minus the erased one)
        persistAllAgentSessions()
    }
}
