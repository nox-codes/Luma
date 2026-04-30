//
//  LumaAgentDockWindowManager.swift
//  leanring-buddy
//
//  One floating NSPanel per agent session. The coordinator diffs the session
//  list on each update, creates/destroys panels as sessions appear/disappear,
//  and drives a 25 Hz physics timer for idle drift and working shake.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Layout Constants
// Shared between AgentBubbleWindow (hit rects, panel size) and MorphingAgentBubbleView (sizing).

private let kOrbCollapsedSize: CGFloat = 40        // Diameter of the collapsed orb
/// Icon font size inside the collapsed orb. Scaled proportionally with kOrbCollapsedSize.
private let kOrbIconSize: CGFloat = 10             // Icon pt size inside the orb
/// Minimum card width (collapsed responses, no wide tables).
private let kCardExpandedWidthMin: CGFloat = 300
/// Maximum card width — reached when tables have many columns or content is wide.
private let kCardExpandedWidthMax: CGFloat = 560
/// Card height when idle/waiting before any response arrives.
/// Sized for ~3-4 lines of placeholder text (64pt) + header (45pt) + minimal controls (82pt).
private let kCardExpandedHeightCompact: CGFloat = 192
/// Card height while a task is running (progress steps visible).
private let kCardExpandedHeightRunning: CGFloat = 238
/// Minimum height of the response scroll area — enough for 3-4 lines when idle or short response.
/// There is no hard maximum: the response area grows to fit actual content (text lines, full tables)
/// and is only bounded by kCardExpandedHeightMax minus the header and controls regions.
private let kResponseScrollMinHeight: CGFloat = 64
/// Maximum total card height. The response area fills whatever space remains after the header (~45pt)
/// and bottom controls (~80–165pt), so tables and long responses render without artificial clipping.
private let kCardExpandedHeightMax: CGFloat = 560
private let kPanelWidth: CGFloat = 340             // Wide enough for rich card content
private let kPanelHeight: CGFloat = 640            // Must exceed kCardExpandedHeightMax so card never clips
private let kOrbTrailingPadding: CGFloat = 12      // Right padding from panel edge to orb right edge
private let kOrbTopPadding: CGFloat = 2            // Top padding — lifts orb off the panel's top edge
/// Diameter of the status indicator dot that badges the orb's top-right corner.
private let kOrbStatusDotSize: CGFloat = 10
/// How far the status dot is inset from the orb's top-right corner (equal x and y).
/// Increase to push the dot further toward the orb edge / outside; decrease to tuck it inward.
private let kOrbStatusDotInset: CGFloat = 2
/// Space (pts) between the orb's edge and the inner edge of the transparent circular wrapper.
/// The wrapper diameter = kOrbCollapsedSize + kOrbWrapperPadding * 2.
/// Increase for more breathing room around the orb; decrease to tighten the fit.
private let kOrbWrapperPadding: CGFloat = 6

// MARK: - Physics Constants

private let kPhysicsTickInterval: Double = 1.0 / 25.0  // 25 Hz timer
/// Distance between orb centers (pixels) at which repulsion force begins.
/// Large enough to start pushing well before orbs can visually overlap.
private let kPhysicsRepulsionRadius: CGFloat = 160.0
/// Controls how hard bubbles push each other and bounce from edges.
/// Higher = more instant separation; lower = softer drifting.
private let kPhysicsRepulsionStrength: CGFloat = 2800.0
/// Hard minimum center-to-center gap. If two orbs are closer than this
/// (e.g., after spawning stacked), they are pushed apart every tick until clear.
/// Set to orb diameter + 6 pt breathing room so they never visually touch.
private let kMinBubbleSeparation: CGFloat = kOrbCollapsedSize + 6  // 46 pt
/// Screen-edge inset (pixels) that triggers edge repulsion.
private let kPhysicsEdgeMargin: CGFloat = 20.0
/// Per-tick velocity multiplier — simulates air resistance / friction.
/// Closer to 1.0 = less friction, bubbles travel further after a bounce.
private let kPhysicsVelocityDamping: CGFloat = 0.93
/// Hard velocity cap (pixels per tick) prevents runaway after dense stacking.
private let kPhysicsMaxSpeed: CGFloat = 22.0
/// Energy retained after a hard bounce off a screen edge (0–1).
/// 0.70 = 70% energy kept, so bubbles travel a good distance after bouncing.
private let kPhysicsBounceRestitution: CGFloat = 0.70
/// Seconds after mouse leaves an expanded card before it collapses.
/// Increase for a more forgiving interaction window.
private let kCollapseDelaySeconds: Double = 5

// MARK: - Screen-clamping helper (file-private so both AgentBubbleWindow and coordinator can use it)

/// Clamps the panel origin so the ORB stays on screen, not the full panel.
/// The panel is 340×580 and the orb sits at the TOP of the panel (not the center),
/// so the card always expands DOWNWARD from the orb — keeping the header visible.
/// Clamping the orb center (not the panel) lets the panel extend off-screen below
/// while the orb and card header remain reachable.
private func clampWindowOriginToScreen(origin: NSPoint, windowSize: NSSize) -> NSPoint {
    guard let screen = NSScreen.main else { return origin }
    let visibleFrame = screen.visibleFrame
    let halfOrb: CGFloat = kOrbCollapsedSize / 2
    // Orb center is at the TOP-RIGHT of the panel (card grows downward from orb).
    // orbOffsetX: distance from panel left edge to orb center X.
    // orbOffsetY: distance from panel bottom edge to orb center Y = panel height - halfOrb.
    let orbOffsetX = windowSize.width - kOrbTrailingPadding - halfOrb
    let orbOffsetY = windowSize.height - halfOrb - kOrbTopPadding   // orb is at the TOP of the panel, inset by top padding
    // How close to the screen edge the orb center may approach.
    let inset: CGFloat = halfOrb + 8
    // Convert screen-space orb constraints back to panel-origin constraints.
    let minPanelOriginX = visibleFrame.minX + inset - orbOffsetX
    let maxPanelOriginX = visibleFrame.maxX - inset - orbOffsetX
    let minPanelOriginY = visibleFrame.minY + inset - orbOffsetY
    let maxPanelOriginY = visibleFrame.maxY - inset - orbOffsetY
    return NSPoint(
        x: max(minPanelOriginX, min(origin.x, maxPanelOriginX)),
        y: max(minPanelOriginY, min(origin.y, maxPanelOriginY))
    )
}

// MARK: - AgentIconShape (unchanged — also used by AgentSession)

enum AgentIconShape: String, CaseIterable, Codable {
    case triangle, diamond, hexagon, star, circle, square

    var systemImageName: String {
        switch self {
        case .triangle: return "triangle.fill"
        case .diamond:  return "diamond.fill"
        case .hexagon:  return "hexagon.fill"
        case .star:     return "star.fill"
        case .circle:   return "circle.fill"
        case .square:   return "square.fill"
        }
    }

    static var random: AgentIconShape {
        allCases.randomElement() ?? .hexagon
    }
}

// MARK: - AgentBubblePhysicsState

/// Per-bubble observable state for physics animation, voice recording, and hover.
/// Updated at 25 Hz by the coordinator's physics timer.
@MainActor
final class AgentBubblePhysicsState: ObservableObject {
    /// Current pixel offset applied to the orb for physics effects.
    @Published var physicsOffset: CGSize = .zero
    /// Set by coordinator when the user is voice-recording into this agent.
    @Published var isVoiceRecording: Bool = false
    /// Set by coordinator based on exact mouse-vs-orb-rect hit testing (replaces SwiftUI
    /// onHover to prevent NSTrackingArea interference between adjacent bubble panels).
    @Published var isOrbHovered: Bool = false

    /// Measured height of the expanded card, updated by the SwiftUI view's PreferenceKey.
    /// Used by AgentBubbleWindow.expandedCardHitRect for accurate hit testing when
    /// the card is taller than the default compact height.
    @Published var measuredExpandedCardHeight: CGFloat = kCardExpandedHeightCompact

    /// Measured width of the expanded card, updated when response content changes.
    /// Drives NSPanel resize in AgentBubbleWindow so wide tables fit without clipping.
    @Published var measuredExpandedCardWidth: CGFloat = kCardExpandedWidthMin

    /// Phase offset (radians) randomized at init so all idle bubbles drift out of sync.
    let idlePhaseOffset: Double = Double.random(in: 0 ..< Double.pi * 2)
    /// Set by the coordinator based on distance to nearest running bubble (0–1).
    var proximityShakeFactor: Double = 0.0

    /// Called by the coordinator on each physics tick.
    func updatePhysics(sessionIsRunning: Bool, currentTime: TimeInterval) {
        if sessionIsRunning {
            // Violent shake: 12 pt in a random direction, updated at 25 Hz.
            let angle = Double.random(in: 0 ..< Double.pi * 2)
            let shakeRadius = 3.6
            physicsOffset = CGSize(
                width: shakeRadius * cos(angle),
                height: shakeRadius * sin(angle)
            )
        } else {
            // Idle hover: a Lissajous figure-8 path with a slow breathing envelope.
            //
            // • Incommensurate X/Y frequencies (0.68 vs 0.51 rad/s, ratio ≈ 4:3)
            //   produce a path that never exactly repeats, so the motion reads as
            //   organic floating rather than a mechanical loop.
            // • Breathing envelope oscillates between 70% and 100% of peak amplitude
            //   over ~28s (0.22 rad/s), making the orb feel like it's inhaling and
            //   exhaling rather than maintaining a fixed drift range.
            // • Y amplitude (6.5pt) > X amplitude (4.5pt): more vertical than lateral,
            //   the classic "floating" bias that reads as levitation.
            // • All offsets stay well under the orb hit rect radius (20pt), so the
            //   visual center never leaves the tracked hit region.
            let breathingEnvelope = 0.70 + 0.30 * sin(currentTime * 0.22 + idlePhaseOffset * 0.7)
            let driftAmplitudeX = 4.5 * breathingEnvelope
            let driftAmplitudeY = 6.5 * breathingEnvelope
            let driftX = driftAmplitudeX * cos(currentTime * 0.68 + idlePhaseOffset)
            let driftY = driftAmplitudeY * sin(currentTime * 0.51 + idlePhaseOffset * 1.3)

            var proximityDx = 0.0
            var proximityDy = 0.0
            if proximityShakeFactor > 0 {
                let angle = Double.random(in: 0 ..< Double.pi * 2)
                let proximityRadius = proximityShakeFactor * 12.0 * 0.35
                proximityDx = proximityRadius * cos(angle)
                proximityDy = proximityRadius * sin(angle)
            }

            physicsOffset = CGSize(width: driftX + proximityDx, height: driftY + proximityDy)
        }
    }
}

// MARK: - KeyAcceptingPanel

/// NSPanel subclass that accepts key focus so embedded SwiftUI TextFields work.
private final class KeyAcceptingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// NSHostingView subclass that accepts the very first mouse click even when
/// the app is not the key application. Without this override, the first tap
/// on the bubble is silently consumed as a "bring window forward" event and
/// never reaches the SwiftUI gesture recognizer.
private final class FirstMouseHostingView<T: View>: NSHostingView<T> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - AgentBubbleWindow

/// Wraps a single floating NSPanel for one agent session.
/// Owns drag handling (with screen clamping) and the AgentBubblePhysicsState
/// used by the SwiftUI view inside. Panel size is fixed — no resize on hover.
@MainActor
final class AgentBubbleWindow {
    let sessionID: UUID
    private(set) var physicsState: AgentBubblePhysicsState

    private let panel: NSPanel
    /// Weak reference — AgentSession lifetime is managed by CompanionManager.
    private weak var session: AgentSession?

    private var dragStartMouseScreenLocation: NSPoint = .zero
    private var dragStartWindowOrigin: NSPoint = .zero
    private var isDragging = false
    /// Holds the Combine subscription that watches measuredExpandedCardWidth and
    /// resizes the panel so wide tables / rich content are never clipped.
    private var cardWidthSubscription: AnyCancellable?

