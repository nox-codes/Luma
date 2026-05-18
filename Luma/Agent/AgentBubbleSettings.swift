//
//  AgentBubbleSettings.swift
//  Luma
//
//  Data model and singleton manager for agent bubble visual appearance settings.
//  Each bubble style exposes its own specific set of customizable properties.
//  All values persist to UserDefaults. Active bubbles observe the manager and
//  update their style and physics in real time without requiring a restart.
//

import Combine
import Foundation
import SwiftUI

// MARK: - BubbleStyle

/// The 6 available visual styles for the floating agent bubble orb.
/// Each style has a distinct idle animation and collapsed appearance.
enum BubbleStyle: String, Codable, CaseIterable {
    case aurora
    case crystal
    case inkDrop
    case spectrum
    case orbital
    case prismCard

    /// Human-readable name shown in the style picker tile.
    var displayName: String {
        switch self {
        case .aurora:    return "Aurora"
        case .crystal:   return "Crystal"
        case .inkDrop:   return "Ink Drop"
        case .spectrum:  return "Spectrum"
        case .orbital:   return "Orbital"
        case .prismCard: return "Prism Card"
        }
    }

    /// Zero-padded ordinal label shown below the preview tile (e.g. "03").
    var ordinalLabel: String {
        switch self {
        case .aurora:    return "01"
        case .crystal:   return "02"
        case .inkDrop:   return "03"
        case .spectrum:  return "04"
        case .orbital:   return "05"
        case .prismCard: return "06"
        }
    }
}

// MARK: - AgentBubbleSettings

/// Persisted settings that control the bubble's visual style, physics, and per-style appearance.
/// Each style has its own block of properties — only the block matching the current style is
/// shown in the settings UI, so controls feel purposeful and specific rather than generic.
struct AgentBubbleSettings: Codable {

    // MARK: Shared across all styles

    /// Which bubble style to render (default: Ink Drop).
    var style: BubbleStyle = .inkDrop

    /// How many seconds to show the halted pill before auto-dismissing (1–8s).
    var pillDismissDelay: Double = 3.0

    /// Visual diameter of the bubble orb in points (48–88pt). Default: 64pt.
    var bubbleSize: Double = 64.0

    /// Overall orb opacity from fully transparent (0.0) to fully opaque (1.0). Default: 1.0.
    /// Applies to the entire orb including glows and effects so the bubble can be made
    /// translucent (frosted-glass feel) or left solid (default).
    var bubbleOpacity: Double = 1.0

    // MARK: Aurora-specific

    /// Seconds per full aurora sweep rotation at rest (lower = faster sweep).
    /// Automatically speeds up to 3.5s when working.
    var auroraRotationSpeed: Double = 8.0

    /// Ambient aurora glow opacity at rest (0.0 = dim, 1.0 = vivid).
    var auroraGlowIntensity: Double = 0.50

    // MARK: Crystal-specific

    /// Brightness of the LinearGradient fill inside the hex shape (0.0–1.0).
    var crystalInnerGlow: Double = 0.55

    /// Intensity of the top-left specular highlight on the crystal face (0.0–1.0).
    var crystalShimmer: Double = 0.30

    // MARK: InkDrop-specific

    /// Blob morph cycle duration in seconds while the agent is working (0.5–10s).
    var inkDropMorphSpeed: Double = 3.0

    /// How fast the blob morphs while idle (0.0 = very slow, 1.0 = same as working speed).
    var inkDropAggressionAtRest: Double = 0.18

    /// Outer glow halo intensity around the ink drop blob (0.0 = no glow, 1.0 = maximum).
    /// Working state always boosts glow above this floor for visual feedback.
    var inkDropGlowIntensity: Double = 0.45

    // MARK: Spectrum-specific

    /// Number of radial waveform bars surrounding the inner disc (8–36).
    /// Stored as Double for Slider compatibility — converted to Int at render time.
    var spectrumBarCount: Double = 20.0

    /// Speed multiplier applied to bar animation while idle (0.3–3.0).
    var spectrumAnimationSpeed: Double = 1.4

    /// Glow intensity of the inner disc and its outer shadow (0.0 = no glow, 1.0 = maximum).
    /// Default 0.30 — noticeably toned-down from the previous hardcoded 0.60/0.55 values.
    var spectrumGlowIntensity: Double = 0.30

    // MARK: Orbital-specific

    /// Glow intensity of the orbital core and its outer shadow (0.0 = no glow, 1.0 = maximum).
    var orbitalGlowIntensity: Double = 0.45

    /// Core orb diameter as a fraction of the total bubble size (0.40–0.85).
    /// At 0.72 the core fills 72% of the available diameter.
    var orbitalCoreSizeRatio: Double = 0.72

    /// Orbit ring radius as a multiple of the core's own radius (1.2–3.5).
    /// At 2.0 the ring sits twice as far from center as the core's edge.
    var orbitalOrbitRadiusMultiple: Double = 2.0

    /// Seconds per complete orbit revolution at rest (1.5–15.0).
    /// Automatically speeds up to 2.0s when working.
    var orbitalOrbitSpeedSeconds: Double = 6.0

    // MARK: PrismCard-specific

    /// Border glow pulse frequency in Hz while working (0.5–4.0).
    var prismBorderPulseRate: Double = 1.8

    /// Left accent strip glow intensity (0.3–1.0).
    var prismAccentGlow: Double = 0.80
}

// MARK: - AgentBubbleSettingsManager

/// Singleton that persists and publishes AgentBubbleSettings changes.
/// Views observe this manager and re-render immediately when settings change.
@MainActor
final class AgentBubbleSettingsManager: ObservableObject {

    static let shared = AgentBubbleSettingsManager()

    private static let userDefaultsKey = "luma.agentBubble.settings"

    @Published var settings: AgentBubbleSettings {
        didSet { persistSettings() }
    }

    private init() {
        if let savedData = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
           let decodedSettings = try? JSONDecoder().decode(AgentBubbleSettings.self, from: savedData) {
            self.settings = decodedSettings
        } else {
            self.settings = AgentBubbleSettings()
        }
    }

    private func persistSettings() {
        if let encodedSettings = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encodedSettings, forKey: Self.userDefaultsKey)
        }
    }
}
