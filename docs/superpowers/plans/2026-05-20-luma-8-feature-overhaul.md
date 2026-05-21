# Luma 8-Feature Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship 8 independent changes to Luma — fixing the menu bar click bug, removing boot-time agents, making agent spawning intent-driven, adding screen-recording reinit, building a permission onboarding flow with drag-to-Settings popup, adding a dynamic demo, adding auto-hide after 30s idle, and adding a floating ⌘⌘/^^ input bubble.

**Architecture:** All changes are isolated to their own files where possible; cross-cutting changes (boot sequence, classifier routing) touch `CompanionManager.swift` in clearly bounded blocks. New features get new files (`LumaIdleTimer.swift`, `LumaPermissionDragPopup.swift`, `LumaDemoOrchestrator.swift`, `LumaFloatingInputWindowManager.swift`, `LumaFloatingInputView.swift`, `LumaDoubleTapModifierDetector.swift`). Implement in the order listed — each task is self-contained and the app builds cleanly after every task.

**Tech Stack:** Swift 5.9+, SwiftUI (views), AppKit (NSPanel, NSEvent, CGEventTap), ScreenCaptureKit, Combine, `@MainActor` throughout, `DispatchSourceTimer` for idle timer. macOS 14.2+ target.

---

## File Map

| File | Task | Change |
|---|---|---|
| `Luma/MenuBarPanelManager.swift` | 1 | Add status-item frame guard in click-outside monitor |
| `Luma/CompanionManager.swift` | 2, 4, 5, 6 | Remove boot agents; screen-recording reinit hook; idle timer wiring; transient agent spawning |
| `Luma/Agent/AgentSession.swift` | 6 | Add `isTransient: Bool` property |
| `Luma/Agent/AgentHotkeyHandler.swift` | 3 | Remove all hotkey handler body; empty stub |
| `Luma/CompanionScreenCaptureUtility.swift` | 4 | Add `reinitializeCapture()` static method |
| `Luma/LumaIdleTimer.swift` | 5 | **New** — 30s inactivity timer |
| `Luma/OnboardingWizardView.swift` | 7, 8 | Add Permissions step (step 4) and Demo step (step 5); push Done to step 6 |
| `Luma/OnboardingPermissionsStep.swift` | 7 | **New** — SwiftUI view for permissions gate |
| `Luma/LumaPermissionDragPopup.swift` | 7 | **New** — NSPanel pill popup with drag source |
| `Luma/LumaDemoOrchestrator.swift` | 8 | **New** — Dynamic demo sequencer |
| `Luma/OnboardingDemoStep.swift` | 8 | **New** — SwiftUI view for demo step |
| `Luma/LumaDoubleTapModifierDetector.swift` | 9 | **New** — Double-tap ⌘/^ CGEventTap detector |
| `Luma/LumaFloatingInputWindowManager.swift` | 9 | **New** — NSPanel lifecycle for floating input |
| `Luma/LumaFloatingInputView.swift` | 9 | **New** — SwiftUI pill input view |

---

## Task 1: Fix Menu Bar Click Bug

**Files:**
- Modify: `Luma/MenuBarPanelManager.swift` (function `installClickOutsideMonitor`, around line 363)

**Root cause:** `NSEvent.addGlobalMonitorForEvents` fires for status-item clicks because the click event is routed through `SystemUIServer` (which owns the menu bar), making it appear as an "other app" event to the global monitor. The 0.3s dismiss fires after the open animation completes.

- [ ] **Step 1: Open `MenuBarPanelManager.swift` and find `installClickOutsideMonitor()`**

The relevant block starts around line 366:
```swift
clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
    matching: [.leftMouseDown, .rightMouseDown]
) { [weak self] event in
    guard let self, let panel = self.panel else { return }

    let clickLocation = NSEvent.mouseLocation
    if panel.frame.contains(clickLocation) {
        return
    }
    // ... dismiss logic
```

- [ ] **Step 2: Add the status-item button frame guard immediately after the panel frame check**

Replace the existing check block with the extended version:
```swift
clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
    matching: [.leftMouseDown, .rightMouseDown]
) { [weak self] event in
    guard let self, let panel = self.panel else { return }

    let clickLocation = NSEvent.mouseLocation

    // Ignore clicks inside the panel itself.
    if panel.frame.contains(clickLocation) {
        return
    }

    // Ignore clicks on the status item button.
    // Because the status item is owned by SystemUIServer, the global event
    // monitor sees the same click that triggered statusItemClicked — we must
    // exclude that area so the panel doesn't open and immediately close.
    if let statusButton = self.statusItem?.button,
       let buttonWindow = statusButton.window,
       buttonWindow.frame.contains(clickLocation) {
        return
    }

    // Delay dismissal slightly to avoid closing the panel when
    // a system permission dialog appears (e.g. microphone access).
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        guard panel.isVisible else { return }

        if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
            return
        }

        self.hidePanel()
    }
}
```

- [ ] **Step 3: Build and verify**

Build in Xcode (Cmd+B). Then run the app (Cmd+R).
- Click the menu bar icon once → panel should open and **stay open**.
- Click the menu bar icon again → panel should close.
- Click anywhere outside the panel → panel should close after ~0.3s.
- Previously required 2 clicks; now 1 click works correctly.

- [ ] **Step 4: Commit**
```bash
git add Luma/MenuBarPanelManager.swift
git commit -m "fix: exclude status item frame from click-outside dismiss monitor"
```

---

## Task 2: No Agents on Boot

**Files:**
- Modify: `Luma/CompanionManager.swift` (the agent-restore block in `start()`, around line 355)

- [ ] **Step 1: Locate the agent restore block in `start()`**

Find and read this block (approximately lines 354–370):
```swift
// Initialize agent session system only if agent mode is enabled
if isAgentModeEnabled {
    // Restore persisted sessions from previous app launch, or create a default one
    restorePersistedAgentSessions()
    if agentSessions.isEmpty {
        ensureDefaultAgentSession()
    }
}
// Only register hotkeys when at least one agent session exists.
if !agentSessions.isEmpty {
    AgentHotkeyHandler.shared.startMonitoring(companionManager: self)
}
```

- [ ] **Step 2: Remove the entire agent restore + hotkey startup block**

Delete those lines entirely. The `agentSessions` array starts empty by default. No agents appear at launch. Replace with a single comment:
```swift
// Agent sessions are spawned on demand by the intent classifier or explicit
// user voice commands. No sessions are created or restored at launch.
```

- [ ] **Step 3: Build and verify**

Build (Cmd+B). Run the app (Cmd+R).
- On launch: only the menu bar icon appears. No floating bubbles.
- If previous sessions were persisted, they should NOT appear.
- Open the menu bar panel → agent section should show as empty (no sessions listed).

- [ ] **Step 4: Commit**
```bash
git add Luma/CompanionManager.swift
git commit -m "fix: don't restore or create agent sessions on boot"
```

---

## Task 3: Remove Agent Hotkeys

**Files:**
- Modify: `Luma/Agent/AgentHotkeyHandler.swift`
- Modify: `Luma/CompanionManager.swift` (remove all `AgentHotkeyHandler.shared.startMonitoring` / `stopMonitoring` call sites)

- [ ] **Step 1: Gut `AgentHotkeyHandler.handleKeyEvent` — make it always return false**

Replace the `handleKeyEvent` method body so no hotkeys fire:
```swift
/// Agent spawn hotkeys have been removed. Agents are now spawned exclusively
/// by the intent classifier when a task requires one, or by explicit voice
/// command ("new agent", "Luma agent"). This method is kept as an empty stub
/// so call sites don't need to be removed.
@discardableResult
private func handleKeyEvent(_ event: NSEvent) -> Bool {
    return false
}
```

- [ ] **Step 2: Remove all `AgentHotkeyHandler.shared.startMonitoring` call sites in `CompanionManager.swift`**

Search for `AgentHotkeyHandler.shared.startMonitoring` in `CompanionManager.swift`. There are two:
1. In the (now-deleted) boot block — already removed by Task 2.
2. In `createAndSelectNewAgentSession()` — delete this line:
```swift
// DELETE this line:
AgentHotkeyHandler.shared.startMonitoring(companionManager: self)
```