    /// Current physics velocity in screen-coordinate pixels per tick.
    /// Zeroed when the user starts dragging so drag and physics don't fight.
    fileprivate var physicsVelocity: CGPoint = .zero
    /// True while the user is actively dragging. Physics position updates are
    /// suspended during drag so the panel doesn't fight the user's cursor.
    fileprivate private(set) var isBeingDragged: Bool = false

    private var positionUserDefaultsKey: String {
        "luma.agentBubble.\(sessionID.uuidString).origin"
    }

    /// The screen-space center of the orb in this bubble's panel.
    /// The orb sits at the TOP of the panel so the card expands downward — this keeps
    /// the card header on-screen even when the orb is near the top of the display.
    var screenCenter: NSPoint {
        let orbCenterX = panel.frame.maxX - kOrbTrailingPadding - kOrbCollapsedSize / 2
        let orbCenterY = panel.frame.maxY - kOrbTopPadding - kOrbCollapsedSize / 2
        return NSPoint(x: orbCenterX, y: orbCenterY)
    }

    /// Hit rect for the collapsed orb, in screen coordinates.
    /// Used by the physics timer to drive hover-to-expand without SwiftUI onHover.
    var orbHitRect: NSRect {
        let halfOrb = kOrbCollapsedSize / 2
        let centerX = panel.frame.maxX - kOrbTrailingPadding - halfOrb
        let centerY = panel.frame.maxY - kOrbTopPadding - halfOrb
        return NSRect(x: centerX - halfOrb, y: centerY - halfOrb,
                      width: kOrbCollapsedSize, height: kOrbCollapsedSize)
    }

    /// Hit rect for the expanded card, in screen coordinates.
    /// Card starts at the TOP of the panel (where the orb is) and extends downward,
    /// so the header is always at the orb's screen position.
    var expandedCardHitRect: NSRect {
        // When expanded, use measuredExpandedCardHeight + a fixed bottom buffer instead of
        // kCardExpandedHeightMax. The buffer (80pt) covers measurement-lag scenarios where
        // GeometryReader hasn't fired yet and the bottom controls (text field, voice button,
        // suggested actions) haven't been included in the measured height.
        //
        // Using kCardExpandedHeightMax (560pt) was too conservative — it created a large
        // transparent dead zone below the actual card. Clicks in that zone were absorbed by
        // the panel (not passthrough) but no gesture or global monitor handled them, so the
        // card never collapsed when tapping in the empty space around the expanded bubble.
        let hitRectBottomBuffer: CGFloat = 80
        let activeCardHeight: CGFloat
        if physicsState.isOrbHovered {
            let measuredWithBuffer = physicsState.measuredExpandedCardHeight + hitRectBottomBuffer
            activeCardHeight = min(measuredWithBuffer, kCardExpandedHeightMax)
        } else {
            activeCardHeight = currentCardHeightFromSessionState()
        }
        let activeCardWidth = physicsState.measuredExpandedCardWidth
        let cardRight = panel.frame.maxX - kOrbTrailingPadding
        let cardLeft = cardRight - activeCardWidth
        // Card top = panel top; card bottom = panel top - card height.
        let cardTop = panel.frame.maxY - kOrbTopPadding
        return NSRect(x: cardLeft, y: cardTop - activeCardHeight,
                      width: activeCardWidth, height: activeCardHeight)
    }

    /// Mirrors the `currentExpandedHeight` logic in MorphingAgentBubbleView so
    /// the hit rect always reflects the card's actual visible height.
    private func currentCardHeightFromSessionState() -> CGFloat {
        guard let session else { return kCardExpandedHeightCompact }
        let sessionIsRunning = session.status == .running || session.status == .starting
        if sessionIsRunning {
            return session.taskSteps.isEmpty ? kCardExpandedHeightCompact : kCardExpandedHeightRunning
        }
        // Use the SwiftUI-measured adaptive height so the hit rect always matches
        // the card's actual visible size. Falls back to compact if not yet measured.
        let measured = physicsState.measuredExpandedCardHeight
        return measured > kCardExpandedHeightCompact ? measured : kCardExpandedHeightCompact
    }

    /// Whether the session attached to this window is actively running.
    var sessionIsRunning: Bool {
        guard let session else { return false }
        return session.status == .running || session.status == .starting
    }

    /// Enables or disables mouse-event pass-through for the panel.
    /// Pass `true` when the cursor is NOT over the orb or expanded card so the
    /// transparent panel area doesn't swallow clicks on elements behind it.
    func setMousePassthrough(_ passthrough: Bool) {
        panel.ignoresMouseEvents = passthrough
    }

    init(
        session: AgentSession,
        initialOrigin: NSPoint,
        onDismiss: @escaping () -> Void,
        onRunSuggestedAction: @escaping (String) -> Void,
        onSubmitText: @escaping (String) -> Void,
        onVoiceFollowUp: @escaping () -> Void,
        onVoiceToggle: @escaping () -> Void
    ) {
        self.sessionID = session.id
        self.session = session
        self.physicsState = AgentBubblePhysicsState()

        // Panel is fixed — the morphing view expands from kOrbCollapsedSize orb
        // to kCardExpandedWidth × kCardExpandedHeight card within this fixed rect.
        let panel = KeyAcceptingPanel(
            contentRect: NSRect(x: 0, y: 0, width: kPanelWidth, height: kPanelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // Start in pass-through mode — the physics tick enables hit-testing only
        // when the cursor is actually over the orb or expanded card. This prevents
        // the transparent 300×250 panel from swallowing clicks on elements behind it.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel

        let bubbleView = AgentBubbleRootView(
            session: session,
            physicsState: physicsState,
            onDragStarted: { [weak self] in self?.handleDragStarted() },
            onDragUpdated: { [weak self] in self?.handleDragUpdated() },
            onDragEnded:   { [weak self] in self?.handleDragEnded() },
            onDismiss: onDismiss,
            onRunSuggestedAction: onRunSuggestedAction,
            onSubmitText: onSubmitText,
            onVoiceFollowUp: onVoiceFollowUp,
            onVoiceToggle: onVoiceToggle,
            onBringToFront: { [weak self] in self?.panel.orderFrontRegardless() }
        )
        panel.contentView = FirstMouseHostingView(rootView: bubbleView)

        let clampedOrigin = clampWindowOriginToScreen(origin: initialOrigin, windowSize: panel.frame.size)
        panel.setFrameOrigin(clampedOrigin)
        panel.makeKeyAndOrderFront(nil)

        // Watch measured card width and resize the panel so the card never clips.
        // The orb stays anchored — when panel grows wider, origin shifts left by the delta.
        cardWidthSubscription = physicsState.$measuredExpandedCardWidth
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newCardWidth in
                self?.resizePanelForCardWidth(newCardWidth)
            }
    }

    /// Adjusts the NSPanel width to accommodate `newCardWidth`, keeping the orb
    /// anchored at its current screen position by shifting the panel origin left.
    private func resizePanelForCardWidth(_ newCardWidth: CGFloat) {
        // Panel width = card width + trailing gap to the orb's right edge
        let neededPanelWidth = newCardWidth + kOrbTrailingPadding + kOrbCollapsedSize + 8
        let currentFrame = panel.frame
        guard abs(neededPanelWidth - currentFrame.width) > 4 else { return }
        let widthDelta = neededPanelWidth - currentFrame.width
        // Shift origin left so the orb stays at the same screen position
        let newOriginX = currentFrame.origin.x - widthDelta
        let newSize = NSSize(width: neededPanelWidth, height: currentFrame.height)
        let newOrigin = NSPoint(x: newOriginX, y: currentFrame.origin.y)
        let clampedOrigin = clampWindowOriginToScreen(origin: newOrigin, windowSize: newSize)
        panel.setFrame(NSRect(origin: clampedOrigin, size: newSize), display: true, animate: false)
    }

    func close() {
        panel.close()
    }

    /// Restores the last-saved drag position from UserDefaults, if one exists.
    func restorePersistedPosition() {
        guard let values = UserDefaults.standard.array(forKey: positionUserDefaultsKey) as? [Double],
              values.count == 2 else { return }
        let savedOrigin = NSPoint(x: values[0], y: values[1])
        let clampedOrigin = clampWindowOriginToScreen(origin: savedOrigin, windowSize: panel.frame.size)
        panel.setFrameOrigin(clampedOrigin)
    }

    // MARK: Drag callbacks (invoked by SwiftUI DragGesture in AgentBubbleRootView)

    private func handleDragStarted() {
        dragStartMouseScreenLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = panel.frame.origin
        isDragging = true
        isBeingDragged = true
        physicsVelocity = .zero   // cancel any physics momentum so drag is smooth
    }

    private func handleDragUpdated() {
        let currentMouse = NSEvent.mouseLocation
        let deltaX = currentMouse.x - dragStartMouseScreenLocation.x
        let deltaY = currentMouse.y - dragStartMouseScreenLocation.y
        let proposedOrigin = NSPoint(
            x: dragStartWindowOrigin.x + deltaX,
            y: dragStartWindowOrigin.y + deltaY
        )
        let clampedOrigin = clampWindowOriginToScreen(origin: proposedOrigin, windowSize: panel.frame.size)
        panel.setFrameOrigin(clampedOrigin)
    }

    private func handleDragEnded() {
        isDragging = false
        isBeingDragged = false
        let origin = panel.frame.origin
        UserDefaults.standard.set([origin.x, origin.y], forKey: positionUserDefaultsKey)
    }

    // MARK: Physics position (called by coordinator physics tick, not user drag)

    /// Current screen-space origin of the NSPanel (bottom-left corner in macOS coords).
    fileprivate var currentPanelOrigin: NSPoint { panel.frame.origin }

    /// Moves the panel to `proposedOrigin`, clamped to screen bounds.
    /// Returns whether clamping occurred on each axis — used by the coordinator
    /// to reflect the velocity component (hard edge bounce).
    /// Does NOT persist to UserDefaults (drag saves position; physics doesn't).
    @discardableResult
    fileprivate func applyPhysicsOrigin(_ proposedOrigin: NSPoint) -> (bouncedX: Bool, bouncedY: Bool) {
        let clampedOrigin = clampWindowOriginToScreen(origin: proposedOrigin, windowSize: panel.frame.size)
        panel.setFrameOrigin(clampedOrigin)
        let bouncedX = abs(clampedOrigin.x - proposedOrigin.x) > 0.5
        let bouncedY = abs(clampedOrigin.y - proposedOrigin.y) > 0.5
        return (bouncedX: bouncedX, bouncedY: bouncedY)
    }
}

// MARK: - Coordinator

@MainActor
final class LumaAgentDockWindowManager {
    private var bubbleWindows: [UUID: AgentBubbleWindow] = [:]
    private var physicsTimer: Timer?
    /// Tracks when the mouse left each expanded bubble. After kCollapseDelaySeconds
    /// the card collapses. Cleared immediately when the mouse re-enters.
    private var collapseTimestamps: [UUID: Date] = [:]

    /// Global NSEvent monitor that collapses any open expanded card when the
    /// user clicks outside all expanded-card rects. Installed while the dock
    /// is visible and removed when it is hidden.
    private var tapOutsideExpandedCardMonitor: Any?

    // Callbacks stored so syncSessions can wire new windows after first show()
    private var onDismissAgent: ((UUID) -> Void)?
    private var onRunSuggestedAction: ((UUID, String) -> Void)?
    private var onVoiceFollowUp: ((UUID) -> Void)?
    private var onSubmitTextFromDock: ((UUID, String) -> Void)?
    private var onVoiceToggle: ((UUID) -> Void)?

    func show(
        sessions: [AgentSession],
        onDismissAgent: @escaping (UUID) -> Void,
        onRunSuggestedAction: @escaping (UUID, String) -> Void,
        onVoiceFollowUp: @escaping (UUID) -> Void,
        onSubmitTextFromDock: @escaping (UUID, String) -> Void,
        onVoiceToggle: @escaping (UUID) -> Void
    ) {
        self.onDismissAgent = onDismissAgent
        self.onRunSuggestedAction = onRunSuggestedAction
        self.onVoiceFollowUp = onVoiceFollowUp
        self.onSubmitTextFromDock = onSubmitTextFromDock
        self.onVoiceToggle = onVoiceToggle

        syncSessions(sessions)
        startPhysicsTimerIfNeeded()
        installTapOutsideMonitorIfNeeded()
    }

