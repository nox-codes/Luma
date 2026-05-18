//
//  LumaSettingsWindowManager.swift
//  leanring-buddy
//
//  Dedicated centered settings window manager.
//

import AppKit
import SwiftUI

// MARK: - KeyAcceptingWindow

/// NSWindow subclass that accepts key and main status even with a .borderless styleMask.
/// A plain borderless NSWindow always returns false for canBecomeKey/canBecomeMain, which
/// means button clicks and text-field focus never work. Overriding these fixes that.
private final class KeyAcceptingWindow: NSWindow {
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - LumaSettingsWindowManager

@MainActor
final class LumaSettingsWindowManager {

    static let shared = LumaSettingsWindowManager()

    private var settingsWindow: NSWindow?
    private let windowSize = NSSize(width: 860, height: 580)
    private let minimumWindowSize = NSSize(width: 760, height: 500)

    private init() {}

    func showSettingsWindow() {
        // Dismiss the menu bar panel so it's not visible behind the settings window
        NotificationCenter.default.post(name: .lumaDismissPanel, object: nil)

        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        } else if let hostingView = settingsWindow?.contentView as? NSHostingView<SettingsPanelView> {
            hostingView.rootView = SettingsPanelView()
        }

        guard let settingsWindow else { return }

        // Switch to regular app so settings appears in the Dock and Cmd+Tab switcher.
        // This makes settings feel like a real app window rather than a hidden-icon utility.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.center()
        settingsWindow.orderFrontRegardless()
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.makeMain()

        // Return to accessory (menu-bar-only) mode when the settings window closes.
        // We observe windowWillClose so the dock icon disappears as soon as the user
        // dismisses the window — before the next event loop tick.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: settingsWindow,
            queue: .main
        ) { _ in
            // Hop back to the main actor to touch @MainActor-isolated state.
            Task { @MainActor in
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func hideSettingsWindow() {
        settingsWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeSettingsWindow() -> NSWindow {
        let settingsWindow = KeyAcceptingWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            // Borderless: no macOS titlebar — we draw our own close button inside SwiftUI.
            // KeyAcceptingWindow overrides canBecomeKey/canBecomeMain so all interactive
            // elements (buttons, text fields, pickers) receive mouse and keyboard events.
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "Luma"
        settingsWindow.minSize = minimumWindowSize
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.collectionBehavior.insert(.moveToActiveSpace)
        settingsWindow.center()
        // Transparent so the rounded SwiftUI view clips cleanly without a square background.
        settingsWindow.isOpaque = false
        settingsWindow.backgroundColor = .clear
        settingsWindow.hasShadow = true
        // Borderless windows are not key by default — override so TextField focus works.
        settingsWindow.isMovableByWindowBackground = true

        let hostingView = NSHostingView(
            rootView: SettingsPanelView()
                .preferredColorScheme(.dark)
                // SwiftUI-level clip so all subviews respect the rounded shape.
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.60), radius: 36, y: 14)
        )
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]

        // AppKit-level layer clip — removes the 1px OS-rendered border that appears
        // around the NSHostingView even when the window background is clear.
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 20
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        hostingView.layer?.backgroundColor = CGColor.clear

        settingsWindow.contentView = hostingView
        return settingsWindow
    }
}
