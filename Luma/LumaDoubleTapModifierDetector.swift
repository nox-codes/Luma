//
//  LumaDoubleTapModifierDetector.swift
//  Luma
//
//  Detects double-tap of the Command (⌘) or Control (^) key within a 300ms
//  window. Uses an NSEvent global monitor watching .flagsChanged events.
//
//  When a double-tap is detected, posts Notification.Name.lumaFloatingInputTriggered.
//

import AppKit
import Foundation

extension Notification.Name {
    /// Posted when the user double-taps ⌘ or ^ within 300ms.
    static let lumaFloatingInputTriggered = Notification.Name("lumaFloatingInputTriggered")
}

final class LumaDoubleTapModifierDetector {

    static let shared = LumaDoubleTapModifierDetector()

    private let doubleTapWindow: TimeInterval = 0.3

    private var lastCommandTapDate: Date?
    private var lastControlTapDate: Date?

    /// True while Command is currently held down — prevents a long press counting as two taps.
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

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags

        let isCommandNowDown = flags.contains(.command)
        if isCommandNowDown && !isCommandCurrentlyDown {
            isCommandCurrentlyDown = true
            checkDoubleTap(lastTapDate: &lastCommandTapDate)
        } else if !isCommandNowDown && isCommandCurrentlyDown {
            isCommandCurrentlyDown = false
        }

        let isControlNowDown = flags.contains(.control)
        if isControlNowDown && !isControlCurrentlyDown {
            isControlCurrentlyDown = true
            checkDoubleTap(lastTapDate: &lastControlTapDate)
        } else if !isControlNowDown && isControlCurrentlyDown {
            isControlCurrentlyDown = false
        }
    }

    /// Fires .lumaFloatingInputTriggered if this tap is within doubleTapWindow of the previous one.
    private func checkDoubleTap(lastTapDate: inout Date?) {
        let now = Date()
        if let last = lastTapDate, now.timeIntervalSince(last) <= doubleTapWindow {
            lastTapDate = nil // Reset so a third tap doesn't count as another double-tap
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .lumaFloatingInputTriggered, object: nil)
                LumaLogger.log("[DoubleTapDetector] Double-tap detected — posting lumaFloatingInputTriggered")
            }
        } else {
            lastTapDate = now
        }
    }
}