    func hide() {
        for (_, window) in bubbleWindows { window.close() }
        bubbleWindows.removeAll()
        stopPhysicsTimer()
        removeTapOutsideMonitor()
    }

    func setVoiceRecordingAgent(_ agentID: UUID?) {
        for (id, window) in bubbleWindows {
            window.physicsState.isVoiceRecording = (agentID == id)
        }
    }

    /// Kept for API compatibility with CompanionManager persistence code (no-op).
    var dragPositions: [UUID: CGSize] { [:] }

    /// Kept for API compatibility with CompanionManager persistence code (no-op).
    func restoreDragPositions(_ positions: [UUID: CGSize]) {}

    // MARK: Session sync

    private func syncSessions(_ sessions: [AgentSession]) {
        let incomingSessionIDs = Set(sessions.map { $0.id })

        // Close windows for sessions that are gone
        for id in bubbleWindows.keys where !incomingSessionIDs.contains(id) {
            bubbleWindows[id]?.close()
            bubbleWindows.removeValue(forKey: id)
            collapseTimestamps.removeValue(forKey: id)
        }

        // Open windows for sessions that are new
        for session in sessions where bubbleWindows[session.id] == nil {
            guard let onDismissAgent, let onRunSuggestedAction,
                  let onVoiceFollowUp, let onSubmitTextFromDock, let onVoiceToggle else { continue }

            let initialOrigin = defaultSpawnOriginForNewBubble(existingCount: bubbleWindows.count)
            let window = AgentBubbleWindow(
                session: session,
                initialOrigin: initialOrigin,
                onDismiss: {
                    onDismissAgent(session.id)
                },
                onRunSuggestedAction: { action in
                    onRunSuggestedAction(session.id, action)
                },
                onSubmitText: { text in
                    onSubmitTextFromDock(session.id, text)
                },
                onVoiceFollowUp: {
                    onVoiceFollowUp(session.id)
                },
                onVoiceToggle: {
                    onVoiceToggle(session.id)
                }
            )
            window.restorePersistedPosition()
            bubbleWindows[session.id] = window

            // ── Immediate repulsion on spawn ─────────────────────────────────────
            // If this new bubble spawns on top of (or near) an existing bubble,
            // the physics timer would gradually push them apart over ~10+ frames.
            // Instead, give the new bubble an instant velocity kick away from
            // any nearby bubble so separation begins on the very first tick.
            let newCenter = window.screenCenter
            for (_, existingWindow) in bubbleWindows where existingWindow.sessionID != session.id {
                let dx = newCenter.x - existingWindow.screenCenter.x
                let dy = newCenter.y - existingWindow.screenCenter.y
                let dist = hypot(dx, dy)
                guard dist < kPhysicsRepulsionRadius && dist > 0 else { continue }
                // Kick velocity proportional to overlap so closer = faster separation.
                let overlapFraction = max(0, 1 - dist / kPhysicsRepulsionRadius)
                let kickSpeed = kPhysicsMaxSpeed * overlapFraction
                window.physicsVelocity.x += kickSpeed * (dx / dist)
                window.physicsVelocity.y += kickSpeed * (dy / dist)
            }
        }
    }

    /// Computes a default spawn origin staggered from the top-right corner.
    /// The panel right edge is flush with the screen's right edge. The first orb
    /// spawns just below the menu-bar area; each subsequent orb stacks 10 pt below.
    private func defaultSpawnOriginForNewBubble(existingCount: Int) -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let visibleFrame = screen.visibleFrame
        let originX = visibleFrame.maxX - kPanelWidth
        // Spawn the panel so the orb sits just below the menu bar safe zone.
        // The orb is at the TOP of the panel: orbCenter.y = panelOrigin.y + kPanelHeight - kOrbCollapsedSize/2
        // So: panelOrigin.y = orbDesiredY - (kPanelHeight - kOrbCollapsedSize/2)
        //   = (visibleFrame.maxY - kPhysicsEdgeMargin - kOrbCollapsedSize/2) - kPanelHeight + kOrbCollapsedSize/2
        //   = visibleFrame.maxY - kPhysicsEdgeMargin - kPanelHeight
        // The card then grows DOWNWARD from the orb — header always on-screen.
        let topEdgeY = visibleFrame.maxY - kPhysicsEdgeMargin - kPanelHeight
        let stackedY = topEdgeY - CGFloat(existingCount) * (kOrbCollapsedSize + 10)
        return NSPoint(x: originX, y: stackedY)
    }

    // MARK: Physics timer

    private func startPhysicsTimerIfNeeded() {
        guard physicsTimer == nil else { return }
        physicsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25.0, repeats: true) { [weak self] _ in
            self?.tickPhysics()
        }
    }

    private func stopPhysicsTimer() {
        physicsTimer?.invalidate()
        physicsTimer = nil
    }

    // MARK: Tap-outside-to-collapse monitor

    private func installTapOutsideMonitorIfNeeded() {
        guard tapOutsideExpandedCardMonitor == nil else { return }

        tapOutsideExpandedCardMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.collapseExpandedCardsIfClickedOutside(clickLocation: NSEvent.mouseLocation)
            }
        }
    }

    private func removeTapOutsideMonitor() {
        if let monitor = tapOutsideExpandedCardMonitor {
            NSEvent.removeMonitor(monitor)
            tapOutsideExpandedCardMonitor = nil
        }
    }

    /// Collapses any expanded bubble whose card rect does not contain the click point.
    private func collapseExpandedCardsIfClickedOutside(clickLocation: NSPoint) {
        for (_, window) in bubbleWindows {
            guard window.physicsState.isOrbHovered else { continue }
            let isInsideExpandedCard = window.expandedCardHitRect.contains(clickLocation)
            let isInsideOrb = window.orbHitRect.contains(clickLocation)
            if !isInsideExpandedCard && !isInsideOrb {
                window.physicsState.isOrbHovered = false
                collapseTimestamps.removeValue(forKey: window.sessionID)
            }
        }
    }

    private func tickPhysics() {
        let currentTime = Date.timeIntervalSinceReferenceDate
        let mouseLocation = NSEvent.mouseLocation

        // ── Auto-collapse when mouse leaves an expanded card ───────────────────────
        // ── Delayed auto-collapse when mouse leaves an expanded card ────────────────
        // Expand is triggered by tap (TapGesture in MorphingAgentBubbleView).
        // When mouse leaves both the orb rect and the card rect, record the
        // departure time. After kCollapseDelaySeconds the card collapses.
        // Returning the mouse before the delay fires cancels the countdown.
        let now = Date()
        for (sessionID, window) in bubbleWindows {
            // Enable hit testing when the cursor is over the orb (collapsed) or
            // anywhere inside the expanded card rect. expandedCardHitRect always
            // reflects the card's actual visible height so all UI elements — title,
            // text field, voice button, recommended actions — receive clicks correctly.
            let cursorOverOrb  = window.orbHitRect.contains(mouseLocation)
            let cursorOverCard = window.physicsState.isOrbHovered
                && window.expandedCardHitRect.contains(mouseLocation)
            window.setMousePassthrough(!cursorOverOrb && !cursorOverCard)

            guard window.physicsState.isOrbHovered else {
                // Not expanded — no countdown needed.
                collapseTimestamps.removeValue(forKey: sessionID)
                continue
            }
            let mouseOverCard = window.expandedCardHitRect.contains(mouseLocation)
            let mouseOverOrb  = window.orbHitRect.contains(mouseLocation)
            if mouseOverCard || mouseOverOrb {
                // Mouse is over the bubble — reset any pending collapse countdown.
                collapseTimestamps.removeValue(forKey: sessionID)
            } else {
                // Mouse has left — start the countdown if not already running.
                if collapseTimestamps[sessionID] == nil {
                    collapseTimestamps[sessionID] = now
                } else if let departureTime = collapseTimestamps[sessionID],
                          now.timeIntervalSince(departureTime) >= kCollapseDelaySeconds {
                    // Delay elapsed — collapse the card.
                    window.physicsState.isOrbHovered = false
                    collapseTimestamps.removeValue(forKey: sessionID)
                }
            }
        }

        // ── Position physics: repulsion + edge bounce (Euler integration) ──────────
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let halfOrb = kOrbCollapsedSize / 2
        // Soft-boundary: orb center must stay this far from each screen edge.
        // orbEdgeMaxY (top boundary) is intentionally omitted — no top-edge repulsion.
        let orbEdgeMinX = visibleFrame.minX + halfOrb + kPhysicsEdgeMargin
        let orbEdgeMaxX = visibleFrame.maxX - halfOrb - kPhysicsEdgeMargin
        let orbEdgeMinY = visibleFrame.minY + halfOrb + kPhysicsEdgeMargin

        let allWindows = Array(bubbleWindows.values)

        for window in allWindows {
            // Skip position physics while the user is dragging or the card is open.
            // When expanded the card is interactive — moving it would be disorienting.
            guard !window.isBeingDragged && !window.physicsState.isOrbHovered else {
                window.physicsVelocity = .zero
                continue
            }

            let center = window.screenCenter
            var forceX: CGFloat = 0
            var forceY: CGFloat = 0

            // ── Bubble-to-bubble repulsion ───────────────────────────────────────
            for other in allWindows {
                guard other.sessionID != window.sessionID else { continue }
                let dx = center.x - other.screenCenter.x
                let dy = center.y - other.screenCenter.y
                let distSquared = dx * dx + dy * dy
                let dist = sqrt(distSquared)
                guard dist > 0 && dist < kPhysicsRepulsionRadius else { continue }
                // Force magnitude grows as bubbles get closer (inverse-square law capped).
                let forceMagnitude = kPhysicsRepulsionStrength / max(distSquared, 1)
                forceX += forceMagnitude * (dx / dist)
                forceY += forceMagnitude * (dy / dist)
            }

            // ── Edge repulsion — pushes orbs away from screen boundaries ────────
            // Using the same inverse-square model so the bounce feels natural.
            // Note: NO top-edge repulsion. Orbs are designed to live near the
            // top-right corner (below the menu bar). Adding top repulsion pushes
            // them downward during the working shake and causes visible drift.
            let leftGap   = center.x - orbEdgeMinX
            let rightGap  = orbEdgeMaxX - center.x
            let bottomGap = center.y - orbEdgeMinY

            if leftGap < kPhysicsRepulsionRadius && leftGap > 0 {
                forceX += kPhysicsRepulsionStrength / max(leftGap * leftGap, 1)
            }
            if rightGap < kPhysicsRepulsionRadius && rightGap > 0 {
                forceX -= kPhysicsRepulsionStrength / max(rightGap * rightGap, 1)
            }
            if bottomGap < kPhysicsRepulsionRadius && bottomGap > 0 {
                forceY += kPhysicsRepulsionStrength / max(bottomGap * bottomGap, 1)
            }

            // ── Euler integration: F → Δvelocity → Δposition ────────────────────
            var velocity = window.physicsVelocity
            velocity.x = velocity.x * kPhysicsVelocityDamping + forceX * CGFloat(kPhysicsTickInterval)
            velocity.y = velocity.y * kPhysicsVelocityDamping + forceY * CGFloat(kPhysicsTickInterval)

            // Clamp speed so stacked bubbles don't explode on first tick.
            let speed = hypot(velocity.x, velocity.y)
            if speed > kPhysicsMaxSpeed {
                let scale = kPhysicsMaxSpeed / speed
                velocity.x *= scale
                velocity.y *= scale
            }
            window.physicsVelocity = velocity

            // Move panel if velocity is non-trivial.
            if speed > 0.05 {
                let proposedOrigin = NSPoint(
                    x: window.currentPanelOrigin.x + velocity.x,
                    y: window.currentPanelOrigin.y + velocity.y
                )
                let bounce = window.applyPhysicsOrigin(proposedOrigin)
                // Reflect the velocity component that hit a hard screen edge,
                // with 40% energy loss so it settles rather than bouncing forever.
                if bounce.bouncedX { window.physicsVelocity.x *= -kPhysicsBounceRestitution }
                if bounce.bouncedY { window.physicsVelocity.y *= -kPhysicsBounceRestitution }
            }
        }

        // ── Hard contact separation (position correction) ───────────────────────
        // After the force pass, enforce a minimum center-to-center distance so
        // orbs never visually touch regardless of how fast they were moving.
        // Process each unique pair once (upper-triangle iteration).
        for i in 0..<allWindows.count {
            for j in (i + 1)..<allWindows.count {
                let windowA = allWindows[i]
                let windowB = allWindows[j]
                let dx = windowA.screenCenter.x - windowB.screenCenter.x
                let dy = windowA.screenCenter.y - windowB.screenCenter.y
                let dist = hypot(dx, dy)
                guard dist < kMinBubbleSeparation && dist > 0 else { continue }

                // Compute how much each orb must move to restore the minimum gap.
                let overlap = kMinBubbleSeparation - dist
                let normX = dx / dist
                let normY = dy / dist
                let halfOverlap = overlap / 2

                // Push both apart equally — only non-dragging, non-expanded orbs move.
                let aCanMove = !windowA.isBeingDragged && !windowA.physicsState.isOrbHovered
                let bCanMove = !windowB.isBeingDragged && !windowB.physicsState.isOrbHovered
                let share: CGFloat = (aCanMove && bCanMove) ? halfOverlap : overlap

                if aCanMove {
                    windowA.applyPhysicsOrigin(NSPoint(
                        x: windowA.currentPanelOrigin.x + normX * share,
                        y: windowA.currentPanelOrigin.y + normY * share
                    ))
                }
                if bCanMove {
                    windowB.applyPhysicsOrigin(NSPoint(
                        x: windowB.currentPanelOrigin.x - normX * share,
                        y: windowB.currentPanelOrigin.y - normY * share
                    ))
                }

                // Cancel any velocity component that would push the orbs back together.
                let relVelAlongNormal = (windowA.physicsVelocity.x - windowB.physicsVelocity.x) * normX
                                      + (windowA.physicsVelocity.y - windowB.physicsVelocity.y) * normY
                if relVelAlongNormal < 0 {  // approaching each other
                    if aCanMove {
                        windowA.physicsVelocity.x -= relVelAlongNormal * normX * 0.5
                        windowA.physicsVelocity.y -= relVelAlongNormal * normY * 0.5
                    }
                    if bCanMove {
                        windowB.physicsVelocity.x += relVelAlongNormal * normX * 0.5
                        windowB.physicsVelocity.y += relVelAlongNormal * normY * 0.5
                    }
                }
            }
        }

        // ── Visual shake (physicsOffset) + proximity factor ─────────────────────
        let runningBubbleCenters: [NSPoint] = bubbleWindows.values
            .filter { $0.sessionIsRunning }
            .map { $0.screenCenter }

        for (_, window) in bubbleWindows {
            if !window.sessionIsRunning && !runningBubbleCenters.isEmpty {
                let center = window.screenCenter
                let minimumDistanceToRunningBubble = runningBubbleCenters
                    .map { hypot(center.x - $0.x, center.y - $0.y) }
                    .min() ?? .infinity
                let proximityRadius: Double = 100
                window.physicsState.proximityShakeFactor = minimumDistanceToRunningBubble < proximityRadius
                    ? max(0.0, 1.0 - minimumDistanceToRunningBubble / proximityRadius)
                    : 0.0
            } else {
                window.physicsState.proximityShakeFactor = 0.0
            }

            window.physicsState.updatePhysics(
                sessionIsRunning: window.sessionIsRunning,
                currentTime: currentTime
            )
        }
    }
}

