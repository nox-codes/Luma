//
//  CompanionBubbleWindow.swift
//  leanring-buddy
//
//  A small floating tooltip-style bubble that follows the mouse cursor and displays
//  contextual text from the AI companion. It never steals focus and never intercepts
//  clicks — it is purely decorative/informational.
//
//  Architecture notes:
//  - Uses NSPanel (not NSWindow) because NSPanel supports .nonactivatingPanel which
//    ensures the bubble can appear on screen without pulling keyboard focus away from
//    whatever app the user is currently working in.
//  - The bubble content is rendered via a SwiftUI BubbleContentView hosted in an
//    NSHostingView, bridged into AppKit. This lets us use SwiftUI animations,
//    modifiers, and DS tokens while still controlling the panel lifecycle in
//    AppKit where we need it (level, collection behavior, ignoresMouseEvents).
//  - Mouse position tracking uses two NSEvent monitors: one global (fires while any
//    other app is in front) and one local (fires while Luma itself is focused).
//    Both are necessary to track the cursor at all times.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Visual Effect Blur Helper

/// NSViewRepresentable wrapper for NSVisualEffectView.
///
/// We use NSVisualEffectView here instead of a pure SwiftUI solution because
/// SwiftUI's `.background(.ultraThinMaterial)` uses system-controlled material that
/// adapts to the current appearance — we want a hard-coded dark blur regardless of
/// whether the user is running macOS in light or dark mode.
struct VisualEffectBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        // .behindWindow means the blur samples from whatever is behind the window,
        // giving an authentic frosted-glass effect even over bright content.
        visualEffectView.blendingMode = .behindWindow
        // .dark forces the dark tint regardless of the system appearance setting.
        visualEffectView.material = .dark
        visualEffectView.state = .active
        return visualEffectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // No dynamic updates needed — the material and blending mode are fixed.
    }
}

// MARK: - Bubble Content SwiftUI View

/// Observable state container shared between CompanionBubbleWindow and BubbleContentView.
/// Using an ObservableObject here (rather than @Binding) because the SwiftUI view is
/// created once and hosted inside an NSHostingView — we can't pass bindings across
/// the AppKit/SwiftUI boundary after the hosting view is created.
@MainActor
final class BubbleContentState: ObservableObject {
    @Published var bubbleText: String = ""
    /// Current step index in walkthrough mode (0-based). Set to -1 when not in walkthrough.
    @Published var walkthroughCurrentStep: Int = -1
    /// Total number of steps in the current walkthrough. Set to 0 when not in walkthrough.
    @Published var walkthroughTotalSteps: Int = 0
}

/// The SwiftUI content rendered inside the floating bubble panel.
/// PRD 7.4: backdrop blur, animated gradient border, markdown rendering,
/// smooth resize, step indicators for walkthrough mode.
struct BubbleContentView: View {

    // MARK: - Layout Constants

    /// Horizontal padding inside the bubble, matching DS spacing.
    private let horizontalPaddingAmount: CGFloat = 14

    /// Vertical padding inside the bubble, matching DS spacing.
    private let verticalPaddingAmount: CGFloat = 10

    /// Minimum width so the bubble doesn't collapse to just a few characters (PRD 7.4: 200pt).
    private let minimumBubbleWidth: CGFloat = 200

    /// Maximum width before text wraps (PRD 7.4: 380pt).
    private let maximumBubbleWidth: CGFloat = 380

    /// Maximum height before content scrolls.
    private let maximumBubbleHeight: CGFloat = 300

    /// Corner radius matching DS.CornerRadius.extraLarge.
    private let bubbleCornerRadius: CGFloat = DS.CornerRadius.extraLarge

    /// Gradient border line width — slightly thicker for the animated gradient to be visible.
    private let gradientBorderLineWidth: CGFloat = 1.0

    // MARK: - State

    @ObservedObject var contentState: BubbleContentState

    /// Controls the entrance animation. Starts false, flipped to true in onAppear
    /// to trigger the spring scale + opacity transition.
    @State private var isAppearing: Bool = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main content — markdown rendered text with scroll for overflow
            ScrollView(.vertical, showsIndicators: false) {
                markdownTextView
                    .padding(.horizontal, horizontalPaddingAmount)
                    .padding(.vertical, verticalPaddingAmount)
            }
            .frame(minWidth: minimumBubbleWidth, maxWidth: maximumBubbleWidth)
            .frame(maxHeight: maximumBubbleHeight)

