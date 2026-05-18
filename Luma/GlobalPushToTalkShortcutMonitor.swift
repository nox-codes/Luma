//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while Luma is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//
//  Energy optimisation — idle sentinel pattern:
//  The CGEvent tap is disabled at idle and re-enabled only when modifier keys
//  are active. An NSEvent global monitor (the "idle sentinel") watches for any
//  .flagsChanged event and wakes the CGEvent tap on demand. Once enabled, the
//  tap auto-returns to idle when all interactive modifier keys are released
//  (checked in the .none case after every event). This eliminates per-keystroke
//  CGEvent callback overhead when the user is not interacting with modifier keys,
//  which is the vast majority of idle time.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    /// Posted when the user presses Cmd+Shift+3/4/5 so the overlay can
    /// temporarily hide itself before the system grabs the screenshot.
    static let systemScreenshotShortcutDetectedNotificationName = NSNotification.Name("lumaSystemScreenshotShortcutDetected")

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?

    /// Lightweight idle sentinel: an NSEvent global monitor that fires only on
    /// .flagsChanged events (modifier key presses). Active when the CGEvent tap
    /// is disabled. When any modifier key is pressed, the sentinel enables the
    /// CGEvent tap for precise shortcut detection and removes itself. Because
    /// .flagsChanged is far less frequent than .keyDown/.keyUp, regular typing
    /// in other apps produces zero overhead while Luma is idle.
    ///
    /// Screenshot shortcut (Cmd+Shift+3/4/5) is still caught correctly: Cmd and
    /// Shift generate .flagsChanged events that wake the tap before the number
    /// key arrives, so the tap is always enabled by the time the .keyDown fires.
    private var idleSentinelEventMonitor: Any?

    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let createdEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // CGEvent.tapCreate fails when Accessibility permission is not granted.
            // The app needs to be in System Settings → Privacy → Accessibility.
            LumaLogger.log("⚠️ GlobalPTT: CGEvent tap creation FAILED — hotkey will not fire")
            LumaLogger.log("⚠️ GlobalPTT: AXIsProcessTrusted = \(AXIsProcessTrusted())")
            LumaLogger.log("⚠️ GlobalPTT: Grant Accessibility in System Settings → Privacy → Accessibility, then relaunch")
            return
        }

        guard let createdRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            createdEventTap,
            0
        ) else {
            CFMachPortInvalidate(createdEventTap)
            LumaLogger.log("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = createdEventTap
        self.globalEventTapRunLoopSource = createdRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), createdRunLoopSource, .commonModes)

        // Start the tap DISABLED — the idle sentinel will enable it on demand.
        // This eliminates per-keystroke CGEvent callback overhead at idle.
        CGEvent.tapEnable(tap: createdEventTap, enable: false)
        installIdleSentinel()
        LumaLogger.log("🎹 GlobalPTT: CGEvent tap registered — starting in idle (low-energy) mode")
    }

    func stop() {
        isShortcutCurrentlyPressed = false
        removeIdleSentinel()

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    // MARK: - Idle Sentinel

    /// Installs the idle sentinel: a lightweight NSEvent global monitor for .flagsChanged.
    /// When any modifier key is pressed, the sentinel wakes the CGEvent tap and removes itself.
    /// Only modifier key events fire the sentinel — regular typing produces zero overhead.
    private func installIdleSentinel() {
        guard idleSentinelEventMonitor == nil else { return }
        idleSentinelEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            self?.handleIdleSentinelFired()
        }
    }

    private func removeIdleSentinel() {
        guard let monitor = idleSentinelEventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        idleSentinelEventMonitor = nil
    }

    /// Called by the idle sentinel when any modifier key changes state.
    /// Enables the CGEvent tap so it can detect the full shortcut combination.
    /// The tap will auto-return to idle (disable + reinstall sentinel) once
    /// all interactive modifiers are released, via the .none case handler.
    private func handleIdleSentinelFired() {
        removeIdleSentinel()
        if let tap = globalEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    // MARK: - CGEvent Tap Callback

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            // System disabled the tap — re-enable it. If no shortcut is active and
            // modifiers are clear, the .none case below will return it to idle.
            if let tap = globalEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // Detect macOS system screenshot shortcuts (Cmd+Shift+3/4/5) so the overlay can
        // temporarily hide before the system captures the screen. Key codes: '3'=20, '4'=21, '5'=23.
        // We only fire on keyDown so there's one hide per key press, not one per repeat.
        // Note: Cmd and Shift generate .flagsChanged events that wake the sentinel before
        // the number key arrives, so the tap is always enabled by the time this .keyDown fires.
        let isScreenshotKeyCode = eventKeyCode == 20 || eventKeyCode == 21 || eventKeyCode == 23
        let hasCmdAndShift = event.flags.contains(.maskCommand) && event.flags.contains(.maskShift)
        if eventType == .keyDown && isScreenshotKeyCode && hasCmdAndShift {
            NotificationCenter.default.post(
                name: GlobalPushToTalkShortcutMonitor.systemScreenshotShortcutDetectedNotificationName,
                object: nil
            )
        }

        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            // When no shortcut is active and no interactive modifier keys are held,
            // disable the tap and reinstall the sentinel to eliminate idle energy cost.
            // Interactive modifiers are ctrl, option, cmd, shift, fn — caps lock is excluded
            // because it is a toggle, not a held key, and cannot trigger the PTT shortcut.
            if !isShortcutCurrentlyPressed {
                let activeInteractiveModifiers = event.flags.intersection([
                    .maskControl, .maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn
                ])
                if activeInteractiveModifiers.rawValue == 0 {
                    if let tap = globalEventTap {
                        CGEvent.tapEnable(tap: tap, enable: false)
                    }
                    installIdleSentinel()
                }
            }

        case .pressed:
            LumaLogger.log("[Luma] Hotkey triggered")
            LumaLogger.log("🎹 GlobalPTT: shortcut PRESSED — starting voice capture")
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)

        case .released:
            LumaLogger.log("🎹 GlobalPTT: shortcut RELEASED — finalizing transcript")
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
            // Return to idle: disable the tap and reinstall the sentinel.
            // The tap is no longer needed until the next modifier key is pressed.
            if let tap = globalEventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            installIdleSentinel()
        }

        return Unmanaged.passUnretained(event)
    }
}