// MARK: - Adaptive card height PreferenceKeys

/// Measures the natural height of the scrollable response content region inside
/// the expanded card. Placed as a background on the content VStack inside the
/// ScrollView — the ScrollView constrains display height, but GeometryReader
/// still reports the content's intrinsic layout height (no circular dependency).
private struct CardResponseContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Measures the natural height of the fixed bottom controls region (text field,
/// voice button, recommended actions). Updates whenever actions appear or disappear.
private struct CardBottomControlsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - MarkdownBlock

/// A parsed block of markdown content, used by RichMarkdownView to render
/// tables, code blocks, headers, lists, and blockquotes with correct styling.
private enum MarkdownBlock {
    case paragraph(String)
    case header(level: Int, text: String)
    case codeBlock(language: String?, code: String)
    case table(headers: [String], rows: [[String]])
    case bulletList([String])
    case numberedList([String])
    case blockquote(String)
    case divider
}

// MARK: - Markdown Parser

/// Parses a markdown string into discrete MarkdownBlock values.
/// Handles GitHub-Flavored Markdown: fenced code blocks (``` lang), ATX headers (#),
/// pipe tables (| col | col |), bullet lists (-, *, +), numbered lists (1.),
/// blockquotes (>), and thematic breaks (---).
private func parseMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    let lines = text.components(separatedBy: "\n")
    var index = 0

    while index < lines.count {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // ── Fenced code block ─────────────────────────────────────────────────
        if trimmed.hasPrefix("```") {
            let languageTag = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let language: String? = languageTag.isEmpty ? nil : languageTag
            index += 1
            var codeLines: [String] = []
            while index < lines.count {
                let codeLine = lines[index].trimmingCharacters(in: .whitespaces)
                if codeLine.hasPrefix("```") { index += 1; break }
                codeLines.append(lines[index])
                index += 1
            }
            blocks.append(.codeBlock(language: language, code: codeLines.joined(separator: "\n")))
            continue
        }

        // ── Thematic break ────────────────────────────────────────────────────
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            blocks.append(.divider)
            index += 1
            continue
        }

        // ── ATX header ────────────────────────────────────────────────────────
        if trimmed.hasPrefix("#") {
            var level = 0
            var remaining = trimmed
            while remaining.hasPrefix("#") && level < 6 {
                level += 1
                remaining = String(remaining.dropFirst())
            }
            let headerText = remaining.trimmingCharacters(in: .whitespaces)
            if !headerText.isEmpty {
                blocks.append(.header(level: level, text: headerText))
                index += 1
                continue
            }
        }

        // ── Blockquote ────────────────────────────────────────────────────────
        if trimmed.hasPrefix(">") {
            var quoteLines: [String] = []
            while index < lines.count {
                let quoteLine = lines[index].trimmingCharacters(in: .whitespaces)
                guard quoteLine.hasPrefix(">") else { break }
                quoteLines.append(String(quoteLine.dropFirst()).trimmingCharacters(in: .whitespaces))
                index += 1
            }
            blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
            continue
        }

        // ── Pipe table ────────────────────────────────────────────────────────
        // A table is detected by: current line contains "|", and the next line
        // is a separator row (only |, -, :, space characters).
        if trimmed.contains("|") && index + 1 < lines.count {
            let nextTrimmed = lines[index + 1].trimmingCharacters(in: .whitespaces)
            let isSeparatorRow = !nextTrimmed.isEmpty && nextTrimmed.allSatisfy { "-|: ".contains($0) }
            if isSeparatorRow {
                let headerCells = parseMarkdownTableRow(trimmed)
                index += 2 // skip header row and separator row
                var tableRows: [[String]] = []
                while index < lines.count {
                    let rowTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    guard rowTrimmed.contains("|") && !rowTrimmed.isEmpty else { break }
                    tableRows.append(parseMarkdownTableRow(rowTrimmed))
                    index += 1
                }
                blocks.append(.table(headers: headerCells, rows: tableRows))
                continue
            }
        }

        // ── Bullet list ───────────────────────────────────────────────────────
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            var items: [String] = []
            while index < lines.count {
                let itemTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if itemTrimmed.hasPrefix("- ") || itemTrimmed.hasPrefix("* ") || itemTrimmed.hasPrefix("+ ") {
                    items.append(String(itemTrimmed.dropFirst(2)))
                    index += 1
                } else {
                    break
                }
            }
            if !items.isEmpty { blocks.append(.bulletList(items)) }
            continue
        }

        // ── Numbered list ─────────────────────────────────────────────────────
        // Detect "1. text", "12. text" etc. using character-level scanning.
        // Blank lines between items are tolerated: peek ahead to see if the next
        // non-empty line continues the list, so Claude responses that include
        // blank lines between items aren't split into separate 1-element blocks
        // (which would make every item show "1." regardless of its position).
        if startsWithNumberedListMarker(trimmed) {
            var items: [String] = []
            while index < lines.count {
                let itemTrimmed = lines[index].trimmingCharacters(in: .whitespaces)

                // Blank line — check if the next non-empty line continues the list.
                if itemTrimmed.isEmpty {
                    let nextNonEmptyLine = lines[(index + 1)...].first {
                        !$0.trimmingCharacters(in: .whitespaces).isEmpty
                    }
                    let nextLineIsNumberedItem = nextNonEmptyLine.map {
                        startsWithNumberedListMarker($0.trimmingCharacters(in: .whitespaces))
                    } ?? false
                    if nextLineIsNumberedItem {
                        index += 1  // skip blank line and keep accumulating
                        continue
                    } else {
                        break  // blank line before non-list content — end the list
                    }
                }

                if startsWithNumberedListMarker(itemTrimmed),
                   let dotIndex = itemTrimmed.firstIndex(of: ".") {
                    let afterDot = itemTrimmed.index(after: dotIndex)
                    if afterDot < itemTrimmed.endIndex {
                        items.append(String(itemTrimmed[afterDot...]).trimmingCharacters(in: .whitespaces))
                    }
                    index += 1
                } else {
                    break
                }
            }
            if !items.isEmpty { blocks.append(.numberedList(items)) }
            continue
        }

        // ── Skip blank lines ──────────────────────────────────────────────────
        if trimmed.isEmpty {
            index += 1
            continue
        }

        // ── Paragraph — accumulate until a block-level marker or blank line ───
        var paragraphLines: [String] = []
        while index < lines.count {
            let pLine = lines[index]
            let pTrimmed = pLine.trimmingCharacters(in: .whitespaces)
            // Stop at block-level markers
            if pTrimmed.isEmpty || pTrimmed.hasPrefix("#") || pTrimmed.hasPrefix("```") ||
               pTrimmed.hasPrefix("- ") || pTrimmed.hasPrefix("* ") || pTrimmed.hasPrefix("+ ") ||
               pTrimmed.hasPrefix("> ") || pTrimmed == "---" || pTrimmed == "***" ||
               startsWithNumberedListMarker(pTrimmed) {
                break
            }
            paragraphLines.append(pLine)
            index += 1
        }
        if !paragraphLines.isEmpty {
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
        }
    }

    return blocks
}

/// Splits a pipe-table row string into individual trimmed cell strings.
/// Leading and trailing pipes are stripped before splitting.
private func parseMarkdownTableRow(_ line: String) -> [String] {
    var stripped = line.trimmingCharacters(in: .whitespaces)
    if stripped.hasPrefix("|") { stripped = String(stripped.dropFirst()) }
    if stripped.hasSuffix("|") { stripped = String(stripped.dropLast()) }
    return stripped.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
}

/// Returns true if `line` begins with one or more digits followed by ". " —
/// the numbered-list marker pattern (e.g. "1. ", "12. ").
private func startsWithNumberedListMarker(_ line: String) -> Bool {
    var characterIndex = line.startIndex
    var hasFoundDigit = false
    while characterIndex < line.endIndex && line[characterIndex].isNumber {
        hasFoundDigit = true
        characterIndex = line.index(after: characterIndex)
    }
    guard hasFoundDigit && characterIndex < line.endIndex && line[characterIndex] == "." else { return false }
    let afterDot = line.index(after: characterIndex)
    return afterDot < line.endIndex && line[afterDot] == " "
}

// MARK: - RichMarkdownView

/// Renders parsed MarkdownBlocks with full styling:
/// - Paragraphs with inline bold/italic/code via lumaMarkdown
/// - Numbered headers (h1–h4) at decreasing font sizes
/// - Fenced code blocks (monospace dark background) and mermaid diagrams
/// - Pipe tables (header row + striped data rows)
/// - Bullet and numbered lists with accent-colored markers
/// - Blockquotes with an accent left-border
/// - Thematic dividers
/// Renders a GFM markdown string as rich SwiftUI content: paragraphs, headers,
/// code blocks (with language tags), pipe tables (striped rows, accent border),
/// bullet/numbered lists, blockquotes, and thematic breaks.
/// Shared by the agent bubble dock card and the companion panel inline response.
struct RichMarkdownView: View {
    let text: String
    let accentColor: Color

