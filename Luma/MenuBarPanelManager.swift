//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let lumaDismissPanel = Notification.Name("lumaDismissPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager

    /// The NSView that hosts the SwiftUI content. Stored so we can update its
    /// frame width when the agent response contains wide tables.
    private weak var contentHostingView: NSView?
    /// Holds the Combine subscription that re-subscribes to response card changes
    /// whenever the active agent session changes.
    private var sessionIDCancellable: AnyCancellable?
    /// Holds the Combine subscription on the current active session's response card.
    private var responseCardCancellable: AnyCancellable?

    struct PanelSizeKey: PreferenceKey {
        static var defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            value = nextValue()
        }
    }
    
    private func morphPanel(to newSize: CGSize) {
        guard let panel = panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        // Prevent redundant animations if the size hasn't actually changed
        guard panel.frame.size != newSize else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Calculate new origin to stay anchored below the menu bar icon
        let panelOriginX = statusItemFrame.midX - (newSize.width / 2)
        let panelOriginY = statusItemFrame.minY - newSize.height - gapBelowMenuBar

        let newFrame = NSRect(x: panelOriginX, y: panelOriginY, width: newSize.width, height: newSize.height)

        // If the panel isn't visible yet, just snap to the new size silently
        guard panel.isVisible else {
            panel.setFrame(newFrame, display: false)
            return
        }

        // Smooth morph animation if the panel is already open
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            // Re-using your nice springy timing function
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().setFrame(newFrame, display: true)
        }
    }

    /// Base (minimum) panel width. The panel grows wider when the agent response
    /// contains wide tables, then shrinks back when the response is cleared.
    private let panelBaseWidth: CGFloat = 356
    /// Maximum panel width — limits how wide the panel can grow for very wide tables.
    private let panelMaxWidth: CGFloat = 600
    /// Tall enough to accommodate the panel content before morphPanel takes over.
    private let panelHeight: CGFloat = 420

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()
        startObservingAgentResponse()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .lumaDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // hidePanel() is @MainActor-isolated; re-establish actor context explicitly
            // since NotificationCenter observer closures are nonisolated @Sendable.
            Task { @MainActor [weak self] in
                self?.hidePanel()
            }
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Adaptive panel width (agent response)

    /// Watches the active session ID and re-subscribes to its response card whenever
    /// it changes, so the panel always tracks the currently-visible agent's content.
    private func startObservingAgentResponse() {
        sessionIDCancellable = companionManager.$activeAgentSessionID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.subscribeToActiveSessionResponseCard()
            }
        // Subscribe immediately for the current session.
        subscribeToActiveSessionResponseCard()
    }

    /// Subscribes to `latestResponseCard` on the currently-active agent session.
    /// Called once at init and again each time the active session changes.
    private func subscribeToActiveSessionResponseCard() {
        responseCardCancellable = companionManager.activeAgentSession.$latestResponseCard
            .receive(on: DispatchQueue.main)
            .sink { [weak self] responseCard in
                self?.updateContentWidthForAgentResponse(responseCard?.rawText)
            }
    }

    /// Computes the ideal content width for `responseText` (widened for wide tables)
    /// and updates the hosting view frame so SwiftUI re-layouts at the new width.
    /// The PanelSizeKey preference fires after layout and morphPanel handles the resize.
    private func updateContentWidthForAgentResponse(_ responseText: String?) {
        let neededWidth: CGFloat
        if let text = responseText {
            neededWidth = requiredPanelWidthForResponseText(text)
        } else {
            neededWidth = panelBaseWidth
        }
        guard let hostingView = contentHostingView,
              abs(neededWidth - hostingView.frame.width) > 4 else { return }
        // Update the hosting view width — SwiftUI re-renders, PanelSizeKey fires,
        // morphPanel resizes the panel to match.
        hostingView.frame.size.width = neededWidth
    }

    /// Scans `responseText` for GFM pipe tables and returns the panel width needed
    /// to display the widest table without severe cell wrapping.
    /// Each column is allocated 75pt; result is clamped to [panelBaseWidth, panelMaxWidth].
    private func requiredPanelWidthForResponseText(_ responseText: String) -> CGFloat {
        let lines = responseText.components(separatedBy: "\n")
        var maximumColumnCount = 0
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.hasPrefix("|") && trimmedLine.hasSuffix("|") else { continue }
            let innerContent = trimmedLine.dropFirst().dropLast()
            let cells = innerContent.components(separatedBy: "|")
            let isSeparatorRow = cells.allSatisfy { cell in
                cell.trimmingCharacters(in: .init(charactersIn: "- :")).isEmpty
            }
            guard !isSeparatorRow else { continue }
            maximumColumnCount = max(maximumColumnCount, cells.count)
        }
        guard maximumColumnCount > 0 else { return panelBaseWidth }
        // 90pt per column matches RichMarkdownView's kTableColumnMinWidth; +28pt for panel padding
        let computedWidth = CGFloat(maximumColumnCount) * 90 + 28
        return min(max(computedWidth, panelBaseWidth), panelMaxWidth)
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = NSImage(systemSymbolName: LumaMenuBar.iconName, accessibilityDescription: "Luma")
        button.image?.isTemplate = true  // adapts to light/dark menu bar automatically
        button.toolTip = "Luma"
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        // Menu bar icon click counts as an interaction — reset the idle countdown.
        companionManager.idleTimer.reset()

        if panel == nil {
            createPanel()
        }

        // Re-check permissions each time the panel opens. The polling timer stops
        // once all permissions are confirmed, so this is the recovery path if the
        // user revokes a permission in System Settings while Luma is running.
        companionManager.refreshAllPermissions()

        positionPanelBelowStatusItem()

        guard let panel else { return }

        // Spring slide-down animation from menu bar (PRD 7.3)
        panel.alphaValue = 0
        let finalFrame = panel.frame
        let startFrame = NSRect(
            x: finalFrame.origin.x,
            y: finalFrame.origin.y + 8,
            width: finalFrame.width,
            height: finalFrame.height
        )
        panel.setFrame(startFrame, display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }

        installClickOutsideMonitor()
    }

    private func hidePanel() {
        guard let panel else { return }

        let currentFrame = panel.frame
        let endFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y + 6,
            width: currentFrame.width,
            height: currentFrame.height
        )

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(endFrame, display: true)
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
            panel.setFrame(currentFrame, display: false)
        })

        removeClickOutsideMonitor()
    }

    private func createPanel() {
            // 1. Build the SwiftUI content.
            //    No fixed width frame here — the hosting view frame IS the width constraint.
            //    When the agent response contains wide tables, updateContentWidthForAgentResponse
            //    updates the hosting view frame, SwiftUI re-renders at the new width,
            //    PanelSizeKey fires with the new CGSize, and morphPanel resizes the panel.
            let companionPanelView = CompanionPanelView(companionManager: companionManager)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PanelSizeKey.self, value: proxy.size)
                    }
                )
                .onPreferenceChange(PanelSizeKey.self) { [weak self] newSize in
                    DispatchQueue.main.async {
                        self?.morphPanel(to: newSize)
                    }
                }
                .preferredColorScheme(.dark)

            // 2. Set up the hosting view. Its frame width controls how wide SwiftUI lays out.
            //    We store a weak reference so updateContentWidthForAgentResponse can update it.
            let hostingView = NSHostingView(rootView: companionPanelView)
            hostingView.frame = NSRect(x: 0, y: 0, width: panelBaseWidth, height: panelHeight)
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = .clear
            contentHostingView = hostingView

            // 3. Create the actual Panel
            let menuBarPanel = KeyablePanel(
                contentRect: NSRect(x: 0, y: 0, width: panelBaseWidth, height: panelHeight),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            menuBarPanel.isFloatingPanel = true
            menuBarPanel.level = .floating
            menuBarPanel.isOpaque = false
            menuBarPanel.backgroundColor = .clear
            menuBarPanel.hasShadow = false
            menuBarPanel.hidesOnDeactivate = false
            menuBarPanel.isExcludedFromWindowsMenu = true
            menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            menuBarPanel.isMovableByWindowBackground = false
            menuBarPanel.titleVisibility = .hidden
            menuBarPanel.titlebarAppearsTransparent = true
            menuBarPanel.appearance = NSAppearance(named: .darkAqua)

            menuBarPanel.sharingType = .readWrite
            menuBarPanel.contentView = hostingView
            
            self.panel = menuBarPanel
        }
    
    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Derive panel size from the hosting view's current frame width
        // (set by updateContentWidthForAgentResponse) and the content's natural height.
        let currentContentWidth = contentHostingView?.frame.width ?? panelBaseWidth
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: currentContentWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        // Horizontally center the panel beneath the status item icon
        let panelOriginX = statusItemFrame.midX - (currentContentWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: currentContentWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Ignore clicks on the status item button.
            // Because the status item is owned by SystemUIServer, the global event
            // monitor sees the same click that triggered statusItemClicked — we must
            // exclude that area so the panel doesn't open and immediately close.
            if let statusButton = self.statusItem?.button,
               let buttonWindow = statusButton.window,
               buttonWindow.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
