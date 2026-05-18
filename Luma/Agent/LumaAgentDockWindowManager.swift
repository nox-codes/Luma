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

private let kOrbCollapsedSize: CGFloat = 64        // Diameter of the collapsed orb (matches AgentBubbleSettings default bubbleSize)
/// Icon font size inside the collapsed orb. Scaled proportionally with kOrbCollapsedSize.
private let kOrbIconSize: CGFloat = 16             // Icon pt size inside the orb
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
private let kMinBubbleSeparation: CGFloat = kOrbCollapsedSize + 6  // 70 pt (orb diameter + breathing room)
/// Screen-edge inset (pixels) that triggers edge repulsion.
private let kPhysicsEdgeMargin: CGFloat = 20.0
/// Per-tick velocity multiplier — simulates air resistance / friction.
/// Closer to 1.0 = less friction, bubbles travel further after a bounce.
private let kPhysicsVelocityDamping: CGFloat = 0.93
/// Hard velocity cap (pixels per tick) prevents runaway after dense stacking.
private let kPhysicsMaxSpeed: CGFloat = 22.0
// MARK: - Screen-clamping helper (file-private so both AgentBubbleWindow and coordinator can use it)

/// Clamps the panel origin so the ORB stays fully on the screen it currently occupies.
/// Multi-monitor aware: finds the screen whose frame contains the proposed orb center
/// (or the nearest screen if the orb is between displays) rather than always using
/// NSScreen.main. This prevents orbs on secondary monitors from clamping to the wrong
/// display's boundaries.
///
/// The panel is kPanelWidth×kPanelHeight and the orb sits at the TOP-RIGHT corner.
/// The card always expands DOWNWARD and LEFTWARD from the orb — keeping the orb and
/// card header reachable even when the card body extends below the visible area.
private func clampWindowOriginToScreen(origin: NSPoint, windowSize: NSSize) -> NSPoint {
    let halfOrb: CGFloat = kOrbCollapsedSize / 2
    // Orb center offsets relative to the panel's bottom-left origin.
    let orbOffsetX = windowSize.width - kOrbTrailingPadding - halfOrb
    let orbOffsetY = windowSize.height - halfOrb - kOrbTopPadding
    let proposedOrbCenter = NSPoint(x: origin.x + orbOffsetX, y: origin.y + orbOffsetY)

    // Find the screen whose frame contains the proposed orb center.
    // Falls back to the nearest screen when the orb is between displays or off all screens.
    let targetScreen = NSScreen.screens.first { $0.frame.contains(proposedOrbCenter) }
        ?? NSScreen.screens.min(by: { a, b in
            let da = hypot(a.visibleFrame.midX - proposedOrbCenter.x,
                           a.visibleFrame.midY - proposedOrbCenter.y)
            let db = hypot(b.visibleFrame.midX - proposedOrbCenter.x,
                           b.visibleFrame.midY - proposedOrbCenter.y)
            return da < db
        })
        ?? NSScreen.main
    guard let visibleFrame = targetScreen?.visibleFrame else { return origin }

    // Minimum gap between the orb center and each screen edge.
    let inset: CGFloat = halfOrb + 8
    // Translate screen-space orb constraints back to panel-origin constraints.
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
        // No shake or drift in any state — the orb stays perfectly still.
        // Motion was removed because it made the bubble feel distracting and
        // unprofessional, especially when multiple agents are active.
        physicsOffset = .zero
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
    
    @_optimize(none)
    deinit {}

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

    /// Brings the panel to the front, above all other floating panels.
    /// Called by the coordinator when hover-to-expand fires so this bubble's
    /// panel is on top and receives all subsequent interaction events.
    func bringToFront() {
        panel.orderFrontRegardless()
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
    /// NSEvent monitor installed when the physics timer is stopped. Fires on mouse moves
    /// and restarts the physics timer the moment the cursor enters a bubble's vicinity.
    /// Nil while the physics timer is running — the two are mutually exclusive.
    private var physicsWakeMonitor: Any?

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
        removePhysicsWakeMonitor()
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
        // Remove the wake monitor before starting — the two are mutually exclusive.
        removePhysicsWakeMonitor()
        guard physicsTimer == nil else { return }
        physicsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25.0, repeats: true) { [weak self] _ in
            #if DEBUG
            EnergyDebugLogger.timerFired("physicsTimer@25Hz", rateLimit: 25)
            #endif
            self?.tickPhysics()
        }
    }

    private func stopPhysicsTimer() {
        physicsTimer?.invalidate()
        physicsTimer = nil
    }

    /// Installs a lightweight NSEvent mouse-movement monitor that restarts the physics
    /// timer when the cursor enters any bubble's vicinity. Only installed when the physics
    /// timer is stopped — gives zero CPU cost when the user's cursor is far from all bubbles.
    private func installPhysicsWakeMonitorIfNeeded() {
        guard physicsWakeMonitor == nil else { return }
        physicsWakeMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let mouseLocation = NSEvent.mouseLocation
                // Expand the orb hit rect by 30 pt on each side so the timer wakes
                // slightly before the cursor actually enters the orb — feels instant.
                let isNearAnyBubble = self.bubbleWindows.values.contains { window in
                    window.orbHitRect.insetBy(dx: -30, dy: -30).contains(mouseLocation)
                }
                if isNearAnyBubble {
                    self.startPhysicsTimerIfNeeded()
                }
            }
        }
    }

    private func removePhysicsWakeMonitor() {
        guard let monitor = physicsWakeMonitor else { return }
        NSEvent.removeMonitor(monitor)
        physicsWakeMonitor = nil
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
            }
        }
    }

    private func tickPhysics() {
        let currentTime = Date.timeIntervalSinceReferenceDate
        let mouseLocation = NSEvent.mouseLocation

        // ── Hover-to-expand and immediate collapse ─────────────────────────────────
        // Expand fires when the cursor enters the orb hit rect (25 Hz → ~40ms latency).
        // Collapse fires immediately the moment the cursor leaves both the orb and card
        // rects — no delay, so the bubble snaps shut as soon as the user moves away.
        for (_, window) in bubbleWindows {
            // Enable hit testing only when the cursor is over the orb (collapsed) or
            // anywhere inside the expanded card rect. This prevents the transparent
            // panel area from swallowing clicks on elements behind it.
            let cursorOverOrb  = window.orbHitRect.contains(mouseLocation)
            let cursorOverCard = window.physicsState.isOrbHovered
                && window.expandedCardHitRect.contains(mouseLocation)
            window.setMousePassthrough(!cursorOverOrb && !cursorOverCard)

            // Hover-to-expand: when the cursor enters the orb rect and the card is
            // not yet open, expand immediately.
            if cursorOverOrb && !window.physicsState.isOrbHovered {
                window.physicsState.isOrbHovered = true
                window.bringToFront()
            }

            // Immediate collapse: when the card is open and the cursor has left both
            // the orb rect and the expanded card rect, collapse without any delay.
            if window.physicsState.isOrbHovered && !cursorOverOrb && !cursorOverCard {
                window.physicsState.isOrbHovered = false
            }
        }

        // ── Position physics: bubble-to-bubble repulsion (Euler integration) ──────
        // Orbs stop hard at screen edges via clampWindowOriginToScreen — no bounce.
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

            // Move panel if velocity is non-trivial. Hard screen-edge clamping in
            // applyPhysicsOrigin ensures orbs stop at the boundary without bouncing.
            if speed > 0.05 {
                let proposedOrigin = NSPoint(
                    x: window.currentPanelOrigin.x + velocity.x,
                    y: window.currentPanelOrigin.y + velocity.y
                )
                window.applyPhysicsOrigin(proposedOrigin)
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

        // Auto-stop when truly idle: no session running, no bubble hovered, no residual velocity.
        // Installs a zero-cost NSEvent wake monitor so the timer restarts the moment
        // the cursor approaches any bubble — zero timers firing at true idle.
        let anySessionActive = bubbleWindows.values.contains { $0.sessionIsRunning }
        let anyBubbleHovered = bubbleWindows.values.contains { $0.physicsState.isOrbHovered }
        let anyBubbleMoving = bubbleWindows.values.contains { hypot($0.physicsVelocity.x, $0.physicsVelocity.y) > 0.05 }

        if !anySessionActive && !anyBubbleHovered && !anyBubbleMoving {
            stopPhysicsTimer()
            installPhysicsWakeMonitorIfNeeded()
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

// MARK: - MorphingAgentBubbleView

/// A single SwiftUI view that IS both the orb and the card.
///
/// Collapsed state (expansionProgress = 0.0):
///   • orbSize circle, corner radius = half (full circle)
///   • The style-specific AgentOrbView at full opacity, card background transparent
///
/// Expanded state (expansionProgress = 1.0):
///   • currentExpandedWidth × currentExpandedHeight rounded rect, corner radius = 14
///   • Dark card: response text, recommended follow-ups, text field, voice button
///   • Drag from header strip to reposition; outer drag disabled
///
/// All dimensions, corner radii, and opacities are interpolated from expansionProgress
/// so every animation frame produces the correct intermediate shape — true shape morphing
/// from a circle to a rounded rect rather than a simple fade between two states.
/// Each bubble style contributes a unique per-style visual effect at the midpoint.
private struct MorphingAgentBubbleView: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var physicsState: AgentBubblePhysicsState

    /// Expansion progress: 0.0 = fully collapsed orb, 1.0 = fully expanded card.
    /// Animated by AgentBubbleRootView using a style-specific spring curve.
    let expansionProgress: CGFloat
    /// Whether the bubble is primarily in card state — used for boolean guards
    /// (drag gesture check) that don't need the interpolated float value.
    private var isExpanded: Bool { expansionProgress > 0.5 }
    /// Orb diameter from the user's bubbleSize setting — matches AgentOrbView's diameter.
    private var orbSize: CGFloat { CGFloat(bubbleSettingsManager.settings.bubbleSize) }
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
    /// Bubble settings manager — used to read the current style for the card header mini icon.
    /// Observing the shared singleton ensures the mini icon re-renders when the style changes.
    @ObservedObject private var bubbleSettingsManager = AgentBubbleSettingsManager.shared

    /// The active expanded card width — uses the response-derived adaptive width
    /// clamped between the minimum and maximum allowed values.
    private var currentExpandedWidth: CGFloat {
        max(kCardExpandedWidthMin, min(dynamicExpandedWidth, kCardExpandedWidthMax))
    }

    private var currentWidth: CGFloat {
        orbSize + (currentExpandedWidth - orbSize) * expansionProgress
    }

    /// Adaptive card height from measurements.
    /// The response area has no artificial upper bound — it grows to show all lines of text
    /// and full markdown tables. The total card height is capped at kCardExpandedHeightMax;
    /// if content exceeds that, the response region scrolls within the card.
    private var idealExpandedCardHeight: CGFloat {
        let estimatedHeaderAndDividerHeight: CGFloat = 46  // header (45pt) + 1pt divider
        // Response area: floored at kResponseScrollMinHeight so the card never collapses to
        // zero before GeometryReader fires. No upper cap — kCardExpandedHeightMax handles it.
        let responseAreaHeight = max(measuredResponseContentNaturalHeight, kResponseScrollMinHeight)
        // Controls height estimate: the input zone alone is ~76pt. Recommended actions now
        // render as pill buttons in a single horizontal row, adding ~54pt regardless of count.
        // GeometryReader overrides this via onPreferenceChange if its measurement differs.
        let suggestedActionsCount = min(
            (session.latestResponseCard?.suggestedActions ?? []).count, 2
        )
        let estimatedControlsHeightFromActions: CGFloat = suggestedActionsCount > 0
            ? 76 + 54
            : 76
        // Use whichever is larger: measured or estimated — so the card never clips.
        let controlsHeight = max(measuredBottomControlsNaturalHeight, estimatedControlsHeightFromActions)
        let total = estimatedHeaderAndDividerHeight + responseAreaHeight + controlsHeight
        // 5% extra breathing room: ensures content never clips at the bottom edge.
        // kCardExpandedHeightMax ceiling still applies — extreme content scrolls.
        let totalWithPadding = total * 1.05
        return min(max(totalWithPadding, kCardExpandedHeightCompact), kCardExpandedHeightMax)
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
    private var currentHeight: CGFloat {
        orbSize + (currentExpandedHeight - orbSize) * expansionProgress
    }
    private var currentCornerRadius: CGFloat {
        orbSize / 2 + (14 - orbSize / 2) * expansionProgress
    }

    var body: some View {
        ZStack {
            // ── Card background — fades in as expansion progresses ─────────────
            // #141614 = JSX T.s1 — the design system card surface colour.
            Color(hex: "#141614")
                .opacity(Double(expansionProgress))

            // ── Per-style ambient background — subtle continuous animation behind card content ──
            // Fades in with the card and plays on every animation frame so the expanded state
            // feels alive. Low opacity (~6-13%) ensures it never competes with the response text.
            // Rate-limited to 8fps at idle: slow gradients (9°/s rotation, 0.045u/s shimmer)
            // are visually indistinguishable at 8fps vs 60fps, saving ~85% of render cost.
            let ambientFrameInterval: TimeInterval = (session.status == .running || session.status == .starting) ? 1.0/60.0 : 1.0/8.0
            TimelineView(.animation(minimumInterval: ambientFrameInterval)) { ambientTimeline in
                expandedCardAmbientBackground(
                    currentTime: ambientTimeline.date.timeIntervalSinceReferenceDate
                )
            }
            .opacity(Double(expansionProgress))
            .allowsHitTesting(false)

            // ── Card content — fades in as expansion progresses ──────────────────
            cardContentView
                .opacity(Double(expansionProgress))
        }
        .frame(width: currentWidth, height: currentHeight)
        .clipShape(RoundedRectangle(cornerRadius: currentCornerRadius, style: .continuous))
        // Specular highlight: white gradient ring visible on the collapsed orb,
        // fades out as the morph progresses toward the card form.
        .overlay(
            RoundedRectangle(cornerRadius: currentCornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.38), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
                .opacity(Double(1 - expansionProgress))
        )
        // Card border: solid design-system border colour, fades in as the morph completes.
        .overlay(
            RoundedRectangle(cornerRadius: currentCornerRadius, style: .continuous)
                .stroke(Color(hex: "#2E322E"), lineWidth: 1.0)
                .opacity(Double(expansionProgress))
        )
        // Collapsed-state drag — disabled while expanding or fully expanded to
        // prevent conflicts with the card header's own drag gesture.
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in
                    guard expansionProgress < 0.5 else { return }
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
            guard let responseCard = session.latestResponseCard else { return }
            let responseText = responseCard.rawText
            let initialWidth = requiredCardWidthForResponseText(responseText)
            let initialContentHeight = estimatedResponseContentHeight(for: responseText, cardWidth: initialWidth)
            // Estimate controls height from suggested actions count so the card opens
            // at the correct size immediately — no post-render jump.
            // Pills render in a single horizontal row, so height is fixed (~54pt) regardless of count.
            let actionsCount = min(responseCard.suggestedActions.count, 2)
            let estimatedControlsHeight: CGFloat = actionsCount > 0
                ? 76 + 54
                : 76
            // No animation — the card isn't visible yet so snapping is correct.
            if abs(initialWidth - dynamicExpandedWidth) > 4 {
                dynamicExpandedWidth = initialWidth
                physicsState.measuredExpandedCardWidth = initialWidth
            }
            if abs(initialContentHeight - measuredResponseContentNaturalHeight) > 4 {
                measuredResponseContentNaturalHeight = initialContentHeight
            }
            // Use the larger of measured and estimated controls height.
            let effectiveControlsHeight = max(measuredBottomControlsNaturalHeight, estimatedControlsHeight)
            let estimatedCardHeight = min(
                max((46 + initialContentHeight + effectiveControlsHeight) * 1.05,
                    kCardExpandedHeightCompact),
                kCardExpandedHeightMax
            )
            physicsState.measuredExpandedCardHeight = estimatedCardHeight
        }
        // When the response card changes, compute both width (from column content widths)
        // and height (from row count and block types) before GeometryReader fires.
        // This ensures the card opens at the correct size immediately rather than
        // starting at kResponseScrollMinHeight and springing upward after measurement.
        // GeometryReader still fires and overrides via onPreferenceChange if the actual
        // rendered height differs from the estimate by more than 2pt.
        .onChange(of: session.latestResponseCard?.rawText) { _ in
            let responseCard = session.latestResponseCard
            let responseText = responseCard?.rawText
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
            // Height — pre-size from estimate, accounting for suggested actions.
            // GeometryReader overrides via onPreferenceChange if actual measured height differs.
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                measuredResponseContentNaturalHeight = estimatedContentHeight
            }
            // Pills render in a single horizontal row, so height is fixed (~54pt) regardless of count.
            let actionsCount = min(responseCard?.suggestedActions.count ?? 0, 2)
            let estimatedControlsHeight: CGFloat = actionsCount > 0
                ? 76 + 54
                : 76
            let effectiveControlsHeight = max(measuredBottomControlsNaturalHeight, estimatedControlsHeight)
            let estimatedCardHeight = min(
                max((46 + estimatedContentHeight + effectiveControlsHeight) * 1.05,
                    kCardExpandedHeightCompact),
                kCardExpandedHeightMax
            )
            DispatchQueue.main.async {
                physicsState.measuredExpandedCardHeight = estimatedCardHeight
            }
        }
    }

    // MARK: - Expanded card ambient background

    /// Returns a continuously-animated per-style background rendered behind card content.
    /// Driven by `currentTime` from a `TimelineView(.animation)` so it loops smoothly at the
    /// display refresh rate. Subtle enough not to compete with response text, vivid enough
    /// to keep the expanded card feeling alive. Fades in with `expansionProgress`.
    @ViewBuilder
    private func expandedCardAmbientBackground(currentTime: TimeInterval) -> some View {
        let style = bubbleSettingsManager.settings.style
        let glowColor = session.glowColor

        switch style {
        case .aurora:
            // Slowly rotating angular gradient sweeping from the orb corner.
            // Full rotation every ~40 s at 9°/s — barely perceptible drift.
            AngularGradient(
                colors: [
                    glowColor.opacity(0.20),
                    Color.white.opacity(0.06),
                    glowColor.opacity(0.14),
                    glowColor.opacity(0.26),
                    Color.white.opacity(0.04),
                    glowColor.opacity(0.16),
                    glowColor.opacity(0.20)
                ],
                center: .topTrailing,
                angle: .degrees(currentTime * 9.0)
            )
            .blendMode(.screen)

        case .crystal:
            // A slow diagonal shimmer band drifts left-to-right across the card surface,
            // suggesting light catching a crystal face — one sweep every ~22 s.
            let sweepPosition = (currentTime * 0.045).truncatingRemainder(dividingBy: 1.6) - 0.3
            LinearGradient(
                colors: [.clear, Color.white.opacity(0.10), glowColor.opacity(0.14), Color.white.opacity(0.08), .clear],
                startPoint: UnitPoint(x: sweepPosition, y: 0.0),
                endPoint: UnitPoint(x: sweepPosition + 0.4, y: 1.0)
            )
            .blendMode(.screen)

        case .inkDrop:
            // Two blurred ellipses drift slowly on independent Lissajous paths, giving
            // the card a wet, organic background that echoes the collapsed blob's motion.
            let inkPhase = currentTime * 0.18
            ZStack {
                Ellipse()
                    .fill(glowColor.opacity(0.20))
                    .frame(width: currentExpandedWidth * 0.65, height: currentExpandedHeight * 0.45)
                    .offset(
                        x: CGFloat(sin(inkPhase)) * currentExpandedWidth * 0.18,
                        y: CGFloat(cos(inkPhase * 0.77)) * currentExpandedHeight * 0.18
                    )
                    .blur(radius: 30)
                Ellipse()
                    .fill(glowColor.opacity(0.12))
                    .frame(width: currentExpandedWidth * 0.45, height: currentExpandedHeight * 0.35)
                    .offset(
                        x: CGFloat(cos(inkPhase * 1.33)) * currentExpandedWidth * 0.22,
                        y: CGFloat(sin(inkPhase * 0.55)) * currentExpandedHeight * 0.22
                    )
                    .blur(radius: 22)
            }
            .blendMode(.screen)

        case .spectrum:
            // A slow radial pulse breathes from the orb corner — like a subwoofer hum
            // felt rather than heard. Pulse period: ~2.9 s.
            let spectrumPulse = 0.5 + sin(currentTime * 2.2) * 0.5
            RadialGradient(
                colors: [glowColor.opacity(0.20 * spectrumPulse), glowColor.opacity(0.06), .clear],
                center: .topTrailing,
                startRadius: 8,
                endRadius: 160
            )
            .blendMode(.screen)

        case .orbital:
            // Three dashed concentric rings rotate at slightly different speeds from the
            // orb corner, suggesting orbital trajectories continuing behind the card text.
            Canvas { context, size in
                let cx = size.width - orbSize / 2
                let cy = orbSize / 2
                // Outer rings rotate more slowly than inner — 72°/min for innermost.
                let baseAngularSpeed = currentTime * 0.20  // radians/s
                for ringIndex in 0..<3 {
                    let ringRadius: CGFloat = 60 + CGFloat(ringIndex) * 58
                    let angularOffset = baseAngularSpeed * (1.0 + Double(ringIndex) * 0.12)
                    let segmentCount = 14
                    let segmentArcLength = Double.pi * 2.0 / Double(segmentCount)
                    for segmentIndex in 0..<segmentCount {
                        let startAngle = Double(segmentIndex) * segmentArcLength + angularOffset
                        let endAngle = startAngle + segmentArcLength * 0.50
                        var segmentPath = Path()
                        segmentPath.addArc(
                            center: CGPoint(x: cx, y: cy),
                            radius: ringRadius,
                            startAngle: .radians(startAngle),
                            endAngle: .radians(endAngle),
                            clockwise: false
                        )
                        let segmentOpacity: Double = 0.16 - Double(ringIndex) * 0.04
                        context.stroke(
                            segmentPath,
                            with: .color(glowColor.opacity(segmentOpacity)),
                            lineWidth: 1.0
                        )
                    }
                }
            }
            .blendMode(.screen)

        case .prismCard:
            // A slow prismatic shimmer sweeps diagonally, more gradual than the morph transition —
            // one sweep every ~17 s, echoing light moving across a held card.
            let prismSweepPosition = (currentTime * 0.06).truncatingRemainder(dividingBy: 1.8) - 0.2
            LinearGradient(
                colors: [.clear, Color.white.opacity(0.12), glowColor.opacity(0.16), Color.white.opacity(0.10), .clear],
                startPoint: UnitPoint(x: prismSweepPosition, y: 0.0),
                endPoint: UnitPoint(x: prismSweepPosition + 0.35, y: 1.0)
            )
            .blendMode(.screen)
        }
    }

    // MARK: - Card content

    /// Full card layout: header + divider + body with a left accent strip overlaid.
    /// The accent strip is 3pt wide, inset 14pt from top and bottom — matching the
    /// JSX `Card` component's `position:'absolute', left:0, top:14, bottom:14` strip.
    private var cardContentView: some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                cardHeader
                Rectangle()
                    .fill(Color(hex: "#2E322E"))
                    .frame(height: 1)
                cardBody
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Left accent strip: 3pt wide, inset 14pt from both top and bottom edges.
            // borderRadius:'0 3px 3px 0' from JSX = small trailing corner radius.
            VStack(spacing: 0) {
                Color.clear.frame(height: 14)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(LinearGradient(
                        colors: [session.glowColor, session.glowColor.opacity(0.60)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .shadow(color: session.glowColor.opacity(0.55), radius: 5)
                Color.clear.frame(height: 14)
            }
            .frame(width: 3)
            .frame(maxHeight: .infinity)
            .allowsHitTesting(false)
        }
    }

    private var cardHeader: some View {
        HStack(spacing: 9) {
            // Style-aware mini icon (28pt) — visually matches the collapsed orb.
            // Reads the current bubble style from AgentBubbleSettingsManager so the
            // card header always reflects the style the user has selected.
            StyleAwareMiniIconView(
                style: bubbleSettingsManager.settings.style,
                accentColor: session.glowColor,
                isWorking: session.status == .running || session.status == .starting,
                size: 28
            )

            // Agent name — sentence-case for a friendly, approachable card header.
            Text(session.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(Color(hex: "#ECEEED"))
                .lineLimit(1)

            Spacer()

            // Status badge pill (Working / Idle / Done / Failed / Stopped)
            statusBadgeView

            // Dismiss button
            Button(action: onDismiss) {
                Text("✕")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#9BA39D"))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 13)
        .padding(.top, 11)
        .padding(.bottom, 10)
        .background(Color.white.opacity(0.015))
        // Drag the entire expanded card by grabbing this header strip.
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
                                .foregroundColor(Color(hex: "#555D58"))
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
            // Input zone with JSX dark surface (#1A1C1A) and #2E322E top border.
            // Recommended actions render above the input zone when available.
            VStack(alignment: .leading, spacing: 0) {

                // Recommended follow-up actions (from <NEXT_ACTIONS> tags).
                // Rendered as accent-colored pill buttons in a horizontal row above the input zone.
                let suggestedActions = session.latestResponseCard?.suggestedActions ?? []
                if !sessionIsRunning && !suggestedActions.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("RECOMMENDED")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(Color(hex: "#555D58"))
                            .kerning(0.5)
                        HStack(spacing: 6) {
                            ForEach(suggestedActions.prefix(2), id: \.self) { actionText in
                                Button(action: { onRunSuggestedAction(actionText) }) {
                                    Text(actionText)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                }
                                .buttonStyle(.plain)
                                .background(session.glowColor)
                                .clipShape(Capsule())
                            }
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(hex: "#1A1C1A"))
                    .overlay(
                        Rectangle().fill(Color(hex: "#2E322E")).frame(height: 1),
                        alignment: .top
                    )
                }

                // Input zone: section label + text field row (text + mic + send/cancel).
                // Matches the JSX InputZone component layout.
                VStack(alignment: .leading, spacing: 7) {
                    // Compute input-empty state once at the VStack level so it can be
                    // referenced by both the send button appearance and its .disabled modifier
                    // without needing a let inside the @ViewBuilder if/else branch.
                    let inputIsEmpty = followUpInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                    // Section label — "REDIRECT AGENT" while running, "FOLLOW UP" at rest.
                    Text(sessionIsRunning ? "Redirect agent" : "Follow up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(hex: "#555D58"))
                        .textCase(.uppercase)
                        .kerning(0.6)

                    // Input row: text field + mic button + send or cancel button.
                    HStack(spacing: 6) {
                        TextField(
                            sessionIsRunning ? "Assign new task (stops current)..." : "Ask a follow-up...",
                            text: $followUpInputText
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#ECEEED").opacity(sessionIsRunning ? 0.40 : 0.85))
                        .disabled(sessionIsRunning)
                        .onSubmit { submitFollowUp() }

                        // Mic / voice toggle button — red when listening, muted at rest.
                        Button(action: onVoiceToggle) {
                            Image(systemName: physicsState.isVoiceRecording ? "mic.fill" : "mic")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(
                                    physicsState.isVoiceRecording
                                        ? Color(hex: "#FF6369")
                                        : Color(hex: "#9BA39D")
                                )
                                .frame(width: 22, height: 22)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(
                                            physicsState.isVoiceRecording
                                                ? Color(hex: "#FF6369").opacity(0.15)
                                                : Color(hex: "#282B28")
                                        )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(
                                            physicsState.isVoiceRecording
                                                ? Color(hex: "#FF6369").opacity(0.35)
                                                : Color(hex: "#2E322E"),
                                            lineWidth: 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)

                        // Cancel button (running) or send button (idle/done).
                        if sessionIsRunning {
                            Button(action: handleCancelTap) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(cancelTapCount > 0 ? .white : Color(hex: "#9BA39D"))
                                    .frame(width: 22, height: 22)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(cancelTapCount > 0 ? Color.red.opacity(0.65) : Color(hex: "#282B28"))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(
                                                cancelTapCount > 0
                                                    ? Color.red.opacity(0.50)
                                                    : Color(hex: "#2E322E"),
                                                lineWidth: 1
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button(action: submitFollowUp) {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(inputIsEmpty ? Color(hex: "#555D58") : .white)
                                    .frame(width: 22, height: 22)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(inputIsEmpty ? Color(hex: "#282B28") : session.glowColor)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(
                                                inputIsEmpty ? Color(hex: "#2E322E") : session.glowColor,
                                                lineWidth: 1
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(inputIsEmpty)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(hex: "#212421"))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color(hex: "#2E322E"), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 11)
                .background(Color(hex: "#1A1C1A"))
                .overlay(
                    Rectangle().fill(Color(hex: "#2E322E")).frame(height: 1),
                    alignment: .top
                )
            }
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
                    .background(Color(hex: "#1A1C1A"))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            // ── Output in monospace — last lines of stdout/stderr ────────────────
            if !sessionIsRunning, let outputText = session.latestActivitySummary {
                Text(outputText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "#9BA39D"))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "#1A1C1A"))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(hex: "#2E322E"), lineWidth: 1)
                    )
            } else if sessionIsRunning {
                // Placeholder output area while the command is running
                Text("...")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "#555D58"))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "#1A1C1A"))
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
                    .foregroundColor(Color(hex: "#555D58"))
                    .kerning(0.5)

                Spacer()

                let completedStepCount = session.taskSteps.filter { $0.state == .completed }.count
                let totalStepCount = session.taskSteps.count
                Text("\(completedStepCount) of \(totalStepCount)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(hex: "#555D58"))
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
                        .fill(session.glowColor)
                        .frame(width: geometry.size.width * completedFraction, height: 3)
                        .shadow(color: session.glowColor.opacity(0.60), radius: 4)
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
        .background(Color(hex: "#1A1C1A"))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(hex: "#2E322E"), lineWidth: 1)
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
                        .foregroundColor(Color(hex: "#34D399"))
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color(hex: "#E5484D"))
                }
            }
            .font(.system(size: 10, weight: .medium))
            .frame(width: 14)

            Text(step.label)
                .font(.system(size: 10))
                .foregroundColor(step.state == .inProgress
                                 ? Color(hex: "#9BA39D")
                                 : Color(hex: "#555D58"))
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

    /// Returns the (label, color) pair for the status badge pill in the card header.
    /// Maps agent session state to the JSX design system status labels and colors.
    private var statusBadgeInfo: (String, Color) {
        switch session.status {
        case .running, .starting:
            return ("Working", Color(hex: "#60A5FA"))
        case .ready where session.latestResponseCard != nil:
            return ("Done", Color(hex: "#34D399"))
        case .ready:
            return ("Idle", Color(hex: "#34D399"))
        case .failed:
            return ("Failed", Color(hex: "#E5484D"))
        case .stopped:
            return ("Stopped", Color(hex: "#555D58"))
        }
    }

    /// Pill-shaped status badge rendered in the card header.
    /// Uses accent-tinted background + matching border per the JSX design.
    private var statusBadgeView: some View {
        let (badgeLabel, badgeColor) = statusBadgeInfo
        return Text(badgeLabel)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(badgeColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(badgeColor.opacity(0.15)))
            .overlay(Capsule().stroke(badgeColor.opacity(0.25), lineWidth: 1))
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

    /// Expansion progress: 0.0 = fully collapsed orb, 1.0 = fully expanded card.
    /// Animated by `onChange(of: physicsState.isOrbHovered)` using a style-specific
    /// spring curve. Because this is a CGFloat, SwiftUI interpolates it at every
    /// animation frame, driving the true shape morph in MorphingAgentBubbleView.
    @State private var expansionProgress: CGFloat = 0
    /// Boolean convenience derived from expansionProgress — used by views and modifiers
    /// that need a stable binary collapsed/expanded check (offset, animation guard).
    private var isExpanded: Bool { expansionProgress > 0.5 }
    /// Smoothed version of physicsState.measuredExpandedCardHeight for the outer wrapper.
    /// physicsState.measuredExpandedCardHeight is set via DispatchQueue.main.async (no
    /// animation), so direct use causes the wrapper to jump abruptly mid-morph and after
    /// the morph settles. This @State tracks the same value but transitions via a spring,
    /// keeping the wrapper height in sync with MorphingAgentBubbleView's animated interior.
    @State private var smoothedWrapperExpandedHeight: CGFloat = kCardExpandedHeightCompact

    /// Bubble appearance settings (ink drop style, morph speed, bubble size, etc.)
    @ObservedObject private var bubbleSettingsManager = AgentBubbleSettingsManager.shared

    var body: some View {
        // All bubble styles use the user-configured bubbleSize for the collapsed orb diameter.
        let effectiveOrbSize: CGFloat = CGFloat(bubbleSettingsManager.settings.bubbleSize)

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
                // Purely structural: defines the bubble's spatial footprint and
                // ensures all child views clip to the correct shape boundary.
                // Interpolated by expansionProgress so the wrapper tracks the
                // true morph from circle to rounded rect at every animation frame.
                let wrapperCollapsedSize: CGFloat = effectiveOrbSize + kOrbWrapperPadding * 2
                let wrapperExpandedWidth = max(physicsState.measuredExpandedCardWidth, kCardExpandedWidthMin)
                // Use smoothedWrapperExpandedHeight (spring-animated) rather than
                // physicsState.measuredExpandedCardHeight (unaniamted async update) so the
                // wrapper grows smoothly instead of jumping during and after the morph.
                let wrapperExpandedHeight = max(smoothedWrapperExpandedHeight, kCardExpandedHeightCompact)
                let wrapperCurrentWidth = wrapperCollapsedSize + (wrapperExpandedWidth - wrapperCollapsedSize) * expansionProgress
                // Clamp to wrapperExpandedHeight so spring overshoot (expansionProgress > 1
                // on bouncy styles like InkDrop) never stretches the wrapper taller than
                // its measured target — the main cause of the "jumps really high" artifact.
                let wrapperCurrentHeight = min(
                    wrapperCollapsedSize + (wrapperExpandedHeight - wrapperCollapsedSize) * expansionProgress,
                    wrapperExpandedHeight
                )
                let wrapperCornerRadius = wrapperCollapsedSize / 2 + (20 - wrapperCollapsedSize / 2) * expansionProgress
                RoundedRectangle(cornerRadius: wrapperCornerRadius, style: .continuous)
                    .fill(Color.clear)
                    .frame(width: wrapperCurrentWidth, height: wrapperCurrentHeight)
                    .allowsHitTesting(false)

                // ── Unified morphing bubble — always present, never conditionally
                // inserted or removed. expansionProgress (0→1) drives the true shape
                // morph inside MorphingAgentBubbleView: frame size, corner radius,
                // card background/content opacity, and the per-style effect.
                // AgentOrbView lives here (not inside MorphingAgentBubbleView) so its
                // OrbStatusDot badge — which extends 3pt outside the orb frame — is
                // never clipped by MorphingAgentBubbleView's clipShape.
                ZStack(alignment: .topTrailing) {
                    MorphingAgentBubbleView(
                        session: session,
                        physicsState: physicsState,
                        expansionProgress: expansionProgress,
                        onDragStarted: onDragStarted,
                        onDragUpdated: onDragUpdated,
                        onDragEnded: onDragEnded,
                        onDismiss: onDismiss,
                        onRunSuggestedAction: onRunSuggestedAction,
                        onSubmitText: onSubmitText,
                        onVoiceToggle: onVoiceToggle
                    )

                    // Orb rendered outside MorphingAgentBubbleView's clipShape so the
                    // internal OrbStatusDot badge renders without clipping.
                    // Fades out as the card expands — at expansionProgress = 1 the orb
                    // is invisible and only the card content remains visible.
                    AgentOrbView(session: session)
                        .frame(width: effectiveOrbSize, height: effectiveOrbSize)
                        .opacity(Double(1 - expansionProgress))
                        .allowsHitTesting(false)
                }
                // compositingGroup() flattens MorphingAgentBubbleView + AgentOrbView into
                // a single bitmap so the drop shadow is computed from the correct alpha
                // channel — the orb shape at collapsed state, the card shape at expanded.
                // Without this, the shadow comes from the rectangular bounding box rather
                // than the actual circular or rounded-rect shape the user sees.
                .compositingGroup()
                .shadow(color: Color.black.opacity(0.45), radius: 8, y: 3)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Style-specific spring drives the shape morph (expansionProgress 0→1).
        .onChange(of: physicsState.isOrbHovered) { nowExpanded in
            withAnimation(styleSpecificExpandAnimation(for: bubbleSettingsManager.settings.style)) {
                expansionProgress = nowExpanded ? 1.0 : 0.0
            }
        }
        // Smoothly follow physicsState.measuredExpandedCardHeight changes so the outer
        // wrapper height never jumps abruptly mid-morph or after the morph settles.
        .onChange(of: physicsState.measuredExpandedCardHeight) { newHeight in
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                smoothedWrapperExpandedHeight = newHeight
            }
        }
    }

    // MARK: - Style-specific animation helpers

    /// Returns a spring animation whose character matches the selected bubble style's personality.
    /// Aurora feels dreamy and weightless; crystal snaps precisely; inkDrop bounces organically;
    /// spectrum pulses with energy; orbital glides smoothly; prismCard slides with authority.
    private func styleSpecificExpandAnimation(for style: BubbleStyle) -> Animation {
        switch style {
        case .aurora:
            // Slow, dreamy spring — aurora feels soft and weightless, like mist settling
            return .spring(response: 0.65, dampingFraction: 0.80)
        case .crystal:
            // Tight, snappy spring — crystal is precise and geometric, zero overshoot
            return .spring(response: 0.38, dampingFraction: 0.90)
        case .inkDrop:
            // Bouncy spring — ink drop has organic, fluid energy with natural overshoot
            return .spring(response: 0.55, dampingFraction: 0.62)
        case .spectrum:
            // Punchy but controlled — energetic response time with enough damping to
            // prevent the card from overshooting its bounds during expand/collapse.
            return .spring(response: 0.42, dampingFraction: 0.74)
        case .orbital:
            // Smooth and deliberate — like a satellite settling into a stable orbit
            return .spring(response: 0.58, dampingFraction: 0.84)
        case .prismCard:
            // Smooth, confident slide — card-like authority with minimal overshoot
            return .spring(response: 0.45, dampingFraction: 0.92)
        }
    }

}
