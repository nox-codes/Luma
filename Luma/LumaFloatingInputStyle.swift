//
//  LumaFloatingInputStyle.swift
//  Luma
//
//  Three visual styles for the floating ⌘⌘/^^ text input bubble.
//  The active style is persisted to UserDefaults and read by
//  LumaFloatingInputWindowManager to size the panel correctly.
//

import Combine
import Foundation

/// Identifies which visual style the floating input bubble uses.
/// Raw value is the UserDefaults-persisted string.
enum FloatingInputStyle: String, CaseIterable {
    /// Fully-rounded pill with a green orb dot on the left. (440 × 52 pt)
    case pillClean = "pillClean"
    /// Wider frosted card with an animated gradient border. (500 × 56 pt)
    case widerCard = "widerCard"
    /// Original cursor-anchored shape with a green tab above. (420 × 52 + 14 pt tab)
    case cursorAnchored = "cursorAnchored"

    var displayName: String {
        switch self {
        case .pillClean:      return "Clean Pill"
        case .widerCard:      return "Frosted Card"
        case .cursorAnchored: return "Cursor Anchored"
        }
    }

    var description: String {
        switch self {
        case .pillClean:      return "Fully rounded, green orb dot — 440 × 52 pt"
        case .widerCard:      return "Wider card with gradient border — 500 × 56 pt"
        case .cursorAnchored: return "Green tab anchors to cursor — 420 × 52 pt"
        }
    }

    /// The panel width in points for this style.
    var panelWidth: CGFloat {
        switch self {
        case .pillClean:      return 440
        case .widerCard:      return 500
        case .cursorAnchored: return 420
        }
    }

    /// The panel height in points for this style.
    /// For cursorAnchored, includes the 14pt tab above the input.
    var panelHeight: CGFloat {
        switch self {
        case .pillClean:      return 52
        case .widerCard:      return 56
        case .cursorAnchored: return 66  // 52pt input + 14pt tab
        }
    }
}

/// Manages the user's floating input style preference.
/// Persists to UserDefaults. Observed by the settings picker for live updates.
@MainActor
final class FloatingInputStyleManager: ObservableObject {

    static let shared = FloatingInputStyleManager()

    private let userDefaultsKey = "floatingInputStyle"

    @Published var currentStyle: FloatingInputStyle {
        didSet {
            UserDefaults.standard.set(currentStyle.rawValue, forKey: userDefaultsKey)
            LumaLogger.log("[FloatingInput] Style changed to \(currentStyle.rawValue)")
        }
    }

    private init() {
        let savedRaw = UserDefaults.standard.string(forKey: "floatingInputStyle") ?? ""
        currentStyle = FloatingInputStyle(rawValue: savedRaw) ?? .pillClean
    }
}
