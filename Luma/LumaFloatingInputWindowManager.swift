//
//  LumaFloatingInputWindowManager.swift
//  Luma
//
//  Manages the floating pill-shaped text input bubble.
//
//  Lifecycle:
//  - showOrRefocus() — spawns at cursor position, focuses the text field, stays put.
//    If already visible, re-focuses without recreating the panel.
//  - Panel is static and draggable. It does NOT follow the mouse automatically.
//    isMovableByWindowBackground = true lets the user drag from any non-interactive area.
//  - Click outside panel → dismissed. Draft AND response are preserved.
//  - ESC key → dismissed. Draft AND response are preserved.
//  - Re-trigger (double-tap) → re-focuses; draft and prior response are preserved.
//  - Send → does NOT hide the panel. Clears draft, starts response streaming.
//    The panel morphs open (spring animation) as the response streams in.
//  - The panel and the Luma cursor overlay coexist simultaneously.
//  - Style changes → panel resizes to match new FloatingInputStyle base dimensions.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class LumaFloatingInputWindowManager: NSObject {

    static let shared = LumaFloatingInputWindowManager()

    private var panel: KeyAcceptingFloatingPanel?

    /// Callback set by CompanionManager to route text through the intent pipeline.
    var onSendText: ((String) -> Void)?

    /// Whether the floating panel is currently on screen.
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    // Event monitors — stored so they can be removed on hide
    private var outsideClickMonitor: Any?
    private var escKeyMonitor: Any?

    // Combine subscriptions
    private var styleChangeCancellable: AnyCancellable?
    private var responseChangeCancellable: AnyCancellable?

    /// Height of the response area added below the input when a response is present.
    private let responseAreaHeight: CGFloat = 201 // 200pt scroll + 1pt divider

    private override init() {
        super.init()

        // Resize panel when style changes
        styleChangeCancellable = FloatingInputStyleManager.shared.$currentStyle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStyle in
                self?.updatePanelFrame(for: newStyle)
            }

        // Morph panel height as AI response streams in / clears
        responseChangeCancellable = FloatingPanelState.shared.$response
            .receive(on: DispatchQueue.main)
            .removeDuplicates { $0.isEmpty == $1.isEmpty } // only react to empty↔non-empty transitions
            .sink { [weak self] response in
                self?.morphPanelForResponse(response)
            }
    }

    // MARK: - Public API

    func showOrRefocus() {
        if let panel, panel.isVisible {
            focusTextField(in: panel)
            return
        }
        createAndShowPanel()
    }

    func hide() {
        removeEventMonitors()
        panel?.orderOut(nil)
        // Draft and response are intentionally NOT cleared — preserved for next open.
    }

    // MARK: - Panel Creation

    private func createAndShowPanel() {
        let currentStyle = FloatingInputStyleManager.shared.currentStyle
        let hasResponse = !FloatingPanelState.shared.response.isEmpty

        let content = LumaFloatingInputView(
            onSend: { [weak self] text in self?.handleSend(text: text) }
        )

        let panelWidth = currentStyle.panelWidth
        let panelHeight = currentStyle.panelHeight + (hasResponse ? responseAreaHeight : 0)

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let floatingPanel = KeyAcceptingFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            // .nonactivatingPanel intentionally omitted — it silently blocks the OS from
            // granting the panel key-window status, so keyboard events never reach the
            // text field. We manage app activation explicitly with NSApp.activate.
            styleMask: [.borderless],
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
        // Allow dragging from any non-interactive background area (text field and buttons
        // are interactive controls and will NOT trigger dragging when clicked/typed in).
        floatingPanel.isMovableByWindowBackground = true
        floatingPanel.contentView = hostingView

        // Spawn just below the cursor so the input row is anchored near where it was triggered.
        let cursorPosition = NSEvent.mouseLocation
        let panelOrigin = NSPoint(
            x: cursorPosition.x,
            y: cursorPosition.y - panelHeight - 8
        )
        floatingPanel.setFrameOrigin(panelOrigin)

        NSApp.activate(ignoringOtherApps: true)
        floatingPanel.makeKeyAndOrderFront(nil)

        self.panel = floatingPanel
        installEventMonitors()
        focusTextField(in: floatingPanel)
    }

    // MARK: - Text Field Focus

    /// Activates the app and focuses the NSTextField directly via AppKit view hierarchy walk.
    /// @FocusState cannot reliably cross the NSHostingView boundary in a background
    /// LSUIElement process, so we bypass SwiftUI's focus system entirely.
    private func focusTextField(in targetPanel: NSPanel) {
        NSApp.activate(ignoringOtherApps: true)
        targetPanel.makeKeyAndOrderFront(nil)
        // Two run-loop cycles give SwiftUI time to build its view tree before we search.
        DispatchQueue.main.async {
            DispatchQueue.main.async { [weak targetPanel] in
                guard let targetPanel else { return }
                if let editableTextField = targetPanel.contentView?.firstEditableTextField() {
                    targetPanel.makeFirstResponder(editableTextField)
                }
            }
        }
    }

    // MARK: - Panel Morph (response expansion)

    /// Animates the panel height to accommodate (or remove) the 200pt response area.
    /// Keeps the top edge of the panel fixed so the input row stays near the cursor.
    private func morphPanelForResponse(_ response: String) {
        guard let panel, panel.isVisible else { return }
        let style = FloatingInputStyleManager.shared.currentStyle
        let baseHeight = style.panelHeight
        let targetHeight = response.isEmpty ? baseHeight : baseHeight + responseAreaHeight

        var frame = panel.frame
        guard abs(frame.height - targetHeight) > 1 else { return }

        let heightDelta = targetHeight - frame.height
        frame.size.height = targetHeight
        // Keep top edge fixed — grow the panel downward
        frame.origin.y -= heightDelta

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }

        // Keep hosting view frame in sync (not animated — SwiftUI handles internal layout)
        if let hostingView = panel.contentView {
            hostingView.frame = NSRect(x: 0, y: 0, width: frame.width, height: targetHeight)
        }
    }

    // MARK: - Panel Resize on Style Change

    private func updatePanelFrame(for style: FloatingInputStyle) {
        guard let panel, panel.isVisible else { return }
        let hasResponse = !FloatingPanelState.shared.response.isEmpty
        let newWidth = style.panelWidth
        let newHeight = style.panelHeight + (hasResponse ? responseAreaHeight : 0)

        var frame = panel.frame
        frame.size = CGSize(width: newWidth, height: newHeight)
        panel.setFrame(frame, display: true, animate: false)

        if let hostingView = panel.contentView {
            hostingView.frame = NSRect(x: 0, y: 0, width: newWidth, height: newHeight)
        }
    }

    // MARK: - Event Monitors

    private func installEventMonitors() {
        removeEventMonitors()

        // Dismiss on click outside panel bounds.
        // Draft and response are preserved — the user can re-open and continue.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let globalClickPoint = NSEvent.mouseLocation
            if !panel.frame.contains(globalClickPoint) {
                Task { @MainActor [weak self] in
                    self?.hide()
                }
            }
        }

        // Dismiss on Escape. Draft and response are preserved.
        escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
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

    /// Routes the submitted text to CompanionManager without hiding the panel.
    /// The panel stays visible and morphs open as the response streams in.
    private func handleSend(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        LumaLogger.log("[FloatingInput] Sending: \(trimmed.prefix(60))")

        // Clear draft immediately so the field looks ready for a follow-up
        FloatingPanelState.shared.draft = ""

        // Clear previous response and signal streaming start before routing,
        // so the panel starts streaming the new response right away
        FloatingPanelState.shared.beginNewResponse()

        // Route text through CompanionManager's intent pipeline.
        // Panel stays visible — the response streams into FloatingPanelState.shared.response.
        onSendText?(trimmed)
    }
}

// MARK: - Key-accepting panel subclass

/// NSPanel subclass that always reports itself as eligible to become the key window.
/// Borderless NSPanel on some macOS versions silently returns false for canBecomeKey,
/// which means makeKeyAndOrderFront succeeds visually but keyboard events never arrive.
private final class KeyAcceptingFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - NSView hierarchy helper

private extension NSView {
    /// Recursively searches the view tree for the first editable, non-hidden NSTextField.
    /// Used to bypass @FocusState limitations when focusing a text field inside an
    /// NSHostingView from a background (LSUIElement) app context.
    func firstEditableTextField() -> NSTextField? {
        if let textField = self as? NSTextField, textField.isEditable, !textField.isHidden {
            return textField
        }
        for subview in subviews {
            if let found = subview.firstEditableTextField() {
                return found
            }
        }
        return nil
    }
}