    private var parsedBlocks: [MarkdownBlock] { parseMarkdownBlocks(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(parsedBlocks.enumerated()), id: \.offset) { _, block in
                richBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func richBlockView(block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let paragraphText):
            Text(lumaMarkdown(paragraphText))
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .header(let level, let headerText):
            Text(lumaMarkdown(headerText))
                .font(.system(size: headerFontSize(level: level), weight: .bold))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level == 1 ? 4 : 2)

        case .codeBlock(let language, let codeText):
            richCodeBlockView(language: language, code: codeText)

        case .table(let headers, let rows):
            richTableView(headers: headers, rows: rows)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 7) {
                        Circle()
                            .fill(accentColor.opacity(0.70))
                            .frame(width: 4, height: 4)
                            .padding(.top, 5)
                        Text(lumaMarkdown(item))
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { itemIndex, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(itemIndex + 1).")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(accentColor.opacity(0.80))
                            .frame(width: 20, alignment: .trailing)
                        Text(lumaMarkdown(item))
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .blockquote(let quoteText):
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(accentColor.opacity(0.55))
                    .frame(width: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 1, style: .continuous))
                Text(lumaMarkdown(quoteText))
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.60))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 9)
            }

        case .divider:
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Code block

    @ViewBuilder
    private func richCodeBlockView(language: String?, code: String) -> some View {
        let isMermaid = language?.lowercased() == "mermaid"
        VStack(alignment: .leading, spacing: 0) {
            // Language tag row (if present)
            if let lang = language, !lang.isEmpty {
                HStack(spacing: 5) {
                    if isMermaid {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 9))
                    }
                    Text(isMermaid ? "Diagram" : lang)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                }
                .foregroundColor(accentColor.opacity(0.70))
                .padding(.horizontal, 9)
                .padding(.top, 7)
                .padding(.bottom, 3)
            }
            // Code body
            Text(code)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(isMermaid ? Color.white.opacity(0.55) : Color.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.top, language == nil ? 7 : 0)
                .padding(.bottom, 7)
        }
        .background(Color.black.opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(accentColor.opacity(0.20), lineWidth: 1)
        )
    }

    // MARK: - Table

    /// Minimum width per column in points. Wide enough to avoid excessive wrapping
    /// for typical cell content (model names, scores, short descriptions).
    private let kTableColumnMinWidth: CGFloat = 90

    @ViewBuilder
    private func richTableView(headers: [String], rows: [[String]]) -> some View {
        let columnCount = max(headers.count, rows.first?.count ?? 1)
        // No horizontal scroll — each cell uses maxWidth:.infinity so all columns
        // share the available width equally. The card's adaptive width already
        // sizes itself wide enough for the column count (see requiredCardWidthForResponseText).
        VStack(alignment: .leading, spacing: 0) {
            // Header row — maxWidth:.infinity distributes width equally across all columns.
            HStack(spacing: 0) {
                ForEach(0..<columnCount, id: \.self) { columnIndex in
                    Text(lumaMarkdown(columnIndex < headers.count ? headers[columnIndex] : ""))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(accentColor.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    if columnIndex < columnCount - 1 {
                        Rectangle()
                            .fill(accentColor.opacity(0.15))
                            .frame(width: 1)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
            .background(Color.white.opacity(0.06))

            // Separator between header and data
            Rectangle()
                .fill(accentColor.opacity(0.30))
                .frame(height: 1)

            // Data rows — each cell gets maxWidth:.infinity so columns stay aligned.
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, rowCells in
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { columnIndex in
                        Text(lumaMarkdown(columnIndex < rowCells.count ? rowCells[columnIndex] : ""))
                            .font(.system(size: 10))
                            .foregroundColor(Color.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        if columnIndex < columnCount - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.06))
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                        }
                    }
                }
                .background(rowIndex % 2 == 0 ? Color.clear : Color.white.opacity(0.025))

                if rowIndex < rows.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 1)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(accentColor.opacity(0.22), lineWidth: 1)
        )
    }

    private func headerFontSize(level: Int) -> CGFloat {
        switch level {
        case 1: return 15
        case 2: return 13
        case 3: return 12
        default: return 11
        }
    }
}

// MARK: - Adaptive card width helper

/// Inspects `responseText` for GFM pipe tables and returns the minimum card width
/// needed to display the widest table without excessive cell wrapping.
///
/// Algorithm:
///  1. Walk every line looking for pipe-delimited rows (start + end with `|`).
///  2. Skip separator rows (`|---|---|`).
///  3. Track the maximum column count across all table rows.
///  4. Each column gets 90pt (matching kTableColumnMinWidth in RichMarkdownView);
///     total clamped to [kCardExpandedWidthMin, kCardExpandedWidthMax].
///
/// Non-table responses return `kCardExpandedWidthMin` so the card stays compact.
private func requiredCardWidthForResponseText(_ responseText: String) -> CGFloat {
    // Collect every non-separator table row in the response text.
    // Uses the same parseMarkdownTableRow helper as RichMarkdownView so the
    // cell-splitting logic is identical to what actually renders on screen.
    var tableRows: [[String]] = []
    for line in responseText.components(separatedBy: "\n") {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard trimmedLine.contains("|") else { continue }
        // Separator rows (|---|---|) contain only pipes, dashes, colons, and spaces.
        guard !trimmedLine.allSatisfy({ "-|: ".contains($0) }) else { continue }
        let cells = parseMarkdownTableRow(trimmedLine)
        guard !cells.isEmpty else { continue }
        tableRows.append(cells)
    }
    guard !tableRows.isEmpty else { return kCardExpandedWidthMin }

    let columnCount = tableRows.map(\.count).max() ?? 0
    guard columnCount > 0 else { return kCardExpandedWidthMin }

    // For each column, find the maximum character count across all rows (header + data).
    var maxCharsPerColumn = Array(repeating: 0, count: columnCount)
    for row in tableRows {
        for (columnIndex, cellText) in row.prefix(columnCount).enumerated() {
            maxCharsPerColumn[columnIndex] = max(maxCharsPerColumn[columnIndex], cellText.count)
        }
    }

    // Per-column width estimate:
    //   • 8.5pt per character — conservative average for 10pt bold SF Pro, covers wide
    //     letters (M, W, uppercase) without underestimating narrow-heavy words.
    //   • 20pt cell padding — 8pt left + 8pt right + 4pt breathing room, matching
    //     the .padding(.horizontal, 8) in richTableView plus a small guard margin.
    //   • 70pt minimum — prevents single-char or empty columns from collapsing.
    let kAvgBoldCharWidthPts: CGFloat = 8.5
    let kCellTotalPaddingPts: CGFloat = 20
    let kMinColumnWidthPts: CGFloat = 70

    let totalColumnsWidth = maxCharsPerColumn.reduce(CGFloat(0)) { runningTotal, charCount in
        let columnWidth = max(CGFloat(charCount) * kAvgBoldCharWidthPts + kCellTotalPaddingPts,
                              kMinColumnWidthPts)
        return runningTotal + columnWidth
    }
    // Add 1pt per column divider (columnCount - 1 dividers between columns).
    let totalDividersWidth = CGFloat(max(0, columnCount - 1))
    // 28pt = 14pt left + 14pt right card content padding (.padding(.horizontal, 14)).
    let computedCardWidth = totalColumnsWidth + totalDividersWidth + 28
    return min(max(computedCardWidth, kCardExpandedWidthMin), kCardExpandedWidthMax)
}

/// Estimates the natural rendered height (in points) of the RichMarkdownView content
/// area at `cardWidth`. Used to pre-size `measuredResponseContentNaturalHeight` so the
/// card opens at the correct height immediately rather than jumping from
/// kResponseScrollMinHeight to the actual content height after GeometryReader fires.
///
/// Heights are derived directly from the rendering constants in richTableView / cardBody:
///   • Table header row: 10pt bold font + 6+6pt vertical padding = 22pt (single line)
///   • Table data row:   10pt font     + 4+4pt vertical padding = 18pt (single line)
///   • Row dividers: 1pt between each data row
///   • Block spacing: 7pt (VStack spacing in RichMarkdownView)
///   • Content area padding: 10pt top + 8pt bottom = 18pt total
private func estimatedResponseContentHeight(for responseText: String, cardWidth: CGFloat) -> CGFloat {
    // 28pt = 14pt left + 14pt right — matches .padding(.horizontal, 14) in cardBody.
    let contentWidth = max(cardWidth - 28, 100)
    let blocks = parseMarkdownBlocks(responseText)
    guard !blocks.isEmpty else { return kResponseScrollMinHeight }

    // 7pt matches VStack(spacing: 7) in RichMarkdownView.body.
    let kBlockSpacingPts: CGFloat = 7
    // 18pt = .padding(.top, 10) + .padding(.bottom, 8) on the content VStack in cardBody.
    var totalHeight: CGFloat = 18

    for (blockIndex, block) in blocks.enumerated() {
        let blockHeight: CGFloat
        switch block {
        case .table(let headers, let rows):
            let columnCount = max(headers.count, rows.first?.count ?? 1)

            // Equal width distribution across columns — same as maxWidth:.infinity in richTableView.
            // Subtract (columnCount-1) for the 1pt column dividers.
            let perColumnTotalWidth = (contentWidth - CGFloat(max(0, columnCount - 1)))
                / CGFloat(max(1, columnCount))
            // Each cell has .padding(.horizontal, 8) = 16pt, plus 4pt breathing room.
            let perColumnTextWidth = max(perColumnTotalWidth - 20, 20)

            // Header row: .padding(.vertical, 6) + 10pt bold font = 22pt per single line.
            // 6.5pt/char is conservative for 10pt bold SF Pro (covers wide uppercase letters).
            var headerRowHeight: CGFloat = 22
            for headerText in headers.prefix(columnCount) {
                let estimatedTextWidthPts = CGFloat(headerText.count) * 6.5
                if estimatedTextWidthPts > perColumnTextWidth {
                    let wrappedLineCount = ceil(estimatedTextWidthPts / perColumnTextWidth)
                    // Each additional line: 10pt font + ~3pt line gap = 13pt.
                    headerRowHeight = max(headerRowHeight, 12 + wrappedLineCount * 13)
                }
            }

            // Data rows: .padding(.vertical, 4) + 10pt font = 18pt per single line.
            // 6.0pt/char is conservative for 10pt regular SF Pro.
            var dataRowHeight: CGFloat = 18
            for row in rows {
                for cellText in row.prefix(columnCount) {
                    let estimatedTextWidthPts = CGFloat(cellText.count) * 6.0
                    if estimatedTextWidthPts > perColumnTextWidth {
                        let wrappedLineCount = ceil(estimatedTextWidthPts / perColumnTextWidth)
                        dataRowHeight = max(dataRowHeight, 8 + wrappedLineCount * 13)
                    }
                }
            }

            // Total: header + 1pt separator + R data rows + (R-1) 1pt row dividers.
            let rowDividersHeight = CGFloat(max(0, rows.count - 1))
            blockHeight = headerRowHeight + 1 + CGFloat(rows.count) * dataRowHeight + rowDividersHeight

        case .paragraph(let paragraphText):
            // 12pt font, ~16pt line height, ~6.5pt/char average at this weight.
            let charsPerLine = max(1, Int(contentWidth / 6.5))
            let lineCount = max(1, Int(ceil(Double(paragraphText.count) / Double(charsPerLine))))
            blockHeight = CGFloat(lineCount) * 16

        case .header(_, _):
            // Any header level fits in ~22pt (font size + top padding from richBlockView).
            blockHeight = 22

        case .codeBlock(let language, let codeText):
            // 10pt monospace, ~14pt line height, 7+7pt block padding.
            // Language tag row (if present) adds ~22pt.
            let lineCount = max(1, codeText.components(separatedBy: "\n").count)
            let languageTagHeight: CGFloat = (language != nil && !(language!.isEmpty)) ? 22 : 0
            blockHeight = languageTagHeight + CGFloat(lineCount) * 14 + 14

        case .bulletList(let listItems):
            // VStack(spacing: 3) with ~15pt per item (11pt font + line gap).
            blockHeight = CGFloat(listItems.count) * 15
                + CGFloat(max(0, listItems.count - 1)) * 3

        case .numberedList(let listItems):
            blockHeight = CGFloat(listItems.count) * 15
                + CGFloat(max(0, listItems.count - 1)) * 3

        case .blockquote(let quoteText):
            let charsPerLine = max(1, Int(contentWidth / 6.0))
            let lineCount = max(1, Int(ceil(Double(quoteText.count) / Double(charsPerLine))))
            blockHeight = CGFloat(lineCount) * 15

        case .divider:
            blockHeight = 1
        }

        totalHeight += blockHeight
        if blockIndex < blocks.count - 1 {
            totalHeight += kBlockSpacingPts
        }
    }

    return max(totalHeight, kResponseScrollMinHeight)
}