Also search for `AgentHotkeyHandler.shared.stopMonitoring()` — there are two:
1. In `dismissAgentSession(id:)` — delete it.
2. In `stop()` — delete it.

- [ ] **Step 3: Build and verify**

Build (Cmd+B). Run the app.
- Ctrl+Cmd+N → should do nothing (no new agent bubble).
- Ctrl+Option+Tab → should do nothing.
- Ctrl+Option+1 → should do nothing.

- [ ] **Step 4: Commit**
```bash
git add Luma/Agent/AgentHotkeyHandler.swift Luma/CompanionManager.swift
git commit -m "feat: remove agent spawn hotkeys — agents are now intent-driven only"
```

---

## Task 4: Screen Recording Permission Without Restart

**Files:**
- Modify: `Luma/CompanionScreenCaptureUtility.swift`
- Modify: `Luma/CompanionManager.swift` (`refreshAllPermissions()`)

- [ ] **Step 1: Add `Notification.Name` for screen recording grant**

At the top of `CompanionManager.swift`, near the other `Notification.Name` extensions, add:
```swift
extension Notification.Name {
    /// Posted when screen recording permission transitions from denied to granted
    /// during a live session. Observers should reinitialize their ScreenCaptureKit
    /// state rather than requiring an app restart.
    static let lumaScreenRecordingPermissionGranted = Notification.Name("lumaScreenRecordingPermissionGranted")
}
```

- [ ] **Step 2: Post the notification in `refreshAllPermissions()` when screen recording flips false→true**

In `CompanionManager.refreshAllPermissions()`, the code already tracks `previouslyHadScreenRecording`. Find the analytics call that fires on that transition (around line 626):
```swift
if !previouslyHadScreenRecording && hasScreenRecordingPermission {
    LumaAnalytics.trackPermissionGranted(permission: "screen_recording")
}
```

Add the notification post immediately after the analytics call:
```swift
if !previouslyHadScreenRecording && hasScreenRecordingPermission {
    LumaAnalytics.trackPermissionGranted(permission: "screen_recording")
    // Notify observers that screen recording was just granted so they can
    // reinitialize ScreenCaptureKit without requiring an app restart.
    NotificationCenter.default.post(name: .lumaScreenRecordingPermissionGranted, object: nil)
    LumaLogger.log("[Luma] Screen recording permission granted — posting reinit notification")
}
```

- [ ] **Step 3: Add `reinitializeCapture()` to `CompanionScreenCaptureUtility.swift`**

Open `CompanionScreenCaptureUtility.swift`. Add this static method at the end of the file (before the final closing brace):
```swift
/// Clears any cached ScreenCaptureKit state that was formed while screen
/// recording permission was denied. Call this after the user grants permission
/// so that subsequent captures succeed without an app restart.
///
/// SCShareableContent caches the denied state internally. The only reliable
/// way to clear it is to issue a new shareable-content request, which forces
/// SCK to re-evaluate the current permission state.
static func reinitializeCapture() async {
    do {
        // Issuing this request is enough to flush the SCK permission cache.
        // We discard the result — the next real capture call will succeed.
        _ = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        LumaLogger.log("[ScreenCapture] ScreenCaptureKit reinitialized after permission grant")
    } catch {
        LumaLogger.log("[ScreenCapture] reinitializeCapture error (non-fatal): \(error)")
    }
}
```

- [ ] **Step 4: Observe the notification in `CompanionManager.start()` and call `reinitializeCapture()`**

In `CompanionManager.start()`, near the other notification observers (after `agentTaskCompletedObserver` setup), add:
```swift
// Reinitialize ScreenCaptureKit when the user grants screen recording permission
// during a live session so captures work immediately without an app restart.
NotificationCenter.default.addObserver(
    forName: .lumaScreenRecordingPermissionGranted,
    object: nil,
    queue: .main
) { _ in
    Task {
        await CompanionScreenCaptureUtility.reinitializeCapture()
    }
}
```

- [ ] **Step 5: Build and verify**