            // Step indicators for walkthrough mode (PRD 7.4)
            if contentState.walkthroughTotalSteps > 0 {
                walkthroughStepIndicators
                    .padding(.horizontal, horizontalPaddingAmount)
                    .padding(.bottom, 8)
            }
        }
        .background(
            ZStack {
                // Backdrop blur layer
                VisualEffectBlurView()
                // Dark overlay: rgba(10, 10, 15, 0.85)
                Color(red: 10/255, green: 10/255, blue: 15/255)
                    .opacity(0.85)
            }
        )
        .overlay(
            Rectangle()
                .stroke(Color.white.opacity(0.2), lineWidth: gradientBorderLineWidth)
        )
        .shadow(color: .black.opacity(0.4), radius: 12)
        // Spring animation on size changes for smooth resize
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: contentState.bubbleText)
        // Scale and opacity spring entrance animation
        .scaleEffect(isAppearing ? 1.0 : 0.85)
        .opacity(isAppearing ? 1.0 : 0.0)
        .animation(
            .interpolatingSpring(stiffness: 200, damping: 20),
            value: isAppearing
        )
        .onAppear {
            isAppearing = true
        }
    }

    // MARK: - Markdown Text

    /// Renders bubble text as markdown using AttributedString (PRD 7.4).
    /// Falls back to plain text if markdown parsing fails.
    private var markdownTextView: some View {
        Group {
            if let attributedString = try? AttributedString(markdown: contentState.bubbleText,
                                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributedString)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(contentState.bubbleText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Walkthrough Step Indicators

    /// Dot indicators showing current step / total for walkthrough mode (PRD 7.4).
    private var walkthroughStepIndicators: some View {
        HStack(spacing: 5) {
            ForEach(0..<contentState.walkthroughTotalSteps, id: \.self) { stepIndex in
                Rectangle()
                    .fill(stepIndex <= contentState.walkthroughCurrentStep
                          ? LumaAccentTheme.current.cursorColor
                          : DS.Colors.textPrimary.opacity(0.2))
                    .frame(width: 5, height: 5)
                    .animation(.easeInOut(duration: 0.2), value: contentState.walkthroughCurrentStep)
            }
            Spacer()
            if contentState.walkthroughTotalSteps > 0 {
                Text("\(contentState.walkthroughCurrentStep + 1)/\(contentState.walkthroughTotalSteps)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
    }
}

// MARK: - Companion Bubble Window

/// A small, always-on-top floating bubble that follows the mouse cursor.
///
/// Design goals:
/// - Never steals focus (NSPanel with .nonactivatingPanel)
/// - Never blocks clicks (.ignoresMouseEvents = true)
/// - Follows the cursor in real time via global + local NSEvent monitors
/// - Fades in/out smoothly when shown or hidden
/// - Stays within screen bounds by detecting edge proximity
@MainActor
final class CompanionBubbleWindow {

    // MARK: - Singleton

    static let shared = CompanionBubbleWindow()

    // MARK: - Constants

    /// How far to the right of the cursor the bubble's leading edge sits (in pts).
    private let cursorRightOffsetPoints: CGFloat = 20

    /// How far below the cursor the bubble's top edge sits (in pts).
    private let cursorBelowOffsetPoints: CGFloat = 20

    /// How far to the left of the cursor the bubble's trailing edge sits when
    /// the bubble would overflow the right screen edge (in pts).
    private let cursorLeftOffsetPoints: CGFloat = 20

    /// Duration of the hide fade-out animation in seconds.
    private let hideFadeAnimationDuration: TimeInterval = 0.1

    /// An approximate fixed bubble size used for edge-overflow calculations.
    /// The actual size varies with text content, but this gives us a reasonable
    /// estimate for deciding whether to flip the position before layout completes.
    private let approximateBubbleSize = CGSize(width: 200, height: 50)

    // MARK: - State

    /// Whether the bubble panel is currently ordered onto the screen.
    private(set) var isVisible: Bool = false

    // MARK: - Private AppKit State

    /// The backing NSPanel. We use NSPanel (not NSWindow) for .nonactivatingPanel support.
    private let bubblePanel: NSPanel

    /// Observable state shared with the hosted SwiftUI view.
    private let bubbleContentState = BubbleContentState()

    /// Global event monitor — fires when OTHER apps are in the foreground.
    /// Needed so the bubble continues to track the cursor even when Luma isn't active.
    private var globalMouseMovedEventMonitor: Any?

    /// Local event monitor — fires when Luma itself is the active application.
    /// The global monitor does NOT fire for the app's own events, so we need both.
    private var localMouseMovedEventMonitor: Any?

    // MARK: - Initialization

    private init() {
        // MARK: Panel Setup
        //
        // We use .borderless | .nonactivatingPanel together because:
        // - .borderless: removes all standard window chrome (title bar, close button, etc.)
        // - .nonactivatingPanel: critical — prevents the panel from becoming the key window
        //   when shown, so the user's focused app keeps keyboard control.
        let bubblePanelStyleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        let initialFrame = CGRect(x: 0, y: 0, width: 200, height: 50)

        bubblePanel = NSPanel(
            contentRect: initialFrame,
            styleMask: bubblePanelStyleMask,
            backing: .buffered,
            defer: true  // Defer creation until the panel is first shown — improves startup time.
        )

        // Transparent background — the SwiftUI view provides all visual styling.
        bubblePanel.isOpaque = false
        bubblePanel.backgroundColor = .clear

        // Float above regular app windows but below system UI (menu bar, Spotlight, etc.).
        bubblePanel.level = .floating

        // Join all Spaces so the bubble follows the user even on full-screen app spaces.
        bubblePanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        // Critical: the bubble must NEVER intercept mouse events. It is purely visual.
        bubblePanel.ignoresMouseEvents = true

        // A subtle drop shadow reinforces the floating-above-content feel.
        bubblePanel.hasShadow = true

        // Ensure the panel never attempts to become the key window.
        // .nonactivatingPanel already handles this, but we set the property explicitly
        // for clarity and defence-in-depth.
        bubblePanel.becomesKeyOnlyIfNeeded = false
        // Exclude from screen capture so the bubble doesn't appear in
        // Cmd+Shift+3/4 screenshots or other apps capturing the screen.
        bubblePanel.sharingType = .readWrite

        // MARK: Hosted SwiftUI Content

        let bubbleContentView = BubbleContentView(contentState: bubbleContentState)
        let hostingView = NSHostingView(rootView: bubbleContentView)

        // Allow the hosting view to shrink-wrap to its content size.
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        bubblePanel.contentView = hostingView

        // MARK: Mouse Tracking Monitors

        // Global monitor: fires for mouse-moved events from ALL apps (including the
        // system) while another app is active. We use this so the bubble keeps
        // following the cursor when Luma is running in the background.
        globalMouseMovedEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .mouseMoved
        ) { [weak self] _ in
            // We intentionally ignore the event itself — NSEvent.mouseLocation always
            // returns the current global cursor position in screen coordinates, which
            // is exactly what we need for positioning the bubble.
            Task { @MainActor in
                self?.updateBubblePanelPositionToFollowCursor()
            }
        }

        // Local monitor: fires for mouse-moved events generated by Luma itself
        // (when Luma is the active app). The global monitor above won't fire in
        // this case, so we install a second monitor to cover that scenario.
        localMouseMovedEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .mouseMoved
        ) { [weak self] event in
            Task { @MainActor in
                self?.updateBubblePanelPositionToFollowCursor()
            }
            // Return the event unchanged — we are only observing, not consuming it.
            return event
        }
    }

    deinit {
        // Clean up event monitors to prevent dangling callbacks after dealloc.
        if let globalMonitor = globalMouseMovedEventMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor = localMouseMovedEventMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    // MARK: - Public API

    /// Updates walkthrough step indicators shown at the bottom of the bubble.
    /// Call with totalSteps: 0 to hide the indicators.
    func updateWalkthroughProgress(currentStep: Int, totalSteps: Int) {
        bubbleContentState.walkthroughCurrentStep = currentStep
        bubbleContentState.walkthroughTotalSteps = totalSteps
    }

    /// Shows the bubble with the given text. If the bubble is already visible,
    /// its text is updated immediately in place (no hide/show cycle).
    ///
    /// - Parameter text: The contextual string to display inside the bubble.
    func show(text: String) {
        // Update text first so the view is ready before we order it front.
        bubbleContentState.bubbleText = text

        // Let SwiftUI complete its layout pass, then resize the NSPanel to fit
        // the actual text content. This ensures single-line responses get a
        // compact bubble and multi-line text grows the panel to match.
        DispatchQueue.main.async { [weak self] in
            self?.resizePanelToFitContent()
        }

        // Position the bubble at the current cursor location before making it visible
        // so there's no frame-of-lag where it appears at (0,0).
        updateBubblePanelPositionToFollowCursor()

        if !isVisible {
            bubblePanel.alphaValue = 0.0
            let visibleFrame = bubblePanel.frame
            let startFrame = NSRect(
                x: visibleFrame.origin.x,
                y: visibleFrame.origin.y - 6,
                width: visibleFrame.width,
                height: visibleFrame.height
            )
            bubblePanel.setFrame(startFrame, display: false)
            bubblePanel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bubblePanel.animator().alphaValue = 1.0
                bubblePanel.animator().setFrame(visibleFrame, display: true)
            }
            isVisible = true
        }
    }

    /// Hides the bubble with a short fade-out animation.
    ///
    /// The panel is ordered out (removed from screen) only after the fade completes
    /// so the disappearance looks smooth rather than abrupt.
    func hide() {
        guard isVisible else { return }

        // Animate to fully transparent.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = hideFadeAnimationDuration
            bubblePanel.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            guard let self = self else { return }
            // Capture self as a let constant so it can be passed into the @Sendable Task closure.
            // NSAnimationContext completion handlers are Sendable, so @MainActor isolation
            // must be re-established explicitly.
            let capturedSelf = self
            Task { @MainActor in
                // Remove from screen after the fade finishes. This also resets alpha for
                // the next show() call — orderOut doesn't reset alphaValue automatically.
                capturedSelf.bubblePanel.orderOut(nil)
                capturedSelf.bubblePanel.alphaValue = 1.0
                capturedSelf.isVisible = false
            }
        }
    }

    // MARK: - Private Sizing

    /// Resizes the NSPanel to match the SwiftUI content's natural size, clamped
    /// between the same min/max values used by BubbleContentView.
    /// Must be called after SwiftUI has had a layout pass (dispatch async to main).
    private func resizePanelToFitContent() {
        guard let contentView = bubblePanel.contentView else { return }
        let naturalSize = contentView.fittingSize
        // Clamp to the same bounds BubbleContentView uses
        let clampedWidth  = max(200, min(naturalSize.width,  380))
        let clampedHeight = max(30,  min(naturalSize.height, 300))
        bubblePanel.setContentSize(CGSize(width: clampedWidth, height: clampedHeight))
    }

    // MARK: - Private Positioning

    /// Reads the current global cursor position and repositions the bubble panel
    /// so it tracks the cursor with a consistent offset. Adjusts the offset when
    /// the bubble would overflow the right or bottom edge of the current screen.
    private func updateBubblePanelPositionToFollowCursor() {
        // NSEvent.mouseLocation returns global screen coordinates in AppKit's
        // coordinate system (origin at bottom-left of the primary screen).
        let currentCursorLocation = NSEvent.mouseLocation

        // Determine which screen the cursor is currently on so we can use its
        // bounds for edge-overflow calculations.
        let screenContainingCursor = NSScreen.screens.first { screen in
            screen.frame.contains(currentCursorLocation)
        } ?? NSScreen.main ?? NSScreen.screens[0]

        let screenFrame = screenContainingCursor.visibleFrame
        let bubbleSize = bubblePanel.frame.size == .zero ? approximateBubbleSize : bubblePanel.frame.size

        // Start with the default position: right and below the cursor tip.
        var bubbleOriginX = currentCursorLocation.x + cursorRightOffsetPoints
        var bubbleOriginY = currentCursorLocation.y - cursorBelowOffsetPoints - bubbleSize.height

        // If the bubble would overflow the right edge of the screen, flip it to
        // the left of the cursor instead so it stays fully visible.
        let wouldOverflowRightEdge = (bubbleOriginX + bubbleSize.width) > screenFrame.maxX
        if wouldOverflowRightEdge {
            bubbleOriginX = currentCursorLocation.x - cursorLeftOffsetPoints - bubbleSize.width
        }

        // If the bubble would overflow the bottom edge of the screen, flip it to
        // above the cursor instead. In AppKit coords, "below" means a lower Y value.
        let wouldOverflowBottomEdge = bubbleOriginY < screenFrame.minY
        if wouldOverflowBottomEdge {
            // Place the bubble above the cursor tip with the same vertical gap.
            bubbleOriginY = currentCursorLocation.y + cursorBelowOffsetPoints
        }

        bubbleOriginX = min(
            max(bubbleOriginX, screenFrame.minX),
            screenFrame.maxX - bubbleSize.width
        )
        bubbleOriginY = min(
            max(bubbleOriginY, screenFrame.minY),
            screenFrame.maxY - bubbleSize.height
        )

        let adjustedBubbleOrigin = CGPoint(x: bubbleOriginX, y: bubbleOriginY)

        // Use setFrameOrigin for instant repositioning — the spring animation feel
        // comes from the SwiftUI content view's entrance animation, not from the
        // window frame itself. Animating the frame via NSAnimationContext here would
        // cause the bubble to lag noticeably behind the cursor.
        bubblePanel.setFrameOrigin(adjustedBubbleOrigin)
    }
}