// MARK: - OrbAccentStatusDot

/// Single status-aware accent dot that floats at the top-right of the collapsed orb.
/// Idle/stopped → grey, working/starting → pulsing orange, ready → green, failed → red.
/// Fades to transparent as the orb morphs into the card.
private struct OrbAccentStatusDot: View {
    let status: AgentSessionStatus
    let isHovered: Bool
    @State private var isPulsingLarge = false

    private var dotColor: Color {
        switch status {
        case .stopped:            return Color.gray.opacity(0.55)
        case .ready:              return Color(red: 0.35, green: 0.78, blue: 0.45)
        case .starting, .running: return Color(red: 1.0, green: 0.62, blue: 0.22)
        case .failed:             return Color(red: 1.0, green: 0.30, blue: 0.30)
        }
    }

    private var isPulsing: Bool { status == .running || status == .starting }

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: kOrbStatusDotSize, height: kOrbStatusDotSize)
            .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
            // Subtle pulse: scale only varies by ~12% so the dot doesn't jump
            .scaleEffect(isPulsing && isPulsingLarge ? 0.88 : 1.0)
            .opacity(isHovered ? 0.0 : (isPulsing && isPulsingLarge ? 0.65 : 1.0))
            .animation(
                isPulsing ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true) : .default,
                value: isPulsingLarge
            )
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onAppear { isPulsingLarge = isPulsing }
            .onChange(of: isPulsing) { active in isPulsingLarge = active }
    }
}

// MARK: - MorphingAgentBubbleView

