//
//  CustomCursorManager.swift
//  leanring-buddy
//
//  Manages a custom NSCursor that changes per LumaCursorState based on the
//  user's CursorProfile (shape, color, size). Falls back to the "Luma-cursor"
//  asset when custom rendering isn't available. Persists the enabled preference
//  to UserDefaults.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class CustomCursorManager {

    // Shared singleton — one manager for the whole app lifetime.
    static let shared = CustomCursorManager()

    // MARK: - Constants

    /// UserDefaults key used to persist whether the custom cursor is enabled.
    private static let userDefaultsKeyForCustomCursorEnabled = "isCustomCursorEnabled"

    /// The hotspot for the Luma cursor is at the very top-left corner of the image.
    private static let cursorHotspot = CGPoint(x: 0, y: 0)

    // MARK: - Published State

    /// Whether the custom Luma cursor is currently enabled.
    @Published var isCustomCursorEnabled: Bool

    /// The current cursor state, which determines shape/color/size from the profile.
    @Published private(set) var currentState: LumaCursorState = .idle

    // MARK: - Private State

    /// Fallback cursor loaded from the "Luma-cursor" image asset.
    private var fallbackCursor: NSCursor?

    /// The user's cursor profile loaded from Keychain.
    private var cursorProfile: CursorProfile

    /// Cache of generated NSCursor instances per state to avoid re-rendering on every call.
    private var cachedCursorsPerState: [LumaCursorState: NSCursor] = [:]

    // MARK: - Initialization

    private init() {
        let hasStoredPreference = UserDefaults.standard.object(forKey: Self.userDefaultsKeyForCustomCursorEnabled) != nil
        if hasStoredPreference {
            self.isCustomCursorEnabled = UserDefaults.standard.bool(forKey: Self.userDefaultsKeyForCustomCursorEnabled)
        } else {
            self.isCustomCursorEnabled = true
            UserDefaults.standard.set(true, forKey: Self.userDefaultsKeyForCustomCursorEnabled)
        }

        self.cursorProfile = CursorProfile.loadFromKeychain()

        if let cursorImage = NSImage(named: "Luma-cursor") {
            self.fallbackCursor = NSCursor(image: cursorImage, hotSpot: Self.cursorHotspot)
        } else {
            LumaLogger.log("[CustomCursorManager] WARNING: 'Luma-cursor' image asset not found. Using rendered shapes only.")
            self.fallbackCursor = nil
        }

        rebuildCursorCache()
    }

    // MARK: - Public API: State Transitions

    /// Switches the active cursor appearance to match the given state.
    /// Called by VoiceEngine, WalkthroughEngine, AgentEngine, etc.
    func setState(_ state: LumaCursorState) {
        currentState = state
        activateCustomCursor()
    }

    /// Activates the custom cursor for the current state.
    func activateCustomCursor() {
        guard isCustomCursorEnabled else { return }

        if let stateCursor = cachedCursorsPerState[currentState] {
            stateCursor.set()
        } else if let fallbackCursor = fallbackCursor {
            fallbackCursor.set()
        }
    }

    /// Restores the system arrow cursor.
    func restoreSystemCursor() {
        NSCursor.arrow.set()
    }

    /// Toggles the custom cursor on/off, persists, and applies immediately.
    func setCustomCursorEnabled(_ enabled: Bool) {
        isCustomCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.userDefaultsKeyForCustomCursorEnabled)

        if enabled {
            activateCustomCursor()
        } else {
            restoreSystemCursor()
        }
    }

    /// Reloads the cursor profile from Keychain and rebuilds the cursor cache.
    /// Called by the Cursor settings tab when the user changes appearance settings.
    func reloadCursorProfile() {
        cursorProfile = CursorProfile.loadFromKeychain()
        rebuildCursorCache()
        if isCustomCursorEnabled {
            activateCustomCursor()
        }
    }

    // MARK: - Cursor Image Rendering

    /// Rebuilds the cached NSCursor for every state from the current cursor profile.
    private func rebuildCursorCache() {
        cachedCursorsPerState = [:]
        for state in LumaCursorState.allCases {
            let appearance = cursorProfile.appearance(for: state)
            if let cursorImage = renderCursorImage(for: appearance) {
                // Hotspot at center for symmetric shapes, top-left for teardrop
                let hotspot: CGPoint
                if appearance.shape == .teardrop {
                    hotspot = CGPoint(x: appearance.size / 2, y: 0)
                } else {
                    hotspot = CGPoint(x: appearance.size / 2, y: appearance.size / 2)
                }
                cachedCursorsPerState[state] = NSCursor(image: cursorImage, hotSpot: hotspot)
            }
        }
    }

    /// Renders an NSImage of the cursor shape at the given size and color.
    private func renderCursorImage(for appearance: CursorStateAppearance) -> NSImage? {
        let size = NSSize(width: appearance.size + 4, height: appearance.size + 4)
        let nsColor = NSColor(appearance.color)

        let image = NSImage(size: size, flipped: false) { drawRect in
            let insetRect = drawRect.insetBy(dx: 2, dy: 2)

            // Draw glow/shadow
            let shadow = NSShadow()
            shadow.shadowColor = nsColor.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = .zero
            shadow.set()

            nsColor.setFill()

            switch appearance.shape {
            case .circle, .dot:
                let dotSize = appearance.shape == .dot
                    ? NSRect(
                        x: insetRect.midX - insetRect.width * 0.25,
                        y: insetRect.midY - insetRect.height * 0.25,
                        width: insetRect.width * 0.5,
                        height: insetRect.height * 0.5
                    )
                    : insetRect
                NSBezierPath(ovalIn: dotSize).fill()

            case .teardrop:
                let path = NSBezierPath()
                // Teardrop: point at top, round at bottom
                path.move(to: NSPoint(x: insetRect.midX, y: insetRect.maxY))
                path.curve(
                    to: NSPoint(x: insetRect.minX, y: insetRect.midY - insetRect.height * 0.1),
                    controlPoint1: NSPoint(x: insetRect.midX - insetRect.width * 0.05, y: insetRect.maxY - insetRect.height * 0.15),
                    controlPoint2: NSPoint(x: insetRect.minX, y: insetRect.maxY - insetRect.height * 0.3)
                )
                path.curve(
                    to: NSPoint(x: insetRect.maxX, y: insetRect.midY - insetRect.height * 0.1),
                    controlPoint1: NSPoint(x: insetRect.minX, y: insetRect.minY),
                    controlPoint2: NSPoint(x: insetRect.maxX, y: insetRect.minY)
                )
                path.curve(
                    to: NSPoint(x: insetRect.midX, y: insetRect.maxY),
                    controlPoint1: NSPoint(x: insetRect.maxX, y: insetRect.maxY - insetRect.height * 0.3),
                    controlPoint2: NSPoint(x: insetRect.midX + insetRect.width * 0.05, y: insetRect.maxY - insetRect.height * 0.15)
                )
                path.close()
                path.fill()

            case .roundedTriangle:
                let path = NSBezierPath()
                path.move(to: NSPoint(x: insetRect.midX, y: insetRect.maxY))
                path.line(to: NSPoint(x: insetRect.minX, y: insetRect.minY))
                path.line(to: NSPoint(x: insetRect.maxX, y: insetRect.minY))
                path.close()
                path.fill()

            case .diamond:
                let path = NSBezierPath()
                path.move(to: NSPoint(x: insetRect.midX, y: insetRect.maxY))
                path.line(to: NSPoint(x: insetRect.minX, y: insetRect.midY))
                path.line(to: NSPoint(x: insetRect.midX, y: insetRect.minY))
                path.line(to: NSPoint(x: insetRect.maxX, y: insetRect.midY))
                path.close()
                path.fill()

            case .cross:
                let armWidth = insetRect.width * 0.3
                let verticalArm = NSRect(
                    x: insetRect.midX - armWidth / 2,
                    y: insetRect.minY,
                    width: armWidth,
                    height: insetRect.height
                )
                let horizontalArm = NSRect(
                    x: insetRect.minX,
                    y: insetRect.midY - armWidth / 2,
                    width: insetRect.width,
                    height: armWidth
                )
                NSBezierPath(roundedRect: verticalArm, xRadius: armWidth / 2, yRadius: armWidth / 2).fill()
                NSBezierPath(roundedRect: horizontalArm, xRadius: armWidth / 2, yRadius: armWidth / 2).fill()
            }

            return true
        }

        return image
    }
}