Build (Cmd+B). To verify:
1. Revoke screen recording permission for Luma in System Settings.
2. Run the app. Attempt a voice command that takes a screenshot → should fail silently.
3. Re-grant screen recording in System Settings (don't restart).
4. Wait 1.5s for the polling cycle. Attempt a voice command again → should succeed without restart.

- [ ] **Step 6: Commit**
```bash
git add Luma/CompanionManager.swift Luma/CompanionScreenCaptureUtility.swift
git commit -m "feat: reinitialize ScreenCaptureKit after screen recording permission granted without restart"
```

---

## Task 5: Auto-Hide After 30 Seconds of Inactivity

**Files:**
- Create: `Luma/LumaIdleTimer.swift`
- Modify: `Luma/CompanionManager.swift`
- Modify: `Luma/MenuBarPanelManager.swift`

- [ ] **Step 1: Create `Luma/LumaIdleTimer.swift`**

```swift
//
//  LumaIdleTimer.swift
//  Luma
//
//  Tracks user inactivity. After `interval` seconds with no interaction,
//  fires `onTimeout`. Any call to `reset()` restarts the countdown.
//  Call `suspend()` to pause the timer without losing the interval value
//  (used during onboarding so the wizard is never hidden mid-flow).
//  Call `resume()` to restart after a suspend.
//
//  Owned by CompanionManager. Thread-safe: all mutations happen on the main queue.
//

import Foundation

@MainActor
final class LumaIdleTimer {

    /// Closure called when the idle interval elapses with no interaction.
    var onTimeout: (() -> Void)?

    private let idleInterval: TimeInterval
    private var timer: DispatchSourceTimer?
    private var isSuspended: Bool = false
    private var isRunning: Bool = false

    init(interval: TimeInterval = 30) {
        self.idleInterval = interval
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Resets the idle countdown. Call this on every user interaction.
    /// If the timer was suspended, this is a no-op until `resume()` is called.
    func reset() {
        guard !isSuspended else { return }
        scheduleTimer()
    }

    /// Starts the idle timer from scratch (e.g. when Luma becomes visible).
    /// Ignored if already running and not suspended.
    func start() {
        guard !isSuspended else { return }
        scheduleTimer()
    }

    /// Stops the idle timer entirely (e.g. when Luma is hidden).
    func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
    }

    /// Suspends the countdown without cancelling. Use during onboarding so
    /// the wizard is never hidden mid-flow.
    func suspend() {
        isSuspended = true
        timer?.suspend()
    }

    /// Resumes from a suspended state and resets the countdown to the full interval.
    func resume() {
        isSuspended = false
        scheduleTimer()
    }

    // MARK: - Private

    private func scheduleTimer() {
        // Cancel any existing timer before creating a new one.
        timer?.cancel()
        timer = nil

        let newTimer = DispatchSource.makeTimerSource(queue: .main)
        newTimer.schedule(deadline: .now() + idleInterval)
        newTimer.setEventHandler { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.isRunning = false
            self.onTimeout?()
        }
        newTimer.resume()
        timer = newTimer
        isRunning = true
    }
}
```

- [ ] **Step 2: Add `idleTimer` to `CompanionManager` and wire `onTimeout`**

In `CompanionManager.swift`, add the property near the other manager properties (around line 86–100):
```swift
/// Fires after 30 seconds of no interaction (voice command, text input, menu bar
/// click, agent spawn, floating input) and hides all visible Luma UI. The menu
/// bar icon stays visible so the user can bring Luma back.
let idleTimer = LumaIdleTimer(interval: 30)
```

In `CompanionManager.start()`, after `refreshAllPermissions()` and `startPermissionPolling()`, add:
```swift
// Wire the idle timer's timeout to hide Luma's visible UI.
// The timer only starts when Luma becomes visible (driven by overlay/panel show events).
// It is suspended during onboarding so the wizard is never hidden mid-flow.
idleTimer.onTimeout = { [weak self] in
    guard let self else { return }
    LumaLogger.log("[LumaIdleTimer] 30s idle — hiding Luma UI")
    // Hide the cursor overlay
    self.overlayWindowManager.hideOverlay()
    self.isOverlayVisible = false
    // Dismiss the menu bar panel (if open)
    NotificationCenter.default.post(name: .lumaDismissPanel, object: nil)
}

// Suspend the idle timer while onboarding is in progress.
// The wizard must never disappear mid-flow due to inactivity.
if !hasCompletedOnboarding {
    idleTimer.suspend()
}
```

- [ ] **Step 3: Resume the idle timer when onboarding completes**

In `CompanionManager`, add a Combine observer that watches `hasCompletedOnboarding` via `UserDefaults`. The cleanest place is in `start()`, after the idle timer setup:

```swift
// Resume the idle timer the moment onboarding finishes.
// `hasCompletedOnboarding` is stored in UserDefaults; observe it via KVO
// through Combine so we react immediately when the flag is written.
NotificationCenter.default.publisher(
    for: UserDefaults.didChangeNotification
)
.receive(on: DispatchQueue.main)
.sink { [weak self] _ in
    guard let self else { return }
    let isOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    if isOnboarded && self.idleTimer.isSuspended {
        // Make isSuspended readable — add a public getter in LumaIdleTimer (see Step 4)
    }
}
.store(in: &cancellables)
```

Wait — `isSuspended` is private. Expose it:

- [ ] **Step 4: Expose `isSuspended` as a public read-only property in `LumaIdleTimer`**

In `LumaIdleTimer.swift`, change:
```swift
private var isSuspended: Bool = false
```
to:
```swift
private(set) var isSuspended: Bool = false
```

Now update the observer in `CompanionManager.start()`:
```swift
NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in
        guard let self else { return }
        let isOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if isOnboarded && self.idleTimer.isSuspended {
            self.idleTimer.resume()
            LumaLogger.log("[LumaIdleTimer] Onboarding complete — idle timer resumed")
        }
    }
    .store(in: &cancellables)
```

- [ ] **Step 5: Reset the idle timer on every user interaction in `CompanionManager`**

Find `classifyAndRouteInput(_:)`. At the very top of the function body (before any other logic), add:
```swift
// Any user input resets the 30-second idle countdown.
idleTimer.reset()
```

Find the overlay show path in `start()` where `overlayWindowManager.showOverlay(...)` is called (showing the cursor). After that call, add:
```swift
idleTimer.start()
```

- [ ] **Step 6: Reset the idle timer in `MenuBarPanelManager.showPanel()`**

In `MenuBarPanelManager.showPanel()`, at the top of the function body (before any other logic), add:
```swift
// Menu bar icon click counts as an interaction — reset the idle countdown.
companionManager.idleTimer.reset()
// If Luma was idle-hidden, start the timer again now that the panel is opening.
companionManager.idleTimer.start()
```

- [ ] **Step 7: Stop the idle timer when Luma is hidden**

In `CompanionManager`, find `scheduleTransientHideIfNeeded()`. After the overlay hide call, add:
```swift
idleTimer.stop()
```

Also in `CompanionManager.stop()` (the full app-shutdown method), add:
```swift
idleTimer.stop()
```

- [ ] **Step 8: Build and verify**

Build (Cmd+B). Run the app.
- Trigger a voice command → Luma responds, timer starts.
- Wait 30 seconds without any interaction → overlay and panel should disappear. Menu bar icon stays.
- Click the menu bar icon → Luma reappears, timer resets.
- During the first-launch onboarding wizard: wait 60 seconds → wizard should NOT hide.

- [ ] **Step 9: Commit**
```bash
git add Luma/LumaIdleTimer.swift Luma/CompanionManager.swift Luma/MenuBarPanelManager.swift
git commit -m "feat: hide Luma after 30s inactivity, suspended during onboarding"
```

---

## Task 6: Intent-Based Agent Spawning

**Files:**
- Modify: `Luma/Agent/AgentSession.swift`
- Modify: `Luma/CompanionManager.swift` (`executeClassifiedPath`, `agentTaskCompletedObserver`, `classifyAndRouteInput`)

### Part A: Add `isTransient` to `AgentSession`

- [ ] **Step 1: Add `isTransient` property to `AgentSession`**

In `AgentSession.swift`, find the `isCLISession` computed property (around line 96). Add `isTransient` immediately before it:
```swift
/// When true, this session was spawned automatically to handle a single
/// classified task. It will be dismissed automatically when the task
/// completes — the user did not explicitly request a persistent agent.
var isTransient: Bool = false
```

### Part B: Check for explicit "new agent" command before classification

- [ ] **Step 2: Add pre-classifier check in `classifyAndRouteInput`**

In `CompanionManager.classifyAndRouteInput(_:)`, find the line that calls the classifier:
```swift
voiceState = .processing
let result = await LumaIntentClassifier.shared.classify(userInput: transcript)
```

Insert a check immediately before the `voiceState = .processing` line:
```swift
// Check for explicit agent spawn request BEFORE running the full classifier.
// "Luma agent" or "new agent" in the transcript always spawns a persistent agent,
// bypassing classification — the user is making a direct structural request.
let lowercasedTranscript = transcript.lowercased()
let isExplicitAgentRequest = lowercasedTranscript.contains("luma agent")
    || lowercasedTranscript.contains("new agent")
    || lowercasedTranscript.contains("spawn agent")
if isExplicitAgentRequest {
    LumaLogger.log("[LumaClassifier] Explicit agent request detected — spawning persistent agent")
    let persistentSession = createAndSelectNewAgentSession()
    // isTransient remains false (default) — this agent persists until dismissed by the user
    updateAgentDock()
    voiceState = .idle
    return
}
```

### Part C: Mark spawned agents as transient and auto-dismiss on completion

- [ ] **Step 3: Mark the CLI-path agent as transient**

In `executeClassifiedPath`, find the `.cli` case. After `agentSessions.append(claudeCodeSession)`, add:
```swift
// This agent was spawned automatically to handle one classified task.
// It will be dismissed automatically when the task completes.
claudeCodeSession.isTransient = true
```

- [ ] **Step 4: Mark the visual_agent path agent as transient**

The `visual_agent` path calls `LumaFlowEngine.shared.startFlow(...)`. `LumaFlowEngine` creates its own agent session internally. Find or add a way to mark it. Check if `LumaFlowEngine.startFlow` returns or exposes the session it creates. If it does, mark it transient there. If not, add an `isTransientFlow: Bool` parameter:

Open `LumaFlowEngine.swift` and find `startFlow`. If it stores the session in a property (e.g. `currentSession`), add after `startFlow` returns (in the Task block in `executeClassifiedPath`):
```swift
Task { @MainActor [weak self] in
    guard let self else { return }
    await LumaFlowEngine.shared.startFlow(goal: goal, companionManager: self)
    // Mark the session created by the flow engine as transient if accessible
    if let flowSession = LumaFlowEngine.shared.currentSession {
        flowSession.isTransient = true
    }
}
```

If `LumaFlowEngine` doesn't expose the session, add a `var currentSession: AgentSession?` property to it. Read `LumaFlowEngine.swift` to see the actual structure before making this edit.

- [ ] **Step 5: Auto-dismiss transient sessions in `agentTaskCompletedObserver`**

In `CompanionManager.start()`, inside the `agentTaskCompletedObserver` handler (around line 381), after `self.updateAgentDock()`, add:
```swift
// Auto-dismiss transient sessions (spawned by the classifier for a single task).
// Persistent sessions (user-requested agents) remain until the user dismisses them.
if let sessionId = notification.userInfo?["sessionId"] as? UUID,
   let completedSession = self.agentSessions.first(where: { $0.id == sessionId }),
   completedSession.isTransient {
    // Small delay so the user can read the completion bubble text before the session disappears
    Task {
        try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds
        await self.dismissAgentSession(id: sessionId)
        LumaLogger.log("[Luma] Auto-dismissed transient session: \(sessionId)")
    }
}
```

- [ ] **Step 6: Build and verify**

Build (Cmd+B). Run the app.
- Say "open Finder" → classifier routes to `response`, no agent spawned.
- Say "write a Python script that lists my Downloads" → classifier routes to `cli`, one agent bubble appears, executes, then disappears after 4s.
- Say "new agent" → one persistent agent bubble spawns. Stays visible until manually dismissed.
- Say "Luma agent" → same as above.

- [ ] **Step 7: Commit**
```bash
git add Luma/Agent/AgentSession.swift Luma/CompanionManager.swift
git commit -m "feat: intent-driven agent spawning — transient for tasks, persistent for explicit requests"
```

---

## Task 7: Onboarding Permissions Flow

**Files:**
- Create: `Luma/OnboardingPermissionsStep.swift`
- Create: `Luma/LumaPermissionDragPopup.swift`
- Modify: `Luma/OnboardingWizardView.swift`

### Part A: `LumaPermissionDragPopup`

- [ ] **Step 1: Create `Luma/LumaPermissionDragPopup.swift`**

```swift
//
//  LumaPermissionDragPopup.swift
//  Luma
//
//  A compact floating pill panel that lets the user drag Luma's .app bundle
//  into a System Settings privacy list to grant a permission.
//
//  Flow:
//  1. Caller calls `show(for:)` — opens System Settings to the correct pane
//     and spawns this popup floating above it.
//  2. User drags the Luma icon from the popup into the System Settings list.
//     macOS accepts the .app bundle URL natively (same as dragging from Finder).
//  3. CompanionManager.refreshAllPermissions() polls every 1.5s and detects
//     the permission flip. It posts Notification.Name.lumaPermissionGranted
//     which this popup observes to auto-dismiss itself.
//
//  One popup instance per permission type. Callers must call `dismiss()` or
//  let the notification auto-dismiss it.
//

import AppKit
import SwiftUI

/// The three permissions Luma requires.
enum LumaRequiredPermission {
    case screenRecording
    case accessibility
    case microphone

    var displayName: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility:   return "Accessibility"
        case .microphone:      return "Microphone"
        }
    }

    /// Deep-link URL for the correct System Settings privacy pane.
    var systemSettingsURL: URL {
        switch self {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        }
    }
}

extension Notification.Name {
    /// Posted by CompanionManager when a specific permission transitions to granted.
    /// userInfo key "permission" carries a LumaRequiredPermission value.
    static let lumaPermissionGranted = Notification.Name("lumaPermissionGranted")
}

@MainActor
final class LumaPermissionDragPopupManager {

    /// One popup per permission type, keyed by type. Ensures only one popup
    /// is shown per permission even if the user taps "Give" multiple times.
    private var activePopups: [ObjectIdentifier: LumaPermissionDragPopup] = [:]

    func showPopup(for permission: LumaRequiredPermission) {
        // Open System Settings to the correct privacy pane
        NSWorkspace.shared.open(permission.systemSettingsURL)

        // Show the drag popup (or focus it if already visible)
        let key = ObjectIdentifier(permission.displayName as AnyObject)
        if activePopups[key] == nil {
            let popup = LumaPermissionDragPopup(permission: permission) { [weak self] in
                self?.activePopups.removeValue(forKey: key)
            }
            activePopups[key] = popup
            popup.show()
        }
    }
}

// MARK: - LumaPermissionDragPopup

/// One floating pill panel for one permission type.
@MainActor
final class LumaPermissionDragPopup: NSObject {

    private let permission: LumaRequiredPermission
    private let onDismiss: () -> Void
    private var panel: NSPanel?
    private var grantObserver: NSObjectProtocol?

    init(permission: LumaRequiredPermission, onDismiss: @escaping () -> Void) {
        self.permission = permission
        self.onDismiss = onDismiss
    }

    func show() {
        let contentView = PermissionDragPillView(permission: permission)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 260, height: 64)

        let dragPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        dragPanel.isFloatingPanel = true
        dragPanel.level = .floating
        dragPanel.isOpaque = false
        dragPanel.backgroundColor = .clear
        dragPanel.hasShadow = true
        dragPanel.hidesOnDeactivate = false
        dragPanel.isExcludedFromWindowsMenu = true
        dragPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        dragPanel.contentView = hostingView

        // Position in the bottom-right area of the primary screen, above the dock
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelX = screenFrame.maxX - 280
            let panelY = screenFrame.minY + 80
            dragPanel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        }

        dragPanel.makeKeyAndOrderFront(nil)
        dragPanel.orderFrontRegardless()
        self.panel = dragPanel

        // Auto-dismiss when the permission is granted
        grantObserver = NotificationCenter.default.addObserver(
            forName: .lumaPermissionGranted,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let grantedPermission = notification.userInfo?["permission"] as? LumaRequiredPermission,
                  grantedPermission.displayName == self.permission.displayName else { return }
            Task { @MainActor [weak self] in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        if let observer = grantObserver {
            NotificationCenter.default.removeObserver(observer)
            grantObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        onDismiss()
    }
}

// MARK: - Pill View (SwiftUI)

/// The pill-shaped drag source view shown inside the popup panel.
private struct PermissionDragPillView: View {

    let permission: LumaRequiredPermission

    var body: some View {
        HStack(spacing: 12) {
            // Drag source: Luma .app icon — acts as a real drag source providing
            // the .app bundle URL, identical to dragging from Finder.
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 36, height: 36)
                .cornerRadius(8)
                .onDrag {
                    // Provide the .app bundle URL so macOS System Settings accepts it
                    // exactly as it would when dragging from Finder.
                    let appURL = URL(fileURLWithPath: Bundle.main.bundlePath)
                    return NSItemProvider(object: appURL as NSURL)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Drag to give permission")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(permission.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#9BA39D"))
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: "#1A1C1A"))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(hex: "#2E322E"), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 4)
        .preferredColorScheme(.dark)
    }
}
```

- [ ] **Step 2: Post `lumaPermissionGranted` in `CompanionManager.refreshAllPermissions()`**

In `refreshAllPermissions()`, after the existing analytics calls for each permission flip, add the notification posts:

For screen recording (after the existing analytics call + reinit notification added in Task 4):
```swift
if !previouslyHadScreenRecording && hasScreenRecordingPermission {
    LumaAnalytics.trackPermissionGranted(permission: "screen_recording")
    NotificationCenter.default.post(name: .lumaScreenRecordingPermissionGranted, object: nil)
    NotificationCenter.default.post(
        name: .lumaPermissionGranted,
        object: nil,
        userInfo: ["permission": LumaRequiredPermission.screenRecording]
    )
}
```

For accessibility (find the existing `!previouslyHadAccessibility && hasAccessibilityPermission` block):
```swift
if !previouslyHadAccessibility && hasAccessibilityPermission {
    LumaAnalytics.trackPermissionGranted(permission: "accessibility")
    NotificationCenter.default.post(
        name: .lumaPermissionGranted,
        object: nil,
        userInfo: ["permission": LumaRequiredPermission.accessibility]
    )
}
```

For microphone (find the existing `!previouslyHadMicrophone && hasMicrophonePermission` block):
```swift
if !previouslyHadMicrophone && hasMicrophonePermission {
    LumaAnalytics.trackPermissionGranted(permission: "microphone")
    NotificationCenter.default.post(
        name: .lumaPermissionGranted,
        object: nil,
        userInfo: ["permission": LumaRequiredPermission.microphone]
    )
}
```

### Part B: `OnboardingPermissionsStep` view

- [ ] **Step 3: Create `Luma/OnboardingPermissionsStep.swift`**

```swift
//
//  OnboardingPermissionsStep.swift
//  Luma
//
//  Wizard step 4: shows all three required permissions with live status chips.
//  The "Continue" button is only enabled when all three are granted.
//
//  Each "Give" button:
//  1. Opens System Settings to the correct privacy pane via deep link.
//  2. Spawns a LumaPermissionDragPopup so the user can drag Luma into the list.
//
//  Permission status is read from CompanionManager's @Published properties,
//  which are polled every 1.5s by the existing permission-polling timer.
//

import SwiftUI

@MainActor
struct OnboardingPermissionsStep: View {

    /// Injected from OnboardingWizardView so this step can read live permission state.
    @ObservedObject var companionManager: CompanionManager

    /// Called when all permissions are granted and the user taps Continue.
    var onAllPermissionsGranted: () -> Void

    private let dragPopupManager = LumaPermissionDragPopupManager()

    var allGranted: Bool {
        companionManager.hasScreenRecordingPermission
        && companionManager.hasAccessibilityPermission
        && companionManager.hasMicrophonePermission
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Text("Give Luma access")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color(hex: "#ECEEED"))
                Text("All three permissions are required to continue.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#9BA39D"))
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 28)

            // Permission rows
            VStack(spacing: 10) {
                permissionRow(
                    icon: "display",
                    name: "Screen Recording",
                    description: "Lets Luma see your screen to assist you",
                    isGranted: companionManager.hasScreenRecordingPermission,
                    permission: .screenRecording
                )
                permissionRow(
                    icon: "accessibility",
                    name: "Accessibility",
                    description: "Lets Luma read and interact with UI elements",
                    isGranted: companionManager.hasAccessibilityPermission,
                    permission: .accessibility
                )
                permissionRow(
                    icon: "mic",
                    name: "Microphone",
                    description: "Lets Luma hear your voice commands",
                    isGranted: companionManager.hasMicrophonePermission,
                    permission: .microphone
                )
            }
            .padding(.horizontal, 40)

            Spacer()

            // Continue button
            VStack(spacing: 8) {
                Button(action: { if allGranted { onAllPermissionsGranted() } }) {
                    Text("Continue →")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(allGranted ? Color(hex: "#ECEEED") : Color(hex: "#444"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(allGranted ? Color(hex: "#2563EB") : Color(hex: "#1A1C1A"))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!allGranted)
                .onHover { isHovering in
                    if allGranted {
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }

                if !allGranted {
                    Text("Waiting for \(missingPermissionNames)…")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#555D58"))
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
    }

    private var missingPermissionNames: String {
        var missing: [String] = []
        if !companionManager.hasScreenRecordingPermission { missing.append("Screen Recording") }
        if !companionManager.hasAccessibilityPermission  { missing.append("Accessibility") }
        if !companionManager.hasMicrophonePermission     { missing.append("Microphone") }
        return missing.joined(separator: ", ")
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        name: String,
        description: String,
        isGranted: Bool,
        permission: LumaRequiredPermission
    ) -> some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(isGranted ? Color(hex: "#34D399") : Color(hex: "#9BA39D"))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isGranted ? Color(hex: "#1A2F1A") : Color(hex: "#1A1C1A"))
                )

            // Name + description
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "#ECEEED"))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#555D58"))
            }

            Spacer()

            // Status chip or Give button
            if isGranted {
                Label("Granted", systemImage: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#34D399"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(hex: "#1A2F1A"))
                            .overlay(Capsule().stroke(Color(hex: "#2A5A2A"), lineWidth: 1))
                    )
            } else {
                Button("Give") {
                    dragPopupManager.showPopup(for: permission)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#ECEEED"))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(hex: "#2563EB"))
                )
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: "#1A1C1A"))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            isGranted ? Color(hex: "#2A5A2A") : Color(hex: "#2E322E"),
                            lineWidth: 1
                        )
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isGranted)
    }
}
```

### Part C: Wire the new step into `OnboardingWizardView`

- [ ] **Step 4: Add Permissions as step 4 and push Done to step 6 in `OnboardingWizardView.swift`**

Update the step names array:
```swift
// Was: ["Welcome", "Account", "Security", "API Setup", "Done"]
// Now: 7 steps — Permissions inserted before Done
private let onboardingStepNames = [
    "Welcome", "Account", "Security", "API Setup", "Permissions", "Demo", "Done"
]
```

Update `stepContentView` switch to add steps 4 and 5, and move Done to 6:
```swift
switch currentStep {
case 0:
    OnboardingWelcomeStep(onGetStarted: advanceToNextStep)
case 1:
    OnboardingAccountCreationStep(onAccountCreated: advanceToNextStep)
case 2:
    OnboardingPINSetupStep(onPINStepComplete: advanceToNextStep)
case 3:
    OnboardingAPIProfileStep(onProfileSaved: advanceToNextStep)
case 4:
    // Permissions gate — Continue only enabled when all three are granted.
    // companionManager must be passed in from the parent.
    OnboardingPermissionsStep(
        companionManager: companionManager,
        onAllPermissionsGranted: advanceToNextStep
    )
case 5:
    // Dynamic demo — only shown after all permissions are confirmed granted.
    OnboardingDemoStep(
        companionManager: companionManager,
        onDemoComplete: advanceToNextStep
    )
case 6:
    OnboardingDoneStep(onStartLearning: completeOnboarding)
default:
    EmptyView()
}
```

Update the bottom navigation row guard (was `currentStep < 4`, now `currentStep < 6`):
```swift
if currentStep > 0 && currentStep < 6 {
    bottomNavigationRow
}
```

Update the step counter label (was `"Step \(currentStep) of 3"`, now `"Step \(currentStep) of 5"`):
```swift
Text("Step \(currentStep) of 5")
```

Add `companionManager` as a property to `OnboardingWizardView` (it needs it to pass to the new steps):
```swift
@ObservedObject var companionManager: CompanionManager
```

Update all call sites that instantiate `OnboardingWizardView` to pass `companionManager`. The main call site is in `OnboardingWizardWindowManager` or `LumaApp.swift` — search for `OnboardingWizardView(hasCompletedOnboarding:` and add the companionManager parameter.

- [ ] **Step 5: Build and verify**

Build (Cmd+B). Run the app on a fresh launch (or reset `hasCompletedOnboarding` in UserDefaults via `defaults delete com.nox.luma hasCompletedOnboarding` in Terminal).
- Wizard opens → step through Welcome, Account, Security, API Setup.
- Step 4 (Permissions): all rows show "Required" if not granted.
- Click "Give" on Screen Recording → System Settings opens to Privacy > Screen Recording + drag popup appears.
- Grant the permission in System Settings → within 1.5s, the onboarding row updates to "✓ Granted" and the drag popup auto-dismisses.
- When all three show "✓ Granted" → Continue button activates.

- [ ] **Step 6: Commit**
```bash
git add Luma/LumaPermissionDragPopup.swift Luma/OnboardingPermissionsStep.swift \
        Luma/OnboardingWizardView.swift Luma/CompanionManager.swift
git commit -m "feat: add onboarding permissions step with drag-to-SystemSettings popup"
```

---

## Task 8: Interactive Demo (Dynamic)

**Files:**
- Create: `Luma/LumaDemoOrchestrator.swift`
- Create: `Luma/OnboardingDemoStep.swift`

- [ ] **Step 1: Create `Luma/LumaDemoOrchestrator.swift`**

```swift
//
//  LumaDemoOrchestrator.swift
//  Luma
//
//  Drives the post-permission interactive demo sequence:
//  1. Capture screen + AX scan for 2-3 visible named UI elements
//  2. Narrate + point cursor at each element
//  3. Invite the user to give a command
//  4. Execute the command through the normal pipeline
//  5. Mark demo complete
//
//  Used by OnboardingDemoStep. Owns its own async Task so the view can
//  cancel it if the user skips or the wizard moves back.
//

import AppKit
import Foundation

@MainActor
final class LumaDemoOrchestrator: ObservableObject {

    /// Published so the demo view can reflect the current phase.
    enum DemoPhase {
        case scanning
        case narrating(elementName: String)
        case inviting
        case executing
        case complete
    }

    @Published private(set) var phase: DemoPhase = .scanning
    @Published private(set) var spokenText: String = ""

    private weak var companionManager: CompanionManager?
    private var demoTask: Task<Void, Never>?

    func start(companionManager: CompanionManager) {
        self.companionManager = companionManager
        demoTask = Task { [weak self] in
            await self?.runDemoSequence(companionManager: companionManager)
        }
    }

    func cancel() {
        demoTask?.cancel()
        demoTask = nil
    }

    // MARK: - Demo Sequence

    private func runDemoSequence(companionManager: CompanionManager) async {
        guard !Task.isCancelled else { return }

        // Step 1: AX scan for visible UI elements
        phase = .scanning
        let demoElements = await scanVisibleElements()

        guard !Task.isCancelled else { return }

        if demoElements.isEmpty {
            // Fallback narration when AX finds nothing interesting
            let fallbackText = "I can see your screen. I can help you navigate apps, open files, answer questions, and more. Try giving me a command."
            await speak(fallbackText, via: companionManager)
        } else {
            // Narrate and point at each element
            for element in demoElements {
                guard !Task.isCancelled else { return }
                phase = .narrating(elementName: element.name)

                let narration = buildNarration(for: element, totalCount: demoElements.count)
                await speak(narration, via: companionManager)

                // Point the cursor at the element
                NotificationCenter.default.post(
                    name: CursorGuide.pointAtNotificationName,
                    object: nil,
                    userInfo: [
                        "targetPoint": element.screenPoint,
                        "bubbleText": element.name
                    ]
                )

                // Brief pause between elements
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }

        guard !Task.isCancelled else { return }

        // Step 2: Invite the user to give a command
        phase = .inviting
        let inviteText = "You're all set. Try giving me a command — hold Control and Option and speak, or type below."
        await speak(inviteText, via: companionManager)
    }

    /// Scans the frontmost app's AX tree for 2-3 named interactive elements.
    /// Falls back to an empty array if AX is unavailable or the app has no named children.
    private func scanVisibleElements() async -> [DemoElement] {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return [] }
        let axApp = AXUIElementCreateApplication(frontmostApp.processIdentifier)

        var focusedWindowValue: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindowValue)
        guard let focusedWindow = focusedWindowValue else { return [] }

        var childrenValue: CFTypeRef?
        AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXChildrenAttribute as CFString, &childrenValue)
        guard let children = childrenValue as? [AXUIElement] else { return [] }

        var results: [DemoElement] = []
        for child in children.prefix(20) {
            guard results.count < 3 else { break }

            var titleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleValue)
            guard let title = titleValue as? String, !title.isEmpty else { continue }

            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue)
            let role = roleValue as? String ?? ""

            // Only use interactive or named elements — skip containers and unknown roles
            let isInteresting = ["AXButton", "AXTextField", "AXList", "AXMenuItem", "AXLink"].contains(role)
            guard isInteresting else { continue }

            var frameValue: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXFrameAttribute as CFString, &frameValue)
            guard let frameRef = frameValue,
                  let frame = (frameRef as? NSValue)?.rectValue ?? extractCGRect(from: frameRef) else { continue }

            // Convert AX (Quartz, top-left origin) to AppKit (bottom-left origin)
            if let screen = NSScreen.main {
                let appKitY = screen.frame.height - frame.midY
                let screenPoint = CGPoint(x: frame.midX, y: appKitY)
                results.append(DemoElement(name: title, role: role, screenPoint: screenPoint))
            }
        }

        return results
    }

    private func extractCGRect(from value: CFTypeRef) -> CGRect? {
        var rect = CGRect.zero
        let success = AXValueGetValue(value as! AXValue, .cgRect, &rect)
        return success ? rect : nil
    }

    private func buildNarration(for element: DemoElement, totalCount: Int) -> String {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "this app"
        if totalCount == 1 {
            return "I can see \(appName) is open. I can see the \(element.name)."
        } else {
            return "I can see the \(element.name)."
        }
    }

    private func speak(_ text: String, via companionManager: CompanionManager) async {
        spokenText = text
        // Use the existing NativeTTSClient via companionManager's internal client.
        // The simplest bridge: post the text as a spoken summary via the overlay.
        // For the demo we speak directly without waiting for push-to-talk.
        companionManager.speakDemoText(text)
        // Wait a reasonable time for TTS to complete (approximate based on word count)
        let wordCount = text.split(separator: " ").count
        let estimatedSeconds = max(2.0, Double(wordCount) * 0.35)
        try? await Task.sleep(nanoseconds: UInt64(estimatedSeconds * 1_000_000_000))
    }

    // MARK: - Model

    struct DemoElement {
        let name: String
        let role: String
        let screenPoint: CGPoint
    }
}
```

- [ ] **Step 2: Add `speakDemoText(_:)` to `CompanionManager`**

`LumaDemoOrchestrator` needs to call TTS. `nativeTTSClient` is private. Add a thin public method in `CompanionManager.swift`:
```swift
/// Speaks text during the onboarding demo sequence. Exposed so LumaDemoOrchestrator
/// can use the shared NativeTTSClient without duplicating TTS setup.
func speakDemoText(_ text: String) {
    nativeTTSClient.speak(text)
}
```

- [ ] **Step 3: Create `Luma/OnboardingDemoStep.swift`**

```swift
//
//  OnboardingDemoStep.swift
//  Luma
//
//  Wizard step 5: the interactive demo. Shown only after all permissions are granted.
//  LumaDemoOrchestrator drives the narration sequence. The user can give a
//  real voice or text command to complete the demo.
//

import SwiftUI

@MainActor
struct OnboardingDemoStep: View {

    @ObservedObject var companionManager: CompanionManager
    var onDemoComplete: () -> Void

    @StateObject private var orchestrator = LumaDemoOrchestrator()
    @State private var userTextInput: String = ""
    @State private var hasSubmitted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Text("Meet Luma")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color(hex: "#ECEEED"))
                Text("Watch what Luma can see, then try a command.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#9BA39D"))
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 24)

            // Status area: what Luma is saying
            if !orchestrator.spokenText.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color(hex: "#2563EB"))
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    Text(orchestrator.spokenText)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#ECEEED"))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
            }

            Spacer()

            // User input — only shown once orchestrator reaches .inviting phase
            if case .inviting = orchestrator.phase {
                VStack(spacing: 10) {
                    Text("Try giving me a command")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#555D58"))

                    HStack(spacing: 10) {
                        TextField("Type a command…", text: $userTextInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "#ECEEED"))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(hex: "#1A1C1A"))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color(hex: "#2E322E"), lineWidth: 1)
                                    )
                            )
                            .onSubmit { submitDemoCommand() }

                        Button(action: submitDemoCommand) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Color(hex: "#141614"))
                                .frame(width: 30, height: 30)
                                .background(Color.white)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(userTextInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .onHover { isHovering in
                            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }

                    Text("Or hold \(Image(systemName: "control")) \(Image(systemName: "option")) and speak")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#555D58"))
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 28)
            }

            if case .complete = orchestrator.phase {
                VStack(spacing: 12) {
                    Text("You're all set! ✓")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: "#34D399"))

                    Button(action: onDemoComplete) {
                        Text("Finish setup →")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(hex: "#ECEEED"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(hex: "#2563EB"))
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            orchestrator.start(companionManager: companionManager)
        }
        .onDisappear {
            orchestrator.cancel()
        }
    }

    private func submitDemoCommand() {
        let command = userTextInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !hasSubmitted else { return }
        hasSubmitted = true
        orchestrator.phase = .executing
        // Route through the normal classifier pipeline
        Task { @MainActor in
            await companionManager.classifyAndRouteInput(command)
            orchestrator.phase = .complete
        }
    }
}
```

- [ ] **Step 4: Make `classifyAndRouteInput` public (if not already) and mark it correctly**

`classifyAndRouteInput` is called from `OnboardingDemoStep`. Check its access modifier in `CompanionManager.swift`. If it is `private`, change to `internal` (no explicit modifier needed in Swift):
```swift
// Before: private func classifyAndRouteInput(_ transcript: String) async {
// After:
func classifyAndRouteInput(_ transcript: String) async {
```

- [ ] **Step 5: Build and verify**

Build (Cmd+B). Step through onboarding to step 5 (Demo).
- Luma should begin scanning and narrating within 1–2 seconds.
- The cursor overlay should point at UI elements on screen.
- After narration: a text field appears prompting for a command.
- Type a command (e.g. "open Calculator") and press Enter → Luma executes it.
- Demo phase transitions to `.complete` → "Finish setup" button appears.

- [ ] **Step 6: Commit**
```bash
git add Luma/LumaDemoOrchestrator.swift Luma/OnboardingDemoStep.swift Luma/CompanionManager.swift
git commit -m "feat: dynamic post-permission demo — AX scan, narrate, point, execute real command"
```

---

## Task 9: Floating Type-to-Luma Input (⌘⌘ or ^^)

**Files:**
- Create: `Luma/LumaDoubleTapModifierDetector.swift`
- Create: `Luma/LumaFloatingInputWindowManager.swift`
- Create: `Luma/LumaFloatingInputView.swift`
- Modify: `Luma/CompanionManager.swift` (start the detector, handle input from bubble)

### Part A: Double-tap modifier detector

- [ ] **Step 1: Create `Luma/LumaDoubleTapModifierDetector.swift`**

```swift
//
//  LumaDoubleTapModifierDetector.swift
//  Luma
//
//  Detects double-tap of the Command (⌘) or Control (^) key within a 300ms
//  window. Uses an NSEvent global monitor watching .flagsChanged events — the
//  same strategy as GlobalPushToTalkShortcutMonitor's idle sentinel, so energy
//  cost is limited to modifier key events only.
//
//  When a double-tap is detected, posts Notification.Name.lumaFloatingInputTriggered.
//  CompanionManager observes this and delegates to LumaFloatingInputWindowManager.
//

import AppKit
import Foundation

extension Notification.Name {
    /// Posted when the user double-taps ⌘ or ^ within 300ms.
    static let lumaFloatingInputTriggered = Notification.Name("lumaFloatingInputTriggered")
}

final class LumaDoubleTapModifierDetector {

    static let shared = LumaDoubleTapModifierDetector()

    /// Maximum time between two taps that counts as a double-tap.
    private let doubleTapWindow: TimeInterval = 0.3

    private var lastCommandTapDate: Date?
    private var lastControlTapDate: Date?

    /// True while Command is currently held down (prevents counting a long press as two taps).
    private var isCommandCurrentlyDown: Bool = false
    /// True while Control is currently held down.
    private var isControlCurrentlyDown: Bool = false

    private var flagsChangedMonitor: Any?

    private init() {}

    func start() {
        guard flagsChangedMonitor == nil else { return }
        flagsChangedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        LumaLogger.log("[DoubleTapDetector] Started — watching for ⌘⌘ and ^^")
    }

    func stop() {
        if let monitor = flagsChangedMonitor {
            NSEvent.removeMonitor(monitor)
            flagsChangedMonitor = nil
        }
    }

    // MARK: - Event Handling

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags

        // --- Command key ---
        let isCommandNowDown = flags.contains(.command)
        if isCommandNowDown && !isCommandCurrentlyDown {
            // Command key just pressed
            isCommandCurrentlyDown = true
            checkDoubleTap(lastTapDate: &lastCommandTapDate)
        } else if !isCommandNowDown && isCommandCurrentlyDown {
            // Command key released — no action needed for double-tap detection
            isCommandCurrentlyDown = false
        }

        // --- Control key ---
        let isControlNowDown = flags.contains(.control)
        if isControlNowDown && !isControlCurrentlyDown {
            // Control key just pressed
            isControlCurrentlyDown = true
            checkDoubleTap(lastTapDate: &lastControlTapDate)
        } else if !isControlNowDown && isControlCurrentlyDown {
            isControlCurrentlyDown = false
        }
    }

    /// Checks whether the current tap is within `doubleTapWindow` of the previous one.
    /// If yes, fires the floating input trigger. Updates `lastTapDate` on every call.
    private func checkDoubleTap(lastTapDate: inout Date?) {
        let now = Date()
        if let last = lastTapDate, now.timeIntervalSince(last) <= doubleTapWindow {
            // Double-tap detected
            lastTapDate = nil // Reset so a third tap doesn't count as another double
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .lumaFloatingInputTriggered, object: nil)
                LumaLogger.log("[DoubleTapDetector] Double-tap detected — posting lumaFloatingInputTriggered")
            }
        } else {
            lastTapDate = now
        }
    }
}
```

### Part B: Floating input view

- [ ] **Step 2: Create `Luma/LumaFloatingInputView.swift`**

```swift
//
//  LumaFloatingInputView.swift
//  Luma
//
//  The pill-shaped text input shown in the floating input bubble.
//  Shape: top-left corner is 0pt radius, all other corners are 999pt (fully rounded).
//  This anchors the bubble visually to the orb above it.
//

import SwiftUI

struct LumaFloatingInputView: View {

    @Binding var draft: String
    /// Called when the user presses Enter or taps the send button.
    var onSend: (String) -> Void
    /// Whether the field is currently focused (controlled externally by the window manager).
    @FocusState.Binding var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            TextField("Ask Luma anything…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .focused($isFieldFocused)
                .tint(.white) // white text cursor
                .onSubmit {
                    sendDraft()
                }

            if !draft.isEmpty {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(hex: "#141614"))
                        .frame(width: 28, height: 28)
                        .background(Color.white)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            // Top-left corner is square (0pt), all others fully rounded (999pt).
            // UnevenRoundedRectangle requires macOS 13+; Luma targets macOS 14.2+ so this is safe.
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 999,
                bottomTrailingRadius: 999,
                topTrailingRadius: 999,
                style: .continuous
            )
            .fill(Color(hex: "#141614"))
            .shadow(color: Color(hex: "#4caf50").opacity(0.08), radius: 16, x: 0, y: 0)
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 999,
                    bottomTrailingRadius: 999,
                    topTrailingRadius: 999,
                    style: .continuous
                )
                .stroke(LumaTheme.Colors.accent.opacity(0.25), lineWidth: 1)
            )
        )
        .preferredColorScheme(.dark)
    }

    private func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
    }
}
```

### Part C: Floating input window manager

- [ ] **Step 3: Create `Luma/LumaFloatingInputWindowManager.swift`**

```swift
//
//  LumaFloatingInputWindowManager.swift
//  Luma
//
//  Manages the floating pill-shaped text input bubble.
//
//  Lifecycle:
//  - `showOrRefocus()` — spawns the panel at the current cursor position and
//    makes it key (autofocused). If already visible, just refocuses.
//  - The panel follows the mouse at 25Hz with spring lerp (factor 0.12/tick).
//  - Following pauses when the text field is focused AND draft.count >= 1
//    so the window doesn't drift under the user's hands while typing.
//  - Click outside → unfocuses (resign first responder), window stays visible.
//  - Re-trigger → refocuses, resumes following.
//  - Send → morphs to orb state, sends text, clears draft.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class LumaFloatingInputWindowManager: NSObject {

    static let shared = LumaFloatingInputWindowManager()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var followTimer: DispatchSourceTimer?

    /// The current draft text. Persists between show/hide cycles.
    private var draft: String = ""

    /// Whether the text field is currently focused (reported back by the SwiftUI view).
    private var isFieldFocused: Bool = false

    /// Callback to send text through the intent pipeline. Set by CompanionManager.
    var onSendText: ((String) -> Void)?

    private override init() {}

    // MARK: - Public API

    /// Shows the floating input bubble at the current cursor position,
    /// or refocuses it if already visible.
    func showOrRefocus() {
        if let panel, panel.isVisible {
            // Already visible — just refocus the text field
            panel.makeKeyAndOrderFront(nil)
            focusTextField()
            startMouseFollowing()
            return
        }

        createAndShowPanel()
    }

    func hide() {
        stopMouseFollowing()
        panel?.orderOut(nil)
    }

    // MARK: - Panel Creation

    private func createAndShowPanel() {
        // Build the SwiftUI view with bindings to our local state
        let draftBinding = Binding<String>(
            get: { [weak self] in self?.draft ?? "" },
            set: { [weak self] newValue in self?.draft = newValue }
        )
        let focusedBinding = Binding<Bool>(
            get: { [weak self] in self?.isFieldFocused ?? false },
            set: { [weak self] newValue in self?.isFieldFocused = newValue }
        )

        let content = LumaFloatingInputView(
            draft: draftBinding,
            onSend: { [weak self] text in
                self?.handleSend(text: text)
            },
            isFieldFocused: focusedBinding
        )

        let hostingView = NSHostingView(rootView: AnyView(content))
        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 48)

        let floatingPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        floatingPanel.isFloatingPanel = true
        floatingPanel.level = .floating
        floatingPanel.isOpaque = false
        floatingPanel.backgroundColor = .clear
        floatingPanel.hasShadow = false // shadow is drawn by the SwiftUI view
        floatingPanel.hidesOnDeactivate = false
        floatingPanel.isExcludedFromWindowsMenu = true
        floatingPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        floatingPanel.contentView = hostingView

        // Position at current cursor location, offset slightly so the top-left corner
        // appears to sit just below the cursor (anchoring the sharp corner).
        let cursorPosition = NSEvent.mouseLocation
        let panelOrigin = NSPoint(
            x: cursorPosition.x,
            y: cursorPosition.y - CGFloat(hostingView.frame.height) - 8
        )
        floatingPanel.setFrameOrigin(panelOrigin)
        floatingPanel.makeKeyAndOrderFront(nil)

        self.panel = floatingPanel
        focusTextField()
        startMouseFollowing()
    }

    // MARK: - Mouse Following

    /// 25 Hz timer that lerps the panel origin toward the current cursor position.
    /// Spring factor 0.12 gives a weightless, slightly-lagging feel.
    /// Pauses when the text field is focused and draft has content (user is typing).
    private func startMouseFollowing() {
        stopMouseFollowing()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 25.0)
        timer.setEventHandler { [weak self] in
            self?.tickMouseFollow()
        }
        timer.resume()
        followTimer = timer
    }

    private func stopMouseFollowing() {
        followTimer?.cancel()
        followTimer = nil
    }

    private func tickMouseFollow() {
        guard let panel, panel.isVisible else {
            stopMouseFollowing()
            return
        }

        // Pause following while user is actively typing (field focused + has content)
        if isFieldFocused && !draft.isEmpty { return }

        let cursorPosition = NSEvent.mouseLocation
        let targetOrigin = NSPoint(
            x: cursorPosition.x,
            y: cursorPosition.y - panel.frame.height - 8
        )

        let currentOrigin = panel.frame.origin
        let springFactor: CGFloat = 0.12

        let newX = currentOrigin.x + (targetOrigin.x - currentOrigin.x) * springFactor
        let newY = currentOrigin.y + (targetOrigin.y - currentOrigin.y) * springFactor

        panel.setFrameOrigin(NSPoint(x: newX, y: newY))
    }

    // MARK: - Text Field Focus

    private func focusTextField() {
        // Make the panel's hosting view the first responder so the text field receives focus
        panel?.makeFirstResponder(panel?.contentView)
    }

    // MARK: - Send

    private func handleSend(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        LumaLogger.log("[FloatingInput] Sending: \(text.prefix(60))")
        draft = "" // Clear draft on successful send
        hide()
        onSendText?(text)
    }
}
```

- [ ] **Step 4: Wire `LumaDoubleTapModifierDetector` and `LumaFloatingInputWindowManager` into `CompanionManager.start()`**

In `CompanionManager.start()`, after `startPermissionPolling()`, add:
```swift
// Start double-tap modifier detector for floating input bubble (⌘⌘ or ^^)
LumaDoubleTapModifierDetector.shared.start()

// Wire the floating input bubble's send action to the classifier pipeline
LumaFloatingInputWindowManager.shared.onSendText = { [weak self] text in
    guard let self else { return }
    Task { @MainActor [weak self] in
        guard let self else { return }
        // Sending text from the floating bubble resets the idle timer
        self.idleTimer.reset()
        await self.classifyAndRouteInput(text)
    }
}

// Show or refocus the floating bubble when the double-tap fires
NotificationCenter.default.addObserver(
    forName: .lumaFloatingInputTriggered,
    object: nil,
    queue: .main
) { [weak self] _ in
    Task { @MainActor [weak self] in
        guard let self else { return }
        // If Luma is hidden, unhide first
        if !self.isOverlayVisible {
            self.overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            self.isOverlayVisible = true
            self.idleTimer.start()
        }
        // Reset idle timer — triggering the bubble counts as an interaction
        self.idleTimer.reset()
        LumaFloatingInputWindowManager.shared.showOrRefocus()
        LumaLogger.log("[FloatingInput] Triggered by double-tap modifier")
    }
}
```

In `CompanionManager.stop()`, add:
```swift
LumaDoubleTapModifierDetector.shared.stop()
```

- [ ] **Step 5: Build and verify**

Build (Cmd+B). Run the app.
- Press ⌘ twice rapidly (within 300ms) → floating pill input bubble appears at cursor position.
- Type text → window follows mouse with spring lag. Typing pauses following.
- Press Enter → bubble disappears, text routes through classifier (Luma responds).
- Click outside → bubble stays visible but unfocuses. Text preserved.
- Double-tap ⌘ again → bubble refocuses with existing text.
- Draft clears after successful send.
- Press ^^ (double-tap Control) → same behavior as ⌘⌘.
- Top-left corner of bubble should be square; all other corners fully rounded.

- [ ] **Step 6: Commit**
```bash
git add Luma/LumaDoubleTapModifierDetector.swift \
        Luma/LumaFloatingInputWindowManager.swift \
        Luma/LumaFloatingInputView.swift \
        Luma/CompanionManager.swift
git commit -m "feat: floating type-to-Luma input bubble triggered by ⌘⌘ or ^^"
```

---

## Self-Review Against Spec

### Spec coverage check

| Spec requirement | Task | ✓ |
|---|---|---|
| Menu bar click bug | Task 1 | ✓ |
| No agents on boot | Task 2 | ✓ |
| Remove agent hotkeys | Task 3 | ✓ |
| Screen recording without restart | Task 4 | ✓ |
| Auto-hide 30s inactivity | Task 5 | ✓ |
| Intent-based agent spawning — simple → overlay only | Task 6 | ✓ |
| Intent-based agent spawning — task → transient agent | Task 6 | ✓ |
| Intent-based agent spawning — "new agent" → persistent | Task 6 | ✓ |
| AgentSession.isTransient flag | Task 6 | ✓ |
| Onboarding permissions gate (all 3 permissions) | Task 7 | ✓ |
| "Give" button per permission → opens System Settings | Task 7 | ✓ |
| Drag popup with real NSItemProvider drag source | Task 7 | ✓ |
| Auto-dismiss drag popup on permission grant | Task 7 | ✓ |
| Live permission status polling (1.5s interval via existing poller) | Task 7 | ✓ |
| Interactive demo — dynamic AX scan | Task 8 | ✓ |
| Demo — narrate + cursor pointing | Task 8 | ✓ |
| Demo — invite + execute real command | Task 8 | ✓ |
| Demo never shown if permission missing | Task 8 (step 5 wiring) | ✓ |
| Auto-hide timer suspended during onboarding | Task 5 | ✓ |
| Floating input ⌘⌘/^^ trigger | Task 9 | ✓ |
| Bubble spawns at cursor, autofocused | Task 9 | ✓ |
| Spring-lag mouse following | Task 9 | ✓ |
| Following pauses during typing | Task 9 | ✓ |
| Click outside → unfocus, text persists | Task 9 | ✓ |
| Retrigger → refocus | Task 9 | ✓ |
| Send → clear draft, route to classifier | Task 9 | ✓ |
| Top-left 0px radius, others fully rounded | Task 9 | ✓ |

### Type consistency check

- `LumaIdleTimer.reset()` / `start()` / `stop()` / `suspend()` / `resume()` / `isSuspended` — used consistently across Tasks 5, 6, 7.
- `LumaRequiredPermission` enum defined in `LumaPermissionDragPopup.swift` — used in `OnboardingPermissionsStep.swift` and `CompanionManager.swift`. All three files must be in the same target.
- `AgentSession.isTransient` — defined in Task 6 Step 1, used in Task 6 Steps 3–5.
- `CompanionManager.speakDemoText(_:)` — defined in Task 8 Step 2, called by `LumaDemoOrchestrator`.
- `CompanionManager.classifyAndRouteInput(_:)` — made `internal` in Task 8 Step 4, called from `OnboardingDemoStep` and `LumaFloatingInputWindowManager`.
- `LumaFloatingInputView.isFieldFocused` uses `@FocusState.Binding` — the binding is provided by `LumaFloatingInputWindowManager` via a `Binding<Bool>`. Note: `@FocusState.Binding` is the correct type for a passed-in focus binding in SwiftUI on macOS 14+.

### Potential issue: `LumaIdleTimer.isSuspended` storage with `Binding<Bool>`

`LumaFloatingInputWindowManager` creates `Binding<Bool>` closures that capture `self` weakly. Ensure the bindings use `[weak self]` to avoid retain cycles — the code in Task 9 Step 3 does this correctly.

### Potential issue: `FocusState.Binding` in `LumaFloatingInputView`

`@FocusState.Binding var isFieldFocused: Bool` is the correct declaration when receiving a focus binding from a parent. The parent (`LumaFloatingInputWindowManager`) passes a regular `Binding<Bool>` as the `isFieldFocused` argument. On macOS 14 this works. Verify during build — if the compiler rejects it, use `@Binding var isFieldFocused: Bool` and handle the focus state with `.focused($isFieldFocused)` using a local `@FocusState` bridged from the binding.
