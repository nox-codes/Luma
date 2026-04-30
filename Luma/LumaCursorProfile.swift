//
//  LumaCursorProfile.swift
//  leanring-buddy
//
//  Defines cursor states and a customizable cursor profile that controls
//  shape, color, and size per state. Persisted to Keychain.
//

import Foundation
import SwiftUI

// MARK: - Cursor State

/// The current behavioral state of the Luma cursor overlay.
/// Each state maps to a distinct visual appearance from the user's CursorProfile.
enum LumaCursorState: String, Codable, CaseIterable {
    case idle       // Default resting state
    case pointing   // Targeting a UI element during walkthrough
    case listening  // Voice input is active
    case processing // Agent is working autonomously
    case hover      // Cursor hovers a UI element

    var displayName: String {
        switch self {
        case .idle:       return "Idle"
        case .pointing:   return "Pointing"
        case .listening:  return "Listening"
        case .processing: return "Processing"
        case .hover:      return "Hover"
        }
    }
}

// MARK: - Cursor Shape

/// Available shapes for the cursor in each state.
enum CursorShape: String, Codable, CaseIterable, Identifiable {
    case teardrop
    case circle
    case roundedTriangle
    case diamond
    case cross
    case dot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .teardrop:        return "Teardrop"
        case .circle:          return "Circle"
        case .roundedTriangle: return "Triangle"
        case .diamond:         return "Diamond"
        case .cross:           return "Cross"
        case .dot:             return "Dot"
        }
    }

    /// SF Symbol name for the shape picker grid.
    var sfSymbolName: String {
        switch self {
        case .teardrop:        return "drop.fill"
        case .circle:          return "circle.fill"
        case .roundedTriangle: return "triangle.fill"
        case .diamond:         return "diamond.fill"
        case .cross:           return "plus"
        case .dot:             return "circle.fill"
        }
    }
}

// MARK: - Per-State Appearance

/// Visual configuration for a single cursor state.
struct CursorStateAppearance: Codable, Equatable {
    var shape: CursorShape
    var colorHex: String
    var size: CGFloat

    /// Converts colorHex to a SwiftUI Color.
    var color: Color {
        Color(hex: colorHex)
    }
}

// MARK: - Cursor Profile

/// Full cursor profile containing appearance settings for every state.
/// Persisted to Keychain under "luma.cursor.profile".
struct CursorProfile: Codable, Equatable {
    var idle: CursorStateAppearance
    var pointing: CursorStateAppearance
    var listening: CursorStateAppearance
    var processing: CursorStateAppearance

    /// Returns the appearance for a given cursor state.
    func appearance(for state: LumaCursorState) -> CursorStateAppearance {
        switch state {
        case .idle, .hover: return idle
        case .pointing:     return pointing
        case .listening:    return listening
        case .processing:   return processing
        }
    }

    /// Default profile matching Luma's current cursor behavior (blue teardrop).
    static let defaultProfile = CursorProfile(
        idle: CursorStateAppearance(
            shape: .teardrop,
            colorHex: "#0A84FF",
            size: 14
        ),
        pointing: CursorStateAppearance(
            shape: .roundedTriangle,
            colorHex: "#0A84FF",
            size: 32
        ),
        listening: CursorStateAppearance(
            shape: .circle,
            colorHex: "#30D158",
            size: 18
        ),
        processing: CursorStateAppearance(
            shape: .diamond,
            colorHex: "#FF9F0A",
            size: 20
        )
    )

    // MARK: - Keychain Persistence

    private static let keychainKey = "luma.cursor.profile"

    /// Loads the profile from Keychain, or returns the default if none is stored.
    static func loadFromKeychain() -> CursorProfile {
        guard let data = try? KeychainManager.load(key: keychainKey),
              let decoded = try? JSONDecoder().decode(CursorProfile.self, from: data) else {
            return .defaultProfile
        }
        return decoded
    }

    /// Persists the profile to Keychain.
    func saveToKeychain() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? KeychainManager.save(key: Self.keychainKey, data: data)
    }
}

// MARK: - Color Hex String Extension

extension Color {
    /// Returns the hex string representation of a Color (best-effort).
    var hexString: String {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else { return "#0A84FF" }
        let red   = Int(components.redComponent * 255)
        let green = Int(components.greenComponent * 255)
        let blue  = Int(components.blueComponent * 255)
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