/// A single SwiftUI view that IS both the orb and the card.
///
/// Collapsed state (isExpanded = false):
///   • kOrbCollapsedSize circle, corner radius = half (full circle)
///   • Rich radial gradient with dark rim vignette for glassy depth
///   • Agent icon colored in session.glowColor, centered, with accent inset glow
///   • Tap gesture expands to card; physics timer collapses when mouse leaves
///   • Physics shake offset applied
///
/// Expanded state (isExpanded = true):
///   • kCardExpandedWidth × kCardExpandedHeight rounded rect, corner radius = 20
///   • Dark card: response text, recommended follow-ups, text field, voice button
///   • Drag from header strip to reposition; outer drag disabled
///
/// All opacity layers read `isExpanded` directly — no async delays — so orb and
/// card crossfade simultaneously in the same spring context with no transparent gap.
private struct MorphingAgentBubbleView: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var physicsState: AgentBubblePhysicsState

    /// True when this bubble is in its expanded card state.
    let isExpanded: Bool
    let onDragStarted: () -> Void
    let onDragUpdated: () -> Void
    let onDragEnded: () -> Void
    let onDismiss: () -> Void
    let onRunSuggestedAction: (String) -> Void
    let onSubmitText: (String) -> Void
    let onVoiceToggle: () -> Void

    @State private var isDragActive = false
    @State private var followUpInputText: String = ""
    /// Continuously-incrementing rotation angle for the in-progress step spinner.
    /// Shared across all in-progress step icons — only one step is in-progress at a time.
    @State private var spinnerRotation: Double = 0
    /// How many times the user has tapped the cancel button while a task is running.
    /// Two taps within kCancelResetSeconds stops the agent.
    @State private var cancelTapCount: Int = 0
    /// Task that resets cancelTapCount after kCancelResetSeconds if the second tap never arrives.
    @State private var cancelTapResetTask: Task<Void, Never>?
    /// Number of seconds after the first cancel tap before the count resets.
    private let kCancelResetSeconds: Double = 3.0
    /// Whether the CLI command disclosure chevron is expanded to show the raw command.
    @State private var isCLICommandDisclosureExpanded: Bool = false
    /// Adaptive width derived from response content structure (table column count).
    /// Springs to fit; clamped to [kCardExpandedWidthMin, kCardExpandedWidthMax].
    @State private var dynamicExpandedWidth: CGFloat = kCardExpandedWidthMin
    /// Natural height of the scrollable response content region as measured by
    /// CardResponseContentHeightKey. Starts at 0 (compact idle). When a response
    /// card arrives, onChange resets this to 0 so GeometryReader re-fires and
    /// springs to the actual content height (floored by kResponseScrollMinHeight,
    /// structurally bounded by kCardExpandedHeightMax via idealExpandedCardHeight).
    @State private var measuredResponseContentNaturalHeight: CGFloat = 0
    /// Natural height of the fixed bottom controls region (text field, voice, actions).
    /// Default of 80pt is a reasonable pre-measurement estimate so the card isn't
    /// initially too small before the first GeometryReader callback fires.
    @State private var measuredBottomControlsNaturalHeight: CGFloat = 80

    /// The active expanded card width — uses the response-derived adaptive width
    /// clamped between the minimum and maximum allowed values.
    private var currentExpandedWidth: CGFloat {
        max(kCardExpandedWidthMin, min(dynamicExpandedWidth, kCardExpandedWidthMax))
    }

    private var currentWidth: CGFloat { isExpanded ? currentExpandedWidth : kOrbCollapsedSize }

    /// Adaptive card height from measurements.
    /// The response area has no artificial upper bound — it grows to show all lines of text
    /// and full markdown tables. The total card height is capped at kCardExpandedHeightMax;
    /// if content exceeds that, the response region scrolls within the card.
    private var idealExpandedCardHeight: CGFloat {
        let estimatedHeaderAndDividerHeight: CGFloat = 45
        let controlsHeight = max(measuredBottomControlsNaturalHeight, 80)
        // Response area: at least kResponseScrollMinHeight so the card never collapses to
        // zero before GeometryReader fires. No upper cap — kCardExpandedHeightMax handles it.
        let responseAreaHeight = max(measuredResponseContentNaturalHeight, kResponseScrollMinHeight)
        let total = estimatedHeaderAndDividerHeight + responseAreaHeight + controlsHeight
        return min(max(total, kCardExpandedHeightCompact), kCardExpandedHeightMax)
    }

    /// Card height per state:
    ///   • Running, no steps → compact (155pt)
    ///   • Running with steps → running height (238pt)
    ///   • All other states → adaptive (measured content, clamped to [compact, max])
    private var currentExpandedHeight: CGFloat {
        let sessionIsRunning = session.status == .running || session.status == .starting
        if sessionIsRunning {
            return session.taskSteps.isEmpty ? kCardExpandedHeightCompact : kCardExpandedHeightRunning
        }
        return idealExpandedCardHeight
    }
    private var currentHeight: CGFloat { isExpanded ? currentExpandedHeight : kOrbCollapsedSize }
    private var currentCornerRadius: CGFloat { isExpanded ? 20 : kOrbCollapsedSize / 2 }

    var body: some View {
        ZStack {
            // ── Card background (expanded state) ─────────────────────────────
            // Fades in as the orb gradient fades out. Both layers always present
            // so their combined opacity is always 1 — no transparent gap.
            Color(red: 0.04, green: 0.03, blue: 0.09)
                .opacity(isExpanded ? 1 : 0)

            // ── Orb visual layers — shake offset applied here ONLY ───────────────
            // The icon and card content are siblings outside this Group so they
            // remain anchored to the orb center during the shake animation.
            Group {
                // Solid dark base — gives the orb a clean, clearly defined circular
                // container so the boundary reads as a crisp circle rather than a
                // gradient edge. Sits below all other layers.
                Circle()
                    .fill(Color(red: 0.07, green: 0.05, blue: 0.13))
                    .opacity(isExpanded ? 0 : 1)

                // Vibrant radial gradient, light source upper-left.
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: session.glowColor.opacity(0.95), location: 0.0),
                        .init(color: session.glowColor.opacity(0.75), location: 0.48),
                        .init(color: Color(red: 0.05, green: 0.02, blue: 0.12), location: 1.0),
                    ]),
                    center: UnitPoint(x: 0.30, y: 0.26),
                    startRadius: 2,
                    endRadius: kOrbCollapsedSize * 0.55
                )
                .opacity(isExpanded ? 0 : 1)

                // Dark vignette at orb edge creates glassy bowl depth.
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.clear, location: 0.44),
                        .init(color: Color.black.opacity(0.55), location: 1.0)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: kOrbCollapsedSize * 0.46
                )
                .opacity(isExpanded ? 0 : 1)

                // Specular highlights — offsets scaled for kOrbCollapsedSize = 64pt.
                Ellipse()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 21, height: 9)
                    .rotationEffect(.degrees(-22))
                    .offset(x: -9, y: -15)
                    .blur(radius: 1)
                    .blendMode(.screen)
                    .opacity(isExpanded ? 0 : 1)

                Ellipse()
                    .fill(Color.white.opacity(0.72))
                    .frame(width: 7, height: 4)
                    .offset(x: -12, y: -17)
                    .blendMode(.screen)
                    .opacity(isExpanded ? 0 : 1)
            }

            // ── Agent icon (collapsed state) ─────────────────────────────────
            // kOrbIconSize controls the pt size — adjust via the constant or
            // UserDefaults key "luma.agentBubble.iconSize".
            // The icon is colored in the session accent color, then shadowed with:
            //   • accent-color glow (simulates backlit inset illumination)
            //   • sharp black drop shadow (inset depth)
            // offset(y: -1) corrects for SF Symbol optical baseline shift — most
            // filled shapes (triangle, diamond, etc.) render slightly below the
            // geometric midpoint of their bounding box.
            Image(systemName: session.iconShape.systemImageName)
                .font(.system(size: kOrbIconSize, weight: .heavy))
                .foregroundColor(session.glowColor)
                // Layered glow: tight bright core → wide soft halo, all in the session's accent color.
                .shadow(color: session.glowColor.opacity(1.0), radius: 6)
                .shadow(color: session.glowColor.opacity(0.75), radius: 12)
                .shadow(color: session.glowColor.opacity(0.40), radius: 20)
                // Black drop shadow for inset depth (keeps icon readable against gradient)
                .shadow(color: Color.black.opacity(0.70), radius: 2, x: 0, y: 1)
                .offset(y: -1)
                .frame(width: kOrbCollapsedSize, height: kOrbCollapsedSize, alignment: .center)
                .opacity(isExpanded ? 0 : 1)

            // ── Card content (expanded state) ─────────────────────────────────
            cardContentView
                .opacity(isExpanded ? 1 : 0)
        }
        .frame(width: currentWidth, height: currentHeight)
        .clipShape(RoundedRectangle(cornerRadius: currentCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: currentCornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isExpanded ? 0.09 : 0.38),
                            Color.white.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        )
        // compositingGroup() rasterises the clipped view into a single flat bitmap
        // so SwiftUI computes the shadow from the circular alpha channel, not the
        // rectangular bounding rect of the inner ZStack. Without this the glow renders
        // as a rectangular halo instead of a circular one.
        .compositingGroup()
        .shadow(color: session.glowColor.opacity(isExpanded ? 0.18 : 0.45), radius: isExpanded ? 10 : 14)
        .shadow(color: Color.black.opacity(0.45), radius: 8, y: 3)
        // Collapsed-state drag — disabled when expanded to prevent conflicts
        // with the card header's own drag gesture
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in
                    guard !isExpanded else { return }
                    if !isDragActive { isDragActive = true; onDragStarted() }
                    onDragUpdated()
                }
                .onEnded { _ in isDragActive = false; onDragEnded() }
        )
        // If a response card was already present when this view first appeared
        // (e.g. the session completed before the bubble window was first shown),
        // SwiftUI's onChange won't fire for that initial value — only for subsequent
        // changes. onAppear pre-sizes both dimensions immediately so the card opens
        // at the correct width and height on first tap.
        .onAppear {
            guard let responseText = session.latestResponseCard?.rawText else { return }
            let initialWidth = requiredCardWidthForResponseText(responseText)
            let initialContentHeight = estimatedResponseContentHeight(for: responseText, cardWidth: initialWidth)
            // No animation — the card isn't visible yet so snapping is correct.
            if abs(initialWidth - dynamicExpandedWidth) > 4 {
                dynamicExpandedWidth = initialWidth
                physicsState.measuredExpandedCardWidth = initialWidth
            }
            if abs(initialContentHeight - measuredResponseContentNaturalHeight) > 4 {
                measuredResponseContentNaturalHeight = initialContentHeight
                let estimatedCardHeight = min(
                    max(45 + initialContentHeight + max(measuredBottomControlsNaturalHeight, 80),
                        kCardExpandedHeightCompact),
                    kCardExpandedHeightMax
                )
                physicsState.measuredExpandedCardHeight = estimatedCardHeight
            }
        }
        // When the response card changes, compute both width (from column content widths)
        // and height (from row count and block types) before GeometryReader fires.
        // This ensures the card opens at the correct size immediately rather than
        // starting at kResponseScrollMinHeight and springing upward after measurement.
        // GeometryReader still fires and overrides via onPreferenceChange if the actual
        // rendered height differs from the estimate by more than 2pt.
        .onChange(of: session.latestResponseCard?.rawText) { responseText in
            let neededWidth: CGFloat
            let estimatedContentHeight: CGFloat
            if let text = responseText {
                neededWidth = requiredCardWidthForResponseText(text)
                estimatedContentHeight = estimatedResponseContentHeight(for: text, cardWidth: neededWidth)
            } else {
                neededWidth = kCardExpandedWidthMin
                estimatedContentHeight = kResponseScrollMinHeight
            }
            // Width
            if abs(neededWidth - dynamicExpandedWidth) > 4 {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                    dynamicExpandedWidth = neededWidth
                }
                physicsState.measuredExpandedCardWidth = neededWidth
            }
            // Height — pre-size from estimate; GeometryReader overrides in onPreferenceChange
            // if the actual measured height differs by > 2pt.
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                measuredResponseContentNaturalHeight = estimatedContentHeight
            }
            let estimatedCardHeight = min(
                max(45 + estimatedContentHeight + max(measuredBottomControlsNaturalHeight, 80),
                    kCardExpandedHeightCompact),
                kCardExpandedHeightMax
            )
            DispatchQueue.main.async {
                physicsState.measuredExpandedCardHeight = estimatedCardHeight
            }
        }
    }

    // MARK: - Card content

    /// Full card layout: header + divider + body, filling the fixed card frame.
    private var cardContentView: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            Rectangle()
                .fill(session.glowColor.opacity(0.22))
                .frame(height: 1)
            cardBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var cardHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusAccentColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusAccentColor.opacity(0.8), radius: 3)

            Text(session.title.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .foregroundColor(session.glowColor.opacity(0.9))
                .kerning(0.77)
                .lineLimit(1)

            Spacer()

            statusChipView

            Button(action: onDismiss) {
                Text("✕")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 9)
        .background(Color.white.opacity(0.03))
        // Drag the entire expanded card by grabbing this header strip
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in
                    if !isDragActive { isDragActive = true; onDragStarted() }
                    onDragUpdated()
                }
                .onEnded { _ in isDragActive = false; onDragEnded() }
        )
    }

    /// Card body: two fixed regions inside the card's fixed height.
    ///
    ///   ┌──────────────────────────────┐
    ///   │  ScrollView (fills flex)     │  ← rich response / progress / placeholders
    ///   │                              │
    ///   ├──────────────────────────────┤
    ///   │  Fixed bottom controls       │  ← recommended actions + input + mic
    ///   └──────────────────────────────┘
    ///
    /// Card height adapts to content up to kCardExpandedHeightMax, then scrolls.
    /// Header and bottom controls are always visible — only the response region scrolls.
    private var cardBody: some View {
        let sessionIsRunning = session.status == .running || session.status == .starting

        // Whether a completed response is ready to display (not streaming, card present).
        let hasCompletedResponseCard = !sessionIsRunning && session.latestResponseCard?.rawText != nil

        // Height for the scrollable response content area.
        // Driven by session state (not measured height) to avoid circular dependency:
        //   • No response: kResponseScrollMinHeight (64pt — 3-4 lines of placeholder)
        //   • Response present: grows to fit actual measured content height (floored at
        //     kResponseScrollMinHeight). The card's structural ceiling is kCardExpandedHeightMax
        //     enforced by idealExpandedCardHeight — no separate scroll cap needed.
        let responseScrollViewHeight: CGFloat = {
            if hasCompletedResponseCard {
                // measuredResponseContentNaturalHeight is reset to 0 on each new response
                // so GeometryReader re-fires. Until it does, show kResponseScrollMinHeight
                // (compact). After measurement, grow to fit actual content.
                // GeometryReader inside ScrollView always reports natural content height —
                // content can grow beyond the scroll viewport, so there is no circular dependency.
                let measured = measuredResponseContentNaturalHeight
                return max(measured, kResponseScrollMinHeight)
            }
            return kResponseScrollMinHeight
        }()

        return VStack(alignment: .leading, spacing: 0) {

            // ── Region 1: scrollable content ────────────────────────────────────
            // Explicit frame height prevents Region 2 from squashing this to 0.
            // GeometryReader on the content VStack measures its intrinsic height
            // (always natural size inside a ScrollView) regardless of the viewport.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {

                    // CLI display mode
                    if session.isCLISession {
                        cliOutputSectionView(sessionIsRunning: sessionIsRunning)
                    } else {
                        // Full rich response — tables, code blocks, diagrams, lists.
                        // When a rich response is available, show it directly (no duplicate caption).
                        // Only fall back to the short summary or placeholder while the response is absent.
                        if !sessionIsRunning, let rawResponseText = session.latestResponseCard?.rawText {
                            RichMarkdownView(text: rawResponseText, accentColor: session.glowColor)
                        } else if let summary = session.shortSummary {
                            // Short summary (≤20 words) — shown only while rich response isn't ready yet
                            Text(lumaMarkdown(summary))
                                .font(.system(size: 11))
                                .foregroundColor(Color.white.opacity(0.65))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(sessionIsRunning ? "Starting..." : "Waiting for response...")
                                .font(.system(size: 11))
                                .foregroundColor(Color.white.opacity(0.28))
                                .fixedSize(horizontal: false, vertical: true)
                                .italic()
                        }

                        // Progress steps (while running)
                        if sessionIsRunning && !session.taskSteps.isEmpty {
                            progressSectionView
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
                // Measure the natural height of this content (including padding) so
                // idealExpandedCardHeight can size the card to fit without extra whitespace.
                // GeometryReader inside a ScrollView reports intrinsic content height,
                // not the constrained scroll viewport — no circular dependency.
                .background(
                    GeometryReader { contentGeo in
                        Color.clear.preference(
                            key: CardResponseContentHeightKey.self,
                            value: contentGeo.size.height
                        )
                    }
                )
            }
            // Explicit frame: grows from 0 to content height as measurements arrive.
            // Prevents Region 2 from taking all vertical space in the outer VStack.
            .frame(height: responseScrollViewHeight)

            // ── Region 2: fixed bottom controls ────────────────────────────────
            // Always pinned to the bottom of the card — never clipped by rich content.
            VStack(alignment: .leading, spacing: 7) {

                // Recommended follow-up actions (from <NEXT_ACTIONS> tags)
                let suggestedActions = session.latestResponseCard?.suggestedActions ?? []
                if !sessionIsRunning && !suggestedActions.isEmpty {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RECOMMENDED")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(Color.white.opacity(0.30))
                            .kerning(0.5)
                        ForEach(suggestedActions.prefix(2), id: \.self) { actionText in
                            Button(action: { onRunSuggestedAction(actionText) }) {
                                Text(actionText)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .background(session.glowColor.opacity(0.28))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(session.glowColor.opacity(0.65), lineWidth: 1)
                            )
                        }
                    }
                }

                // Follow-up text input
                HStack(spacing: 6) {
                    TextField(
                        sessionIsRunning ? "Tap twice to cancel..." : "Ask a follow-up...",
                        text: $followUpInputText
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(sessionIsRunning ? 0.40 : 0.80))
                    .disabled(sessionIsRunning)
                    .onSubmit { submitFollowUp() }

                    if sessionIsRunning {
                        Button(action: handleCancelTap) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(cancelTapCount > 0 ? .white : Color.white.opacity(0.55))
                                .frame(width: 20, height: 20)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(cancelTapCount > 0
                                              ? Color.red.opacity(0.65)
                                              : Color.white.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: submitFollowUp) {
                            Text("↑")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 20, height: 20)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(session.glowColor.opacity(
                                            followUpInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                ? 0.25 : 0.70
                                        ))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(followUpInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )

                // Voice button — compact, right-aligned
                HStack {
                    Spacer()
                    Button(action: onVoiceToggle) {
                        HStack(spacing: 5) {
                            Image(systemName: physicsState.isVoiceRecording ? "mic.fill" : "mic")
                                .font(.system(size: 10, weight: .bold))
                            if physicsState.isVoiceRecording {
                                Text("Listening...")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .foregroundColor(physicsState.isVoiceRecording ? .white : Color.white.opacity(0.50))
                        .padding(.horizontal, physicsState.isVoiceRecording ? 10 : 7)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(physicsState.isVoiceRecording
                                      ? Color.red.opacity(0.35)
                                      : Color.white.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(physicsState.isVoiceRecording
                                        ? Color.red.opacity(0.55)
                                        : Color.white.opacity(0.07), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 12)
            // Measure this controls region's natural height including padding.
            // Fires whenever actions appear/disappear (e.g. response card with NEXT_ACTIONS).
            .background(
                GeometryReader { controlsGeo in
                    Color.clear.preference(
                        key: CardBottomControlsHeightKey.self,
                        value: controlsGeo.size.height
                    )
                }
            )
        }
        // ── Adaptive height: update state whenever measured regions change ──────
        // Each handler recomputes idealExpandedCardHeight from the freshly-measured
        // value so physicsState always reflects the card's current visible height.
        .onPreferenceChange(CardResponseContentHeightKey.self) { newResponseHeight in
            // Ignore zero measurements (view not yet rendered) and tiny noise.
            guard newResponseHeight > 0 else { return }
            guard abs(newResponseHeight - measuredResponseContentNaturalHeight) > 2 else { return }
            // Clamp to line-count limits before storing so we don't animate past the max.
            let clampedHeight = max(newResponseHeight, kResponseScrollMinHeight)
            let estimatedHeaderAndDividerHeight: CGFloat = 45
            let adaptiveHeight = min(
                max(estimatedHeaderAndDividerHeight + clampedHeight + measuredBottomControlsNaturalHeight,
                    kCardExpandedHeightCompact),
                kCardExpandedHeightMax
            )
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                measuredResponseContentNaturalHeight = clampedHeight
            }
            DispatchQueue.main.async {
                physicsState.measuredExpandedCardHeight = adaptiveHeight
            }
        }
        .onPreferenceChange(CardBottomControlsHeightKey.self) { newControlsHeight in
            guard newControlsHeight > 0 else { return }
            guard abs(newControlsHeight - measuredBottomControlsNaturalHeight) > 2 else { return }
            let estimatedHeaderAndDividerHeight: CGFloat = 45
            let responseAreaHeight = max(measuredResponseContentNaturalHeight, kResponseScrollMinHeight)
            let adaptiveHeight = min(
                max(estimatedHeaderAndDividerHeight + responseAreaHeight + newControlsHeight,
                    kCardExpandedHeightCompact),
                kCardExpandedHeightMax
            )
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                measuredBottomControlsNaturalHeight = newControlsHeight
            }
            DispatchQueue.main.async {
                physicsState.measuredExpandedCardHeight = adaptiveHeight
            }
        }
    }

    // MARK: - CLI Display Section

    /// Replaces the normal agent response area for CLI sessions.
    /// Shows a status line (Running / Done ✓ / Failed), the command output in monospace,
    /// and a disclosure chevron that reveals the raw shell command.
    @ViewBuilder
    private func cliOutputSectionView(sessionIsRunning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {

            // ── Status line: "Running command…" / "Done ✓" / "Failed" ──────────
            HStack(spacing: 5) {
                if sessionIsRunning {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.50))
                    Text("Running command...")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.50))
                        .italic()
                } else if case .failed = session.status {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(red: 0.96, green: 0.36, blue: 0.42))
                    Text("Failed")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(red: 0.96, green: 0.36, blue: 0.42))
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(red: 0.20, green: 0.83, blue: 0.60))
                    Text("Done ✓")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(red: 0.20, green: 0.83, blue: 0.60))
                }

                Spacer()

                // Disclosure chevron — expands to show the raw shell command
                if let rawCommand = session.cliCommand {
                    Button(action: { isCLICommandDisclosureExpanded.toggle() }) {
                        HStack(spacing: 3) {
                            Text("command")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Color.white.opacity(0.30))
                            Image(systemName: isCLICommandDisclosureExpanded ? "chevron.up" : "chevron.right")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(Color.white.opacity(0.30))
                        }
                    }
                    .buttonStyle(.plain)
                    // Tapping the chevron label reveals the raw command in a code block below
                    let _ = rawCommand // suppress unused warning — used in disclosure block below
                }
            }

            // ── Raw command disclosure — shown when chevron is expanded ─────────
            if isCLICommandDisclosureExpanded, let rawCommand = session.cliCommand {
                Text(rawCommand)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.45))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            // ── Output in monospace — last lines of stdout/stderr ────────────────
            if !sessionIsRunning, let outputText = session.latestActivitySummary {
                Text(outputText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.70))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
            } else if sessionIsRunning {
                // Placeholder output area while the command is running
                Text("...")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.20))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    // MARK: - Progress Section

    /// Compact step-by-step progress view shown in the card body while the agent is running.
    /// Shows up to 4 steps; older completed steps scroll off the top as new ones arrive.
    private var progressSectionView: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: "PROGRESS" label + "X of Y steps" counter
            HStack {
                Text("PROGRESS")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(Color.white.opacity(0.30))
                    .kerning(0.5)

                Spacer()

                let completedStepCount = session.taskSteps.filter { $0.state == .completed }.count
                let totalStepCount = session.taskSteps.count
                Text("\(completedStepCount) of \(totalStepCount)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.28))
            }

            // Thin progress bar: fraction of completed steps out of total
            let completedFraction: Double = session.taskSteps.isEmpty
                ? 0
                : Double(session.taskSteps.filter { $0.state == .completed }.count) / Double(session.taskSteps.count)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 3)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(session.glowColor.opacity(0.80))
                        .frame(width: geometry.size.width * completedFraction, height: 3)
                        .animation(.easeInOut(duration: 0.4), value: completedFraction)
                }
            }
            .frame(height: 3)

            // Step rows — show the last 3 steps so the most recent activity is always visible.
            // Capping at 3 keeps the card height predictable without a scroll view.
            let visibleSteps = Array(session.taskSteps.suffix(3))
            ForEach(visibleSteps) { step in
                stepRowView(step: step)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .onAppear {
            // Start the continuous spinner rotation for in-progress step icons.
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                spinnerRotation = 360
            }
        }
    }

    /// A single step row showing the step icon and its label.
    @ViewBuilder
    private func stepRowView(step: AgentStep) -> some View {
        HStack(spacing: 6) {
            // Icon: spinning circle for in-progress, checkmark for completed, X for failed
            Group {
                switch step.state {
                case .inProgress:
                    Image(systemName: "circle.dotted")
                        .rotationEffect(.degrees(spinnerRotation))
                        .foregroundColor(session.glowColor)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(red: 0.30, green: 0.78, blue: 0.45))
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color(red: 1.0, green: 0.35, blue: 0.35))
                }
            }
            .font(.system(size: 10, weight: .medium))
            .frame(width: 14)

            Text(step.label)
                .font(.system(size: 10))
                .foregroundColor(step.state == .inProgress
                                 ? Color.white.opacity(0.80)
                                 : Color.white.opacity(0.42))
                .lineLimit(1)
        }
    }

    // MARK: - Cancel tap handler

    /// Handles a tap on the cancel button while the agent is running.
    /// First tap: turns the button red and starts a 3-second reset timer.
    /// Second tap within 3 seconds: stops the agent immediately.
    private func handleCancelTap() {
        cancelTapCount += 1
        if cancelTapCount >= 2 {
            // Confirmed cancel — stop the agent
            cancelTapResetTask?.cancel()
            cancelTapCount = 0
            Task { await session.stop() }
        } else {
            // First tap — arm the cancel; reset if second tap doesn't arrive in time
            cancelTapResetTask?.cancel()
            cancelTapResetTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(kCancelResetSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                cancelTapCount = 0
            }
        }
    }

    private func submitFollowUp() {
        let trimmedText = followUpInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        onSubmitText(trimmedText)
        followUpInputText = ""
    }

    // MARK: Status helpers

    private var statusAccentColor: Color {
        switch session.status {
        case .stopped:            return Color.gray.opacity(0.50)
        case .ready:              return Color(red: 0.35, green: 0.78, blue: 0.45)
        case .starting, .running: return Color(red: 1.0, green: 0.62, blue: 0.22)
        case .failed:             return Color(red: 1.0, green: 0.30, blue: 0.30)
        }
    }

    private var statusChipColor: Color {
        switch session.status {
        case .running, .starting: return Color.orange
        case .ready:              return Color.green
        case .failed:             return Color.red
        case .stopped:            return Color.white.opacity(0.40)
        }
    }

    private var statusChipView: some View {
        Text(session.status.displayLabel)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(statusChipColor)
            .textCase(.uppercase)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(statusChipColor.opacity(0.12)))
            .overlay(Capsule().stroke(statusChipColor.opacity(0.22), lineWidth: 1))
            .clipShape(Capsule())
    }
}

