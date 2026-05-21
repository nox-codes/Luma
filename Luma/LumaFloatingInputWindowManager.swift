//
//  LumaFloatingInputWindowManager.swift
//  Luma
//
//  Manages the floating pill-shaped text input bubble.
//
//  Lifecycle:
//  - showOrRefocus() — spawns the panel at the current cursor position and makes it key.
//    If already visible, just refocuses the text field.
//  - The panel follows the mouse at 25 Hz with spring lerp (factor 0.12/tick).
//  - Following pauses when the text field is focused AND draft.count >= 1.
//  - Click outside → field loses focus, following stops. Panel stays visible. Draft persists.
//  - Re-trigger (double-tap) → refocuses, resumes following, existing draft intact.
//  - Send → clears draft, hides panel, routes text through onSendText callback.
//

import AppKit
import SwiftUI

@MainActor
final class LumaFloatingInputWindowManager: NSObject {

    static let shared = LumaFloatingInputWindowManager()

    private var panel: NSPanel?
    private var followTimer: DispatchSourceTimer?

    /// Draft text persists between show/hide cycles so the user can pick up where they left off.
    private var draft: String = ""

    /// Whether the embedded text field is currently focused. Updated via onFocusChanged callback.
    private var isFieldFocused: Bool = false

    /// Callback to send text through the intent pipeline. Set by CompanionManager.
    var onSendText: ((String) -> Void)?

    private override init() {}

    // MARK: - Public API

    /// Shows the floating input bubble at the current cursor position,
    /// or refocuses it if already visible.
    func showOrRefocus() {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            // Focus is restored by making the hosting view first responder.
            // The SwiftUI @FocusState inside LumaFloatingInputView will pick it up.
            panel.makeFirstResponder(panel.contentView)
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
        let draftBinding = Binding<String>(
            get: { [weak self] in self?.draft ?? "" },
            set: { [weak self] newValue in self?.draft = newValue }
        )

        let content = LumaFloatingInputView(
            draft: draftBinding,
            onSend: { [weak self] text in self?.handleSend(text: text) },
            onFocusChanged: { [weak self] isFocused in self?.isFieldFocused = isFocused }
        )

        let hostingView = NSHostingView(rootView: content)
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
        floatingPanel.hasShadow = false // shadow drawn by SwiftUI
        floatingPanel.hidesOnDeactivate = false
        floatingPanel.isExcludedFromWindowsMenu = true
        floatingPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        floatingPanel.contentView = hostingView

        // Position at cursor. The top-left sharp corner sits just below the cursor,
        // visually anchoring the bubble to the cursor tip.
        let cursorPosition = NSEvent.mouseLocation
        let panelOrigin = NSPoint(
            x: cursorPosition.x,
            y: cursorPosition.y - CGFloat(hostingView.frame.height) - 8
        )
        floatingPanel.setFrameOrigin(panelOrigin)
        floatingPanel.makeKeyAndOrderFront(nil)
        floatingPanel.makeFirstResponder(hostingView)

        self.panel = floatingPanel
        startMouseFollowing()
    }

    // MARK: - Mouse Following

    /// 25 Hz timer that lerps the panel origin toward the current cursor position.
    /// Spring factor 0.12 gives a weightless, slightly-lagging feel.
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

        // Pause following while the user is actively typing
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

    // MARK: - Send

    private func handleSend(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        LumaLogger.log("[FloatingInput] Sending: \(text.prefix(60))")
        draft = "" // Clear draft on successful send
        hide()
        onSendText?(text)
    }
}
