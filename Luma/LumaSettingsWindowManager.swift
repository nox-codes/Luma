//
//  LumaSettingsWindowManager.swift
//  leanring-buddy
//
//  Dedicated centered settings window manager.
//

import AppKit
import SwiftUI

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
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.center()
        settingsWindow.orderFrontRegardless()
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.makeMain()
    }

    func hideSettingsWindow() {
        settingsWindow?.orderOut(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let settingsWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "Luma Settings"
        settingsWindow.minSize = minimumWindowSize
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.toolbarStyle = .unified
        settingsWindow.collectionBehavior.insert(.moveToActiveSpace)
        settingsWindow.center()
        settingsWindow.backgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1.0)

        let hostingView = NSHostingView(
            rootView: SettingsPanelView()
                .preferredColorScheme(.dark)
        )
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]
        settingsWindow.contentView = hostingView
        return settingsWindow
    }
}
