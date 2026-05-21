//
//  LumaFloatingInputWindowManager.swift
//  Luma
//
//  Manages the floating pill-shaped text input bubble.
//
//  Lifecycle:
//  - showOrRefocus() — spawns at cursor position, makes panel key, auto-focuses field.
//    If already visible, refocuses without recreating the panel.
//  - Panel follows the mouse at 25 Hz with spring lerp (0.12 factor).
//  - Following pauses when the text field is focused AND draft is non-empty.
//  - Click outside panel → dismissed via global mouse-down monitor.
//  - ESC key → dismissed via local key-down monitor.
//  - Re-trigger (double-tap) → refocuses; draft is preserved.
//  - Send → clears draft, hides panel, routes text through onSendText callback.
//  - Style changes → panel resizes to match new FloatingInputStyle dimensions.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class LumaFloatingInputWindowManager: NSObject {

    static let shared = LumaFloatingInputWindowManager()

    private var panel: NSPanel?
    private var followTimer: DispatchSourceTimer?

    /// Draft text persists between show/hide cycles.
    private var draft: String = ""

    /// Whether the embedded text field is currently focused.
    private var isFieldFocused: Bool = false

    /// Callback set by CompanionManager to route text through the intent pipeline.
    var onSendText: ((String) -> Void)?

    // Event monitors — stored so they can be removed on hide/deinit
    private var outsideClickMonitor: Any?
    private var escKeyMonitor: Any?

    // Combine subscription to react to style changes
    private var styleChangeCancellable: AnyCancellable?

    private override init() {
        super.init()
        // Observe style changes and resize the live panel if it's visible
        styleChangeCancellable = FloatingInputStyleManager.shared.$currentStyle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStyle in
                self?.resizePanelIfVisible(to: newStyle)
            }
    }

    // MARK: - Public API

    func showOrRefocus() {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(panel.contentView)
            startMouseFollowing()
            return
        }
        createAndShowPanel()
    }

    func hide() {
        removeEventMonitors()
        stopMouseFollowing()
        panel?.orderOut(nil)
    }

    // MARK: - Panel Creation

    private func createAndShowPanel() {
        let currentStyle = FloatingInputStyleManager.shared.currentStyle

        let draftBinding = Binding<String>(
            get: { [weak self] in self?.draft ?? "" },
            set: { [weak self] newValue in self?.draft = newValue }
        )

        let content = LumaFloatingInputView(
            draft: draftBinding,
            onSend: { [weak self] text in self?.handleSend(text: text) },
            onFocusChanged: { [weak self] isFocused in self?.isFieldFocused = isFocused }
        )

        let panelWidth = currentStyle.panelWidth
        let panelHeight = currentStyle.panelHeight

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let floatingPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        floatingPanel.isFloatingPanel = true
        floatingPanel.level = .floating
        floatingPanel.isOpaque = false
        floatingPanel.backgroundColor = .clear
        floatingPanel.hasShadow = false
        floatingPanel.hidesOnDeactivate = false
        floatingPanel.isExcludedFromWindowsMenu = true
        floatingPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        floatingPanel.contentView = hostingView

        // Position so top-left of panel sits just below the cursor
        let cursorPosition = NSEvent.mouseLocation
        let panelOrigin = NSPoint(
            x: cursorPosition.x,
            y: cursorPosition.y - panelHeight - 8
        )
        floatingPanel.setFrameOrigin(panelOrigin)
        // Activate the app so the panel can become key and @FocusState works.
        // Without this, a nonactivatingPanel shown from a background double-tap
        // won't receive key events, so the text field never accepts input.
        NSApp.activate(ignoringOtherApps: true)
        floatingPanel.makeKeyAndOrderFront(nil)
        floatingPanel.makeFirstResponder(hostingView)

        self.panel = floatingPanel
        startMouseFollowing()
        installEventMonitors()
    }

    // MARK: - Panel Resize on Style Change

    private func resizePanelIfVisible(to style: FloatingInputStyle) {
        guard let panel, panel.isVisible else { return }
        let newWidth = style.panelWidth
        let newHeight = style.panelHeight
        var frame = panel.frame
        frame.size = CGSize(width: newWidth, height: newHeight)
        panel.setFrame(frame, display: true, animate: false)
        if let hostingView = panel.contentView {
            hostingView.frame = NSRect(x: 0, y: 0, width: newWidth, height: newHeight)
        }
    }

    // MARK: - Mouse Following

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

    // MARK: - Event Monitors

    private func installEventMonitors() {
        removeEventMonitors()

        // Dismiss on click outside panel bounds
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            // Use global mouse location in screen coordinates
            let globalClickPoint = NSEvent.mouseLocation
            if !panel.frame.contains(globalClickPoint) {
                Task { @MainActor [weak self] in
                    self?.hide()
                }
            }
        }

        // Dismiss on Escape
        escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // keyCode 53 = Escape
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in
                    self?.hide()
                }
                return nil // consume the event
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        if let monitor = escKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escKeyMonitor = nil
        }
    }

    // MARK: - Send

    private func handleSend(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        LumaLogger.log("[FloatingInput] Sending: \(text.prefix(60))")
        draft = ""
        hide()
        onSendText?(text)
    }
}
