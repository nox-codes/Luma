//
//  CompanionResponseOverlay.swift
//  leanring-buddy
//
//  Cursor-following overlay that displays streaming AI response text.
//  Uses a non-activating NSPanel so it floats above all apps without
//  stealing focus, and repositions itself near the mouse cursor each frame.
//

import AppKit
import Combine
import SwiftUI

// MARK: - View Model

@MainActor
final class CompanionResponseOverlayViewModel: ObservableObject {
    @Published var streamingResponseText: String = ""
    @Published var isShowingResponse: Bool = false
}

// MARK: - Overlay Manager

@MainActor
final class CompanionResponseOverlayManager {
    private let overlayViewModel = CompanionResponseOverlayViewModel()
    private var overlayPanel: NSPanel?
    private var cursorTrackingTimer: Timer?
    private var autoHideWorkItem: DispatchWorkItem?

    /// The horizontal offset from the cursor to the left edge of the overlay panel.
    private let cursorOffsetX: CGFloat = 22
    /// The vertical offset from the cursor downward to the top edge of the overlay panel.
    private let cursorOffsetY: CGFloat = 6
    /// Maximum width of the overlay panel.
    private let overlayMaxWidth: CGFloat = 380

    func showOverlayAndBeginStreaming() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil

        overlayViewModel.streamingResponseText = ""
        overlayViewModel.isShowingResponse = true
        createOverlayPanelIfNeeded()
        startCursorTracking()
        overlayPanel?.alphaValue = 1
        overlayPanel?.orderFrontRegardless()
    }

    func updateStreamingText(_ accumulatedText: String) {
        overlayViewModel.streamingResponseText = accumulatedText
        resizePanelToFitContent()
    }

    func finishStreaming() {
        // Keep the response visible for a few seconds after streaming ends,
        // then fade out so the user has time to read the last chunk.
        let hideWork = DispatchWorkItem { [weak self] in
            self?.fadeOutAndHide()
        }
        autoHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: hideWork)
    }

    func hideOverlay() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        stopCursorTracking()
        overlayViewModel.isShowingResponse = false
        overlayViewModel.streamingResponseText = ""
        overlayPanel?.orderOut(nil)
    }

    // MARK: - Private

    private func createOverlayPanelIfNeeded() {
        if overlayPanel != nil { return }

        let initialFrame = NSRect(x: 0, y: 0, width: overlayMaxWidth, height: 40)
        let responseOverlayPanel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        responseOverlayPanel.level = .statusBar
        responseOverlayPanel.isOpaque = false
        responseOverlayPanel.backgroundColor = .clear
        responseOverlayPanel.hasShadow = false
        responseOverlayPanel.ignoresMouseEvents = true
        responseOverlayPanel.hidesOnDeactivate = false
        responseOverlayPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        responseOverlayPanel.isExcludedFromWindowsMenu = true
        // Exclude from screen capture so the response overlay doesn't appear in
        // Cmd+Shift+3/4 screenshots or other apps capturing the screen.
        responseOverlayPanel.sharingType = .readWrite

        let hostingView = NSHostingView(
            rootView: CompanionResponseOverlayView(viewModel: overlayViewModel)
                .frame(maxWidth: overlayMaxWidth)
        )
        hostingView.frame = initialFrame
        responseOverlayPanel.contentView = hostingView

        overlayPanel = responseOverlayPanel
    }

    private func startCursorTracking() {
        // 60fps cursor tracking so the panel stays glued to the mouse
        cursorTrackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionPanelNearCursor()
            }
        }
    }

    private func stopCursorTracking() {
        cursorTrackingTimer?.invalidate()
        cursorTrackingTimer = nil
    }

    private func repositionPanelNearCursor() {
        guard let overlayPanel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let panelSize = overlayPanel.frame.size

        // Position the panel to the right of and slightly below the cursor.
        // In macOS screen coordinates, Y increases upward, so "below" means
        // subtracting from the cursor Y.
        var panelOriginX = mouseLocation.x + cursorOffsetX
        var panelOriginY = mouseLocation.y - cursorOffsetY - panelSize.height

        // Clamp to the visible frame of the screen containing the cursor
        // so the panel never goes off-screen.
        if let currentScreen = screenContainingPoint(mouseLocation) {
            let visibleFrame = currentScreen.visibleFrame

            // If the panel would go off the right edge, flip it to the left of the cursor
            if panelOriginX + panelSize.width > visibleFrame.maxX {
                panelOriginX = mouseLocation.x - cursorOffsetX - panelSize.width
            }

            // If the panel would go below the bottom edge, push it above the cursor
            if panelOriginY < visibleFrame.minY {
                panelOriginY = mouseLocation.y + cursorOffsetY
            }

            // Final clamp
            panelOriginX = max(visibleFrame.minX, min(panelOriginX, visibleFrame.maxX - panelSize.width))
            panelOriginY = max(visibleFrame.minY, min(panelOriginY, visibleFrame.maxY - panelSize.height))
        }

        overlayPanel.setFrameOrigin(CGPoint(x: panelOriginX, y: panelOriginY))
    }

    private func resizePanelToFitContent() {
        guard let overlayPanel, let contentView = overlayPanel.contentView else { return }

        let fittingSize = contentView.fittingSize
        let newSize = CGSize(
            width: min(fittingSize.width, overlayMaxWidth),
            height: fittingSize.height
        )

        // Resize and reposition atomically: compute the screen-clamped origin for
        // the new size so the bubble never clips off any screen edge.
        contentView.frame = NSRect(origin: .zero, size: newSize)
        repositionPanelNearCursor(overrideSize: newSize)
    }

    /// Positions the panel near the cursor using `overrideSize` for layout calculations
    /// when the panel has just been resized (so we use the new size, not the stale frame).
    private func repositionPanelNearCursor(overrideSize: CGSize? = nil) {
        guard let overlayPanel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let panelSize = overrideSize ?? overlayPanel.frame.size

        var panelOriginX = mouseLocation.x + cursorOffsetX
        var panelOriginY = mouseLocation.y - cursorOffsetY - panelSize.height

        if let currentScreen = screenContainingPoint(mouseLocation) {
            let visibleFrame = currentScreen.visibleFrame

            if panelOriginX + panelSize.width > visibleFrame.maxX {
                panelOriginX = mouseLocation.x - cursorOffsetX - panelSize.width
            }
            if panelOriginY < visibleFrame.minY {
                panelOriginY = mouseLocation.y + cursorOffsetY
            }
            // Hard clamp so the bubble never bleeds off any screen edge
            panelOriginX = max(visibleFrame.minX, min(panelOriginX, visibleFrame.maxX - panelSize.width))
            panelOriginY = max(visibleFrame.minY, min(panelOriginY, visibleFrame.maxY - panelSize.height))
        }

        overlayPanel.setFrame(
            NSRect(origin: CGPoint(x: panelOriginX, y: panelOriginY), size: panelSize),
            display: true
        )
    }

    private func fadeOutAndHide() {
        guard let overlayPanel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            overlayPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Guard self as a let so it can be safely captured in the @Sendable Task closure.
            guard let self else { return }
            Task { @MainActor [self] in
                self.hideOverlay()
            }
        })
    }

    private func screenContainingPoint(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

// MARK: - SwiftUI View

private struct CompanionResponseOverlayView: View {
    @ObservedObject var viewModel: CompanionResponseOverlayViewModel
    @State private var borderHueRotation: Double = 0

    var body: some View {
        if viewModel.isShowingResponse {
            ScrollView(.vertical, showsIndicators: false) {
                markdownResponseText
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 200, maxWidth: 380)
            .frame(maxHeight: 280)
            .background(
                ZStack {
                    VisualEffectBlurView()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Color(red: 10/255, green: 10/255, blue: 15/255, opacity: 0.85)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                Color(hex: "#0A84FF"),
                                Color(hex: "#BF5AF2"),
                                Color(hex: "#FF375F"),
                                Color(hex: "#FF9F0A"),
                                Color(hex: "#30D158"),
                                Color(hex: "#0A84FF"),
                            ]),
                            center: .center
                        ),
                        lineWidth: 1.0
                    )
                    .hueRotation(.degrees(borderHueRotation))
                    .opacity(0.58)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 14, x: 0, y: 9)
            .onAppear {
                withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
                    borderHueRotation = 360
                }
            }
        }
    }

    @ViewBuilder
    private var markdownResponseText: some View {
        let safeText = viewModel.streamingResponseText.isEmpty ? "..." : viewModel.streamingResponseText
        if let attributedString = try? AttributedString(
            markdown: safeText,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributedString)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(DS.Colors.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else {
            Text(safeText)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(DS.Colors.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
