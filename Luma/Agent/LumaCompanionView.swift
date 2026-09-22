//
//  LumaCompanionView.swift
//  Luma
//
//  One character renderer shared by the dock, workspace, menu-bar panel, and
//  Character settings preview.
//

import SwiftUI

enum CompanionRenderSize {
    case compact
    case regular
    case large

    var points: CGFloat {
        switch self {
        case .compact: return 52
        case .regular: return 84
        case .large: return 148
        }
    }
}

struct LumaCompanionView: View {
    let state: LumaCompanionState
    let appearance: CompanionAppearance
    let size: CompanionRenderSize
    var onActivate: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    init(
        state: LumaCompanionState,
        appearance: CompanionAppearance,
        size: CompanionRenderSize = .regular,
        onActivate: (() -> Void)? = nil
    ) {
        self.state = state
        self.appearance = appearance.bounded
        self.size = size
        self.onActivate = onActivate
    }

    var body: some View {
        Group {
            if let onActivate {
                Button(action: onActivate) {
                    character
                }
                .buttonStyle(.plain)
            } else {
                character
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .help(state.explanation ?? state.shortLabel)
    }

    private var character: some View {
        ZStack(alignment: .topTrailing) {
            characterBody

            if let accessorySymbol {
                Image(systemName: accessorySymbol)
                    .font(.system(size: size.points * 0.15, weight: .bold))
                    .foregroundStyle(accentColor)
                    .frame(width: size.points * 0.27, height: size.points * 0.27)
                    .background(Circle().fill(appearance.palette.face.swiftUIColor))
                    .overlay(Circle().stroke(accentColor.opacity(0.75), lineWidth: 1.5))
                    .offset(x: size.points * 0.03, y: -size.points * 0.01)
            }
        }
        .frame(width: size.points * 1.22, height: size.points * 1.18)
        .scaleEffect(appearance.scale)
        .opacity(appearance.opacity)
        .animation(animation, value: state)
    }

    private var characterBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size.points * 0.3, style: .continuous)
                .fill(appearance.palette.body.swiftUIColor)
                .overlay(
                    RoundedRectangle(cornerRadius: size.points * 0.3, style: .continuous)
                        .stroke(accentColor.opacity(0.78), lineWidth: max(1, size.points * 0.022))
                )
                .shadow(color: accentColor.opacity(0.28), radius: size.points * 0.18)

            VStack(spacing: size.points * 0.09) {
                HStack(spacing: size.points * 0.12) {
                    eye
                    eye
                }

                mouth
            }
            .offset(y: size.points * 0.02)

            if case .working(let progress) = state, let progress {
                Circle()
                    .trim(from: 0, to: progress.fraction)
                    .stroke(accentColor, style: StrokeStyle(lineWidth: max(2, size.points * 0.035), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(size.points * 0.045)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size.points, height: size.points)
        .rotationEffect(bodyRotation)
        .scaleEffect(bodyScale)
    }

    private var eye: some View {
        Capsule(style: .continuous)
            .fill(appearance.palette.face.swiftUIColor)
            .frame(width: size.points * 0.105, height: eyeHeight)
            .offset(y: eyeOffset)
    }

    private var mouth: some View {
        Group {
            switch state {
            case .success:
                Capsule(style: .continuous)
                    .fill(appearance.palette.success.swiftUIColor)
                    .frame(width: size.points * 0.22, height: size.points * 0.06)
            case .failed, .needsAttention:
                Capsule(style: .continuous)
                    .fill(accentColor)
                    .frame(width: size.points * 0.20, height: size.points * 0.055)
                    .rotationEffect(.degrees(-12))
            default:
                Capsule(style: .continuous)
                    .fill(accentColor.opacity(0.72))
                    .frame(width: size.points * 0.12, height: size.points * 0.045)
            }
        }
    }

    private var eyeHeight: CGFloat {
        switch state {
        case .listening: return size.points * 0.18
        case .thinking: return size.points * 0.08
        default: return size.points * 0.13
        }
    }

    private var eyeOffset: CGFloat {
        switch state {
        case .thinking: return -size.points * 0.04
        case .listening: return size.points * 0.01
        default: return 0
        }
    }

    private var bodyScale: CGFloat {
        switch state {
        case .listening: return 1.03
        case .working: return 1.02
        case .success: return 1.05
        default: return 1
        }
    }

    private var bodyRotation: Angle {
        switch state {
        case .thinking: return .degrees(-4)
        case .needsAttention: return .degrees(3)
        default: return .zero
        }
    }

    private var accentColor: Color {
        switch state {
        case .success: return appearance.palette.success.swiftUIColor
        case .failed: return appearance.palette.failure.swiftUIColor
        case .needsAttention, .paused: return appearance.palette.warning.swiftUIColor
        default: return appearance.palette.accent.swiftUIColor
        }
    }

    private var accessorySymbol: String? {
        switch state {
        case .listening: return "waveform"
        case .thinking: return "ellipsis"
        case .working: return "sparkles"
        case .paused: return "pause.fill"
        case .success: return "checkmark"
        case .failed: return "xmark"
        case .needsAttention: return "exclamationmark"
        case .idle: return nil
        }
    }

    private var accessibilityValue: String {
        if let explanation = state.explanation, !explanation.isEmpty {
            return explanation
        }
        if case .working(let progress) = state, let progress {
            return "\(Int(progress.fraction * 100)) percent complete. \(progress.label ?? "Working on your task.")"
        }
        return state.shortLabel
    }

    private var animation: Animation? {
        guard !accessibilityReduceMotion, appearance.motion.intensity > 0 else { return nil }
        let duration = max(0.35, 1.25 / appearance.motion.speed)
        return .easeInOut(duration: duration).repeatForever(autoreverses: true)
    }
}

struct LumaCompanionBadge: View {
    @ObservedObject var system: LumaCompanionSystem
    let size: CompanionRenderSize

    init(system: LumaCompanionSystem, size: CompanionRenderSize = .compact) {
        self.system = system
        self.size = size
    }

    var body: some View {
        HStack(spacing: 9) {
            LumaCompanionView(
                state: system.state,
                appearance: system.appearance,
                size: size
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Luma")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(system.state.shortLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.Colors.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(system.state.accessibilityLabel)
        .accessibilityValue(system.stateExplanation)
    }
}
