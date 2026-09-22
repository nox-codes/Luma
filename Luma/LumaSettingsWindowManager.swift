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
    private var settingsHostingView: NSHostingView<AnyView>?
    private var settingsWindowCloseObserver: NSObjectProtocol?
    private let windowSize = NSSize(width: 980, height: 680)
    private let minimumWindowSize = NSSize(width: 900, height: 620)

    private init() {}

    func showSettingsWindow(companionManager: CompanionManager) {
        // Dismiss the menu bar panel so it's not visible behind the settings window
        NotificationCenter.default.post(name: .lumaDismissPanel, object: nil)

        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow(companionManager: companionManager)
        } else if let hostingView = settingsHostingView {
            hostingView.rootView = AnyView(
                SettingsPanelView(companionManager: companionManager)
                    .preferredColorScheme(.dark)
                    .shadow(color: .black.opacity(0.60), radius: 36, y: 14)
            )
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
        if let settingsWindowCloseObserver {
            NotificationCenter.default.removeObserver(settingsWindowCloseObserver)
        }

        settingsWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: settingsWindow,
            queue: .main
        ) { [weak self] _ in
            // Hop back to the main actor to touch @MainActor-isolated state.
            Task { @MainActor [weak self] in
                self?.restoreActivationPolicy()
            }
        }
    }

    func hideSettingsWindow() {
        settingsWindow?.orderOut(nil)
        restoreActivationPolicy()
    }

    private func restoreActivationPolicy() {
        let shouldShowInDock = UserDefaults.standard.bool(forKey: "luma_show_in_dock")
        NSApp.setActivationPolicy(shouldShowInDock ? .regular : .accessory)
    }

    private func makeSettingsWindow(companionManager: CompanionManager) -> NSWindow {
        let settingsWindow = KeyAcceptingWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            // Keep the native titlebar and traffic lights so settings feels like a
            // normal macOS surface while the SwiftUI body owns the app navigation.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "Luma Settings"
        settingsWindow.titleVisibility = .hidden
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.minSize = minimumWindowSize
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.collectionBehavior.insert(.moveToActiveSpace)
        settingsWindow.center()
        // Transparent so the SwiftUI body supplies the dark surface below the titlebar.
        settingsWindow.isOpaque = false
        settingsWindow.backgroundColor = .clear
        settingsWindow.hasShadow = true
        let hostingView = NSHostingView<AnyView>(
            rootView: AnyView(
                SettingsPanelView(companionManager: companionManager)
                .preferredColorScheme(.dark)
                .shadow(color: .black.opacity(0.60), radius: 36, y: 14)
            )
        )
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]

        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = true
        hostingView.layer?.backgroundColor = CGColor.clear

        settingsHostingView = hostingView
        settingsWindow.contentView = hostingView
        return settingsWindow
    }
}
