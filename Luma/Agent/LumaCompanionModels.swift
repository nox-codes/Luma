//
//  LumaCompanionModels.swift
//  Luma
//
//  Shared presentation contracts for the Luma character and its state-aware
//  desktop presence. These values deliberately do not know how an agent acts.
//

import SwiftUI

enum LumaCompanionState: Equatable {
    case idle
    case listening
    case thinking
    case working(progress: CompanionProgress?)
    case paused(reason: String?)
    case success
    case failed(message: String?)
    case needsAttention(message: String?)

    var accessibilityLabel: String {
        switch self {
        case .idle: return "Luma is ready"
        case .listening: return "Luma is listening"
        case .thinking: return "Luma is thinking"
        case .working: return "Luma is working"
        case .paused: return "Luma is paused"
        case .success: return "Luma completed the task"
        case .failed: return "Luma encountered an error"
        case .needsAttention: return "Luma needs your attention"
        }
    }

    var shortLabel: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .working: return "Working"
        case .paused: return "Paused"
        case .success: return "Complete"
        case .failed: return "Failed"
        case .needsAttention: return "Attention"
        }
    }

    var explanation: String? {
        switch self {
        case .paused(let reason), .failed(let reason), .needsAttention(let reason):
            return reason
        default:
            return nil
        }
    }
}

struct CompanionProgress: Codable, Equatable {
    let completed: Int
    let total: Int
    let label: String?

    init(completed: Int, total: Int, label: String? = nil) {
        self.completed = completed
        self.total = total
        self.label = label
    }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

enum LumaCompanionEvent: Equatable {
    case idle
    case listening
    case thinking
    case working(CompanionProgress?)
    case paused(reason: String?)
    case success
    case failed(message: String?)
    case needsAttention(message: String?)
}

enum LumaCompanionReducer {
    static func reduce(_ state: LumaCompanionState, event: LumaCompanionEvent) -> LumaCompanionState {
        switch event {
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .working(let progress): return .working(progress: progress)
        case .paused(let reason): return .paused(reason: reason)
        case .success: return .success
        case .failed(let message): return .failed(message: message)
        case .needsAttention(let message): return .needsAttention(message: message)
        }
    }
}

enum CompanionPreset: String, Codable, CaseIterable, Identifiable {
    case `default`
    case monochrome
    case focus
    case teaching

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default: return "Luma"
        case .monochrome: return "Quiet"
        case .focus: return "Focus"
        case .teaching: return "Teaching"
        }
    }

    var description: String {
        switch self {
        case .default: return "The balanced Luma character."
        case .monochrome: return "A low-distraction presence for deep work."
        case .focus: return "Sharper status contrast for active tasks."
        case .teaching: return "A warmer expression for guided learning."
        }
    }
}

struct CompanionColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    static let white = CompanionColor(red: 0.96, green: 0.97, blue: 0.99)
    static let black = CompanionColor(red: 0.04, green: 0.05, blue: 0.07)
    static let blue = CompanionColor(red: 0.28, green: 0.60, blue: 1.0)
    static let mint = CompanionColor(red: 0.31, green: 0.91, blue: 0.70)
    static let amber = CompanionColor(red: 1.0, green: 0.70, blue: 0.25)
    static let red = CompanionColor(red: 1.0, green: 0.36, blue: 0.40)
}

struct CompanionPalette: Codable, Equatable {
    var body: CompanionColor
    var face: CompanionColor
    var accent: CompanionColor
    var success: CompanionColor
    var warning: CompanionColor
    var failure: CompanionColor

    static let `default` = CompanionPalette(
        body: .white,
        face: .black,
        accent: .blue,
        success: .mint,
        warning: .amber,
        failure: .red
    )

    static let monochrome = CompanionPalette(
        body: CompanionColor(red: 0.78, green: 0.80, blue: 0.84),
        face: .black,
        accent: CompanionColor(red: 0.70, green: 0.73, blue: 0.78),
        success: CompanionColor(red: 0.72, green: 0.86, blue: 0.78),
        warning: CompanionColor(red: 0.90, green: 0.83, blue: 0.64),
        failure: CompanionColor(red: 0.92, green: 0.68, blue: 0.70)
    )

    static let focus = CompanionPalette(
        body: CompanionColor(red: 0.87, green: 0.93, blue: 1.0),
        face: .black,
        accent: .blue,
        success: .mint,
        warning: .amber,
        failure: .red
    )

    static let teaching = CompanionPalette(
        body: CompanionColor(red: 1.0, green: 0.91, blue: 0.76),
        face: .black,
        accent: CompanionColor(red: 0.94, green: 0.48, blue: 0.28),
        success: .mint,
        warning: .amber,
        failure: .red
    )
}

