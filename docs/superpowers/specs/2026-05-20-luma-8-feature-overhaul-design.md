# Luma 8-Feature Overhaul — Design Spec
Date: 2026-05-20

## Overview

Eight changes spanning bug fixes, behavior removals, UX modifications, and two new features. Changes are independent enough to be implemented one at a time without breaking each other.

---

## 1. Menu Bar Icon Click Bug Fix

**Problem**: The menu bar panel appears then immediately collapses on first click. Root cause: `NSEvent.addGlobalMonitorForEvents` fires for status item clicks because the click event is routed through `SystemUIServer` (which owns the menu bar), making it visible as an "other app" event to the global monitor. The 0.3s dismiss timer fires after the open animation completes, collapsing the panel.

**Fix** (`MenuBarPanelManager.swift`, `installClickOutsideMonitor()`):
- After getting `clickLocation`, add a guard: if `statusItem?.button?.window?.frame.contains(clickLocation)` → `return`.
- This excludes the status item area from triggering the dismiss path.
- No timing hacks. No other changes.

---

## 2. No Agents on Boot

**Problem**: `CompanionManager.start()` restores or creates agent sessions on launch, causing bubbles to appear at startup.

**Fix** (`CompanionManager.swift`):
- Remove the block in `start()` that restores or creates agent sessions.
- `agentSessions` starts as an empty array on every launch.
- `agentDockWindowManager.show()` is never called during startup.
- Agent sessions are only ever created by the classifier or explicit user command (see Feature 3).

---

## 3. Intent-Based Agent Spawning + Remove Hotkeys

**Behavior**:

| Classifier result | Action |
|---|---|
| `response` | Overlay only, no agent spawned |
| `cli` | Spawn one transient agent, auto-dismiss on task completion |
| `visual_agent` | Spawn one transient agent, auto-dismiss on task completion |
| Voice input contains "Luma agent" or "new agent" | Spawn one persistent agent (not auto-dismissed) |

**Changes** (`CompanionManager.swift`):
- In `classifyAndRouteInput()`, update `cli` and `visual_agent` paths to spawn a single agent marked as transient (`isTransient = true`).
- Subscribe to `AgentSession.taskCompletedNotificationName` for transient agents; dismiss the session and hide the dock window when it fires.
- Detect "Luma agent" / "new agent" in the user's voice transcript before classification; if matched, spawn a persistent agent directly without running the classifier.
- Remove `AgentHotkeyHandler` initialization from `start()`.
- Remove or comment out Ctrl+Cmd+N, Ctrl+Option+Tab, Ctrl+Option+1-9 handlers in `AgentHotkeyHandler.swift`.

---

## 4. Screen Recording Permission Without Restart

**Problem**: If the user grants screen recording after launch, ScreenCaptureKit retains a denied state and screenshots fail until restart.

**Fix**:
- In `CompanionManager.refreshAllPermissions()`, track the previous value of `hasScreenRecordingPermission` via a stored property `previousScreenRecordingPermissionState`.
- When the value transitions `false → true`, post `Notification.Name.lumaScreenRecordingPermissionGranted`.
- `CompanionScreenCaptureUtility` (or `CompanionManager`) observes this notification and calls a new `reinitializeCapture()` method that creates a fresh `SCShareableContent` request, clearing any cached denied state.
- No app restart required.

---

## 5. Onboarding Permissions Flow

### Screen structure

A new step in `OnboardingWizardView` — the permissions gate. Cannot be skipped. "Continue" is only enabled when all three permissions are granted.

### Permission row layout

Each row shows:
- Icon + permission name + description
- Live status chip: "✓ Granted" (green) or "Required" (red), updated every 1 second via a `Timer` reading `CompanionManager`'s published permission state
- **"Give" button** — triggers the permission grant flow (see below)

### Permission grant flow (per permission)

1. User taps "Give" on a permission row.
2. `NSWorkspace.shared.open(URL)` deep-links to the correct System Settings pane:
   - Screen Recording: `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
   - Accessibility: `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
   - Microphone: `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`
