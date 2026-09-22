//
//  LumaWorkspaceWindowManager.swift
//  Luma
//
//  Owns the normal workspace window used for persistent agent conversations.
//  The menu-bar panel remains the lightweight entry point; this window provides
//  the full-screen workflow for longer tasks and transcript review.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let lumaOpenWorkspace = Notification.Name("com.luma.openWorkspace")
}

@MainActor
final class LumaWorkspaceWindowManager: NSObject {
    static let shared = LumaWorkspaceWindowManager()

    private var workspaceWindow: NSWindow?
    private var hostingController: NSHostingController<LumaWorkspaceView>?

    private override init() {
        super.init()
    }

    func show(companionManager: CompanionManager) {
        // The workspace becomes the primary interaction surface, so dismiss the
        // compact menu-bar panel before activating the normal app window.
        NotificationCenter.default.post(name: .lumaDismissPanel, object: nil)

        if let workspaceWindow {
            NSApp.setActivationPolicy(.regular)
            workspaceWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = LumaWorkspaceView(
            companionManager: companionManager,
            onClose: { [weak self] in
                self?.hide()
            }
        )
        let controller = NSHostingController(rootView: contentView)
        hostingController = controller

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Luma Workspace"
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.minSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()

        workspaceWindow = window
        window.delegate = self
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        workspaceWindow?.orderOut(nil)
        restoreActivationPolicy()
    }

    func toggle(companionManager: CompanionManager) {
        if let workspaceWindow, workspaceWindow.isVisible {
            hide()
        } else {
            show(companionManager: companionManager)
        }
    }
}

extension LumaWorkspaceWindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        workspaceWindow?.orderOut(nil)
        restoreActivationPolicy()
    }

    private func restoreActivationPolicy() {
        let shouldShowInDock = UserDefaults.standard.bool(forKey: "luma_show_in_dock")
        NSApp.setActivationPolicy(shouldShowInDock ? .regular : .accessory)
    }
}