// MARK: - AgentBubbleRootView

/// Root SwiftUI view hosted in each AgentBubbleWindow panel (kPanelWidth × kPanelHeight fixed).
/// A clear passthrough background fills the panel; the morphing orb/card sits at the trailing
/// edge with an accent status dot overlaid at its top-right corner.
///
/// Hover-to-expand is driven by the coordinator's 25 Hz physics timer via
/// physicsState.isOrbHovered — not SwiftUI onHover — to prevent NSTrackingArea
/// interference between adjacent bubble panels.
private struct AgentBubbleRootView: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var physicsState: AgentBubblePhysicsState

    let onDragStarted: () -> Void
    let onDragUpdated: () -> Void
    let onDragEnded: () -> Void
    let onDismiss: () -> Void
    let onRunSuggestedAction: (String) -> Void
    let onSubmitText: (String) -> Void
    let onVoiceFollowUp: () -> Void
    let onVoiceToggle: () -> Void
    /// Called when the orb is tapped so the coordinator can bring this panel
    /// to the front — preventing a higher-z transparent panel from intercepting
    /// subsequent drags or gestures on the now-expanded card.
    let onBringToFront: () -> Void

    /// Animated local copy of physicsState.isOrbHovered.
    /// All morph animations share this single spring context.
    @State private var isExpanded = false

    var body: some View {
        // topTrailing: the orb/card is pinned to the TOP-RIGHT of the panel.
        // The card expands DOWNWARD from the orb, keeping the header on-screen
        // even when the orb is positioned near the menu bar.
        ZStack(alignment: .topTrailing) {
            // Passthrough background — hit testing is driven by simultaneousGesture below.
            Color.clear.allowsHitTesting(false)

            // Wrapper + bubble unit. Both live in a center-aligned ZStack so the orb
            // is perfectly centered inside the wrapper circle when collapsed.
            // When expanded the wrapper and card are the same size, so alignment
            // has no visible effect — they overlap exactly.
            ZStack {
                // ── Transparent morphing wrapper ─────────────────────────────────
                // Purely structural: a clean circular boundary around the orb when
                // collapsed, morphing to trace the card outline when expanded.
                // No fill, no visible stroke — invisible but defines the bubble's
                // spatial footprint and ensures the orb sits centered in a circle.
                let wrapperCollapsedSize: CGFloat = kOrbCollapsedSize + kOrbWrapperPadding * 2
                RoundedRectangle(
                    cornerRadius: isExpanded ? 20 : wrapperCollapsedSize / 2,
                    style: .continuous
                )
                .fill(Color.clear)
                .frame(
                    width: isExpanded
                        ? max(physicsState.measuredExpandedCardWidth, kCardExpandedWidthMin)
                        : wrapperCollapsedSize,
                    height: isExpanded
                        ? max(physicsState.measuredExpandedCardHeight, kCardExpandedHeightCompact)
                        : wrapperCollapsedSize
                )
                .allowsHitTesting(false)

                // ── Morphing bubble + status dot ─────────────────────────────────
                // topTrailing alignment anchors the status dot to the orb's corner
                // and ensures the card expands downward from the orb position.
                // The center-aligned outer ZStack centers this when the orb is
                // smaller than the wrapper (collapsed state).
                ZStack(alignment: .topTrailing) {
                    MorphingAgentBubbleView(
                        session: session,
                        physicsState: physicsState,
                        isExpanded: isExpanded,
                        onDragStarted: onDragStarted,
                        onDragUpdated: onDragUpdated,
                        onDragEnded: onDragEnded,
                        onDismiss: onDismiss,
                        onRunSuggestedAction: onRunSuggestedAction,
                        onSubmitText: onSubmitText,
                        onVoiceToggle: onVoiceToggle
                    )

                    // Status dot is inset from the top-right corner so it sits visibly
                    // inside the orb circle rather than hanging outside the boundary.
                    OrbAccentStatusDot(status: session.status, isHovered: isExpanded)
                        .offset(x: -kOrbStatusDotInset, y: kOrbStatusDotInset)
                }
            }
            // Physics offset: applied to the entire unit (wrapper + orb + dot) so all
            // visual elements move together. Zero out when expanded so the card stays
            // still and interactions (text fields, buttons) aren't jittery.
            .offset(
                x: isExpanded ? 0 : physicsState.physicsOffset.width,
                y: isExpanded ? 0 : physicsState.physicsOffset.height
            )
            // Animation strategy differs by state:
            //   • Idle — spring with moderate response/damping: the orb chases the
            //     sine path with trailing inertia. Because each spring is interrupted
            //     by the next 25 Hz tick before it settles, the orb permanently lags
            //     the mathematical target by ~80ms, giving it a "floating weight" feel.
            //   • Working/starting — linear 0.04s: matches the 25 Hz tick exactly so
            //     the violent shake registers immediately without spring overshoot.
            .animation(
                (session.status == .running || session.status == .starting)
                    ? .linear(duration: 0.04)
                    : .spring(response: 0.65, dampingFraction: 0.78),
                value: physicsState.physicsOffset
            )
            .padding(.trailing, kOrbTrailingPadding)
            .padding(.top, kOrbTopPadding)
            // Tap-to-expand: only fire when collapsed so the card can still receive
            // its own interactions (text fields, buttons) when expanded.
            // simultaneousGesture lets this fire even while DragGesture is pending.
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard !isExpanded else { return }
                    onBringToFront()   // bring this panel above any overlapping transparent panels
                    physicsState.isOrbHovered = true
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Spring drives the morph — response/damping approximate CSS cubic-bezier(0.34,1.56,0.64,1)
        .onChange(of: physicsState.isOrbHovered) { nowExpanded in
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
                isExpanded = nowExpanded
            }
        }
    }
}