3. Simultaneously, a `LumaPermissionDragPopup` window spawns and floats above System Settings:
   - Style: compact, dark, pill-shaped panel (like Claude's quick-input popup)
   - Contains: Luma `.app` icon (32×32pt) + label "Drag to give permission."
   - The icon is a real drag source via `NSItemProvider` providing Luma's `.app` bundle `URL` (identical to dragging from Finder).
   - Panel level: `.floating`, joins all spaces, non-activating.
4. User drags the icon from the popup into the System Settings privacy list. macOS accepts it natively.
5. `CompanionManager.refreshAllPermissions()` polling (1.5s interval) detects the permission flip.
6. On detection: post `Notification.Name.lumaPermissionGranted(permission:)` → popup dismisses itself → onboarding row updates to "✓ Granted".
7. Each permission has its own independent "Give" button and popup lifecycle.

### New files
- `LumaPermissionDragPopup.swift` — NSPanel + SwiftUI pill popup with drag source
- Updated `OnboardingWizardView.swift` — adds the permissions step with live polling

---

## 6. Interactive Demo (Dynamic)

Shown only after all three permissions are granted. Never shown with any permission missing.

### Demo sequence

1. **Transition**: Onboarding wizard auto-advances to demo step when `allPermissionsGranted` becomes true.
2. **Screen scan**: `LumaDemoOrchestrator` captures the screen and runs an AX tree scan to find 2–3 visible, named, interactive UI elements from the frontmost app. If AX finds fewer than 2 usable elements (no named interactive children, or frontmost app is the desktop), falls back to a generic narration: "I can see your screen — I can help you navigate, open apps, find files, and more."
3. **Narration + pointing**: Luma speaks about what it sees (via `ElevenLabsTTSClient`) and the blue cursor points to each element in sequence (via existing `CursorGuide.pointAtNotificationName`).
   - Example: "I can see Finder is open. I can see your sidebar, your Downloads folder, and the search bar."
4. **Invite**: After narration completes, Luma says "Try giving me a command" and the demo screen shows a text input + push-to-talk instruction.
5. **Execution**: The user's input (voice or text) goes through the normal `classifyAndRouteInput()` pipeline and executes for real.
6. **Completion**: After the command executes, Luma says "You're all set." The demo step marks complete, onboarding finishes, and the wizard closes.

### New files
- `LumaDemoOrchestrator.swift` — orchestrates the scan → narrate → invite → execute → complete sequence.

---

## 7. Auto-Hide After 30 Seconds of Inactivity

**Definition of "interaction"**: any voice command, text input sent, agent spawn, menu bar icon click, or floating input bubble activation.

### Behavior
- Timer starts when Luma becomes visible (overlay or panel shown).
- Any interaction resets the 30-second countdown.
- On timeout: hide the overlay window + dismiss the menu bar panel if open. Agent bubbles are hidden too. Menu bar icon remains visible at all times.
- Luma continues running in the background. All state is preserved.
- First interaction after timeout (menu bar click or hotkey) unhides Luma and resets the timer.
- **Timer is suspended during the onboarding wizard and demo sequence** — hiding mid-onboarding would break the flow. Timer activates only after `hasCompletedOnboarding` is true.

### Implementation
- New `LumaIdleTimer.swift`: wraps a `DispatchSourceTimer`, exposes `reset()`, `suspend()`, `resume()`, and an `onTimeout` closure.
- Owned by `CompanionManager`.
- `reset()` called from: `classifyAndRouteInput()`, `agentSessionSpawned`, `floatingInputActivated`.
- `MenuBarPanelManager.showPanel()` calls `companionManager.idleTimer.reset()` directly (no notification needed — `MenuBarPanelManager` already holds a `CompanionManager` reference).
- `onTimeout`: calls `overlayWindow.hide()` + posts `Notification.Name.lumaDismissPanel`.
- Timer only active while Luma is visible (starts on show, stops on hide).

---

## 8. Floating Type-to-Luma Input (⌘⌘ or ^^)

### Trigger
Double-tap of the Command key (⌘) or Control key (^) within a 300ms window. Detected via a `CGEventTap` monitoring `NSEventType.flagsChanged` events. If Luma is hidden when triggered, unhide first then spawn the bubble.

### Window
- `LumaFloatingInputWindowManager.swift`: owns a single `NSPanel` (borderless, non-activating, floating level).
- Spawns at the current `NSEvent.mouseLocation`.
- Immediately becomes key window (autofocused — user types without clicking).

### Shape
- Pill shape with one exception: top-left corner is 0pt radius, all other corners are 999pt (fully rounded).
- This anchors the bubble visually to the orb above it.

### Styling
- Background: `DS.Colors.cardSurface` (`#141614`)
- Border: accent color at 25% opacity
- Box shadow: `0 0 16px rgba(accent, 0.08)`
- Text cursor: white
- Placeholder: muted accent (`DS.Colors.textTertiary`)
- Send button: white filled circle, dark arrow icon

### Mouse follow
- 25 Hz `DispatchSourceTimer` lerps the window origin toward `NSEvent.mouseLocation`.
- Spring factor: 0.12 per tick (weightless feel, slight lag).
- Pauses following while the text field is first responder and the user has typed ≥ 1 character (so the window doesn't drift under the user's hands while typing).
- Resumes following when field is empty or unfocused.

### Focus / dismiss / persistence
- Click outside → field resigns first responder, mouse follow stops. Window stays visible. Text persists.
- Re-trigger hotkey → window refocuses and resumes following.
- Press Enter / tap send button → window morphs to orb state (scales down, rounds all corners, fades) → text sent to `LumaIntentClassifier` via `CompanionManager.classifyAndRouteInput()` → normal pipeline.
- Successful send → draft cleared.
- Auto-hide timer (Feature 7) is reset on bubble activation and on send.

### New files
- `LumaFloatingInputWindowManager.swift`
- `LumaFloatingInputView.swift`
- New `LumaDoubleTapModifierDetector.swift` — owns the `CGEventTap` for double-tap ⌘/^ detection, posts `Notification.Name.lumaFloatingInputTriggered`. Separate from `GlobalPushToTalkShortcutMonitor` (which handles hold-to-talk, a different interaction mode).

---

## Files Affected Summary

| File | Change type |
|---|---|
| `MenuBarPanelManager.swift` | Fix (click bug) |
| `CompanionManager.swift` | Fix + modify (no boot agents, intent routing, screen recording reinit, idle timer integration) |
| `AgentSession.swift` | Add `isTransient: Bool` property |
| `AgentHotkeyHandler.swift` | Remove hotkey registrations |
| `CompanionScreenCaptureUtility.swift` | Add `reinitializeCapture()` |
| `OnboardingWizardView.swift` | Add permissions step + demo step |
| `LumaPermissionDragPopup.swift` | **New** |
| `LumaDemoOrchestrator.swift` | **New** |
| `LumaIdleTimer.swift` | **New** |
| `LumaFloatingInputWindowManager.swift` | **New** |
| `LumaFloatingInputView.swift` | **New** |
| `LumaDoubleTapModifierDetector.swift` | **New** — double-tap ⌘/^ detection |

## Implementation Order

Implement in this order to avoid dependencies on unbuilt features:

1. Menu bar click bug (isolated fix, no dependencies)
2. No agents on boot (remove code, no dependencies)
3. Remove agent hotkeys (remove code, no dependencies)
4. Screen recording reinit (small addition to existing polling)
5. Auto-hide idle timer (new file + CompanionManager hooks)
6. Intent-based agent spawning (modifies classifier routing)
7. Onboarding permissions flow (new UI + LumaPermissionDragPopup)
8. Interactive demo (depends on permissions step being complete)
9. Floating input bubble (independent new feature)