struct CompanionMotion: Codable, Equatable {
    var intensity: Double = 0.65
    var speed: Double = 1.0

    var bounded: CompanionMotion {
        CompanionMotion(
            intensity: min(max(intensity, 0), 1),
            speed: min(max(speed, 0.5), 2)
        )
    }
}

enum CompanionPresence: String, Codable, CaseIterable, Identifiable {
    case cursorSide
    case topRight
    case bottomRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cursorSide: return "Near cursor"
        case .topRight: return "Top right"
        case .bottomRight: return "Bottom right"
        }
    }
}

struct CompanionAppearance: Codable, Equatable {
    var preset: CompanionPreset
    var palette: CompanionPalette
    var motion: CompanionMotion
    var scale: Double
    var opacity: Double
    var presence: CompanionPresence

    static let `default` = CompanionAppearance(
        preset: .default,
        palette: .default,
        motion: CompanionMotion(),
        scale: 1,
        opacity: 1,
        presence: .cursorSide
    )

    var bounded: CompanionAppearance {
        var copy = self
        copy.scale = min(max(scale, 0.75), 1.5)
        copy.opacity = min(max(opacity, 0), 1)
        copy.motion = motion.bounded
        return copy
    }

    static func fromLegacy(styleRawValue: String, bubbleSize: Double, opacity: Double) -> CompanionAppearance {
        let preset: CompanionPreset
        let palette: CompanionPalette
        let motionIntensity: Double

        switch styleRawValue {
        case "crystal":
            preset = .monochrome
            palette = .monochrome
            motionIntensity = 0.35
        case "spectrum", "orbital":
            preset = .focus
            palette = .focus
            motionIntensity = 0.70
        case "prismCard":
            preset = .teaching
            palette = .teaching
            motionIntensity = 0.55
        default:
            preset = .default
            palette = .default
            motionIntensity = 0.65
        }

        return CompanionAppearance(
            preset: preset,
            palette: palette,
            motion: CompanionMotion(intensity: motionIntensity, speed: 1),
            scale: bubbleSize / 64,
            opacity: opacity,
            presence: .cursorSide
        ).bounded
    }
}

@MainActor
final class LumaCompanionSystem: ObservableObject {
    private static let appearanceKey = "luma.companion.appearance"
    private let defaults: UserDefaults

    @Published private(set) var state: LumaCompanionState = .idle
    @Published private(set) var activeSessionID: UUID?
    @Published var appearance: CompanionAppearance {
        didSet {
            let boundedAppearance = appearance.bounded
            if appearance != boundedAppearance {
                appearance = boundedAppearance
            }
            persistAppearance()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.appearanceKey),
           let savedAppearance = try? JSONDecoder().decode(CompanionAppearance.self, from: data) {
            self.appearance = savedAppearance.bounded
        } else if let data = defaults.data(forKey: "luma.agentBubble.settings"),
                  let legacySettings = try? JSONDecoder().decode(AgentBubbleSettings.self, from: data) {
            self.appearance = CompanionAppearance.fromLegacy(
                styleRawValue: legacySettings.style.rawValue,
                bubbleSize: legacySettings.bubbleSize,
                opacity: legacySettings.bubbleOpacity
            )
        } else {
            self.appearance = .default
        }
    }

    var stateExplanation: String {
        switch state {
        case .idle: return "Ready when you are."
        case .listening: return "Listening for your request."
        case .thinking: return "Working out the next step."
        case .working(let progress):
            guard let progress else { return "Working on your task." }
            return progress.label ?? "\(Int(progress.fraction * 100))% complete"
        case .paused(let reason): return reason ?? "Paused until you resume."
        case .success: return "Task completed successfully."
        case .failed(let message): return message ?? "The task could not be completed."
        case .needsAttention(let message): return message ?? "A decision is needed to continue."
        }
    }

    func send(_ event: LumaCompanionEvent, sessionID: UUID? = nil) {
        state = LumaCompanionReducer.reduce(state, event: event)
        if sessionID != nil {
            activeSessionID = sessionID
        }
    }

    func setActiveSession(_ sessionID: UUID?) {
        activeSessionID = sessionID
    }

    func setAppearance(_ appearance: CompanionAppearance) {
        self.appearance = appearance.bounded
    }

    func resetAppearance() {
        appearance = .default
    }

    private func persistAppearance() {
        guard let data = try? JSONEncoder().encode(appearance.bounded) else { return }
        defaults.set(data, forKey: Self.appearanceKey)
    }
}
