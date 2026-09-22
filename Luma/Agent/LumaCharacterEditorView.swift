//
//  LumaCharacterEditorView.swift
//  Luma
//
//  The replacement for the old six-style bubble picker.
//

import SwiftUI

struct LumaCharacterEditorView: View {
    @ObservedObject var system: LumaCompanionSystem
    @State private var previewState: CharacterPreviewState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            previewSection
            presetSection
            stateSection
            motionSection
            presenceSection
            resetSection
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
    }

    private var previewSection: some View {
        HStack(alignment: .center, spacing: 22) {
            LumaCompanionView(
                state: previewState.companionState,
                appearance: system.appearance,
                size: .large
            )
            .frame(width: 170, height: 170)
            .background(DS.Colors.surface1)
            .overlay(Rectangle().stroke(DS.Colors.borderSubtle, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 8) {
                Text("Your Luma character")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("One identity across the workspace, menu bar, and desktop presence.")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(system.stateExplanation)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(DS.Colors.surface1)
        .overlay(Rectangle().stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
    }

    private var presetSection: some View {
        characterSection(title: "Character", subtitle: "Choose a starting personality. Every preset keeps the same Luma identity.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(CompanionPreset.allCases) { preset in
                    Button {
                        var next = system.appearance
                        next.preset = preset
                        next.palette = palette(for: preset)
                        system.setAppearance(next)
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(palette(for: preset).accent.swiftUIColor)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().stroke(DS.Colors.textPrimary.opacity(0.35), lineWidth: 0.5))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DS.Colors.textPrimary)
                                Text(preset.description)
                                    .font(.system(size: 10))
                                    .foregroundStyle(DS.Colors.textTertiary)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 0)

                            if system.appearance.preset == preset {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(DS.Colors.accentText)
                            }
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(system.appearance.preset == preset ? DS.Colors.accentSubtle : DS.Colors.surface2)
                        .overlay(Rectangle().stroke(system.appearance.preset == preset ? DS.Colors.accentText.opacity(0.65) : DS.Colors.borderSubtle, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(system.appearance.preset == preset ? [.isSelected] : [])
                }
            }
        }
    }

    private var stateSection: some View {
        characterSection(title: "Preview state", subtitle: "Check how Luma communicates work without relying on text alone.") {
            Picker("Preview state", selection: $previewState) {
                ForEach(CharacterPreviewState.allCases) { state in
                    Text(state.displayName).tag(state)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var motionSection: some View {
        characterSection(title: "Presence", subtitle: "Keep motion bounded and readable during active work.") {
            VStack(spacing: 14) {
                editorSlider(
                    title: "Scale",
                    value: scaleBinding,
                    range: 0.75...1.5,
                    valueLabel: String(format: "%.2fx", system.appearance.scale)
                )
                editorSlider(
                    title: "Motion",
                    value: motionBinding,
                    range: 0...1,
                    valueLabel: String(format: "%.0f%%", system.appearance.motion.intensity * 100)
                )
            }
        }
    }

    private var presenceSection: some View {
        characterSection(title: "Desktop location", subtitle: "Choose where the compact presence should prefer to appear.") {
            Picker("Desktop location", selection: presenceBinding) {
                ForEach(CompanionPresence.allCases) { presence in
                    Text(presence.displayName).tag(presence)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240, alignment: .leading)
        }
    }

    private var resetSection: some View {
        HStack {
            Text("Appearance changes are saved immediately.")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textTertiary)

            Spacer()

            Button {
                system.resetAppearance()
            } label: {
                Label("Reset character", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reset character appearance")
        }
    }

    private func characterSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private func editorSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        valueLabel: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(width: 72, alignment: .leading)

            Slider(value: value, in: range)
                .tint(DS.Colors.accent)

            Text(valueLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.Colors.textTertiary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private var scaleBinding: Binding<Double> {
        Binding(
            get: { system.appearance.scale },
            set: { newValue in
                var next = system.appearance
                next.scale = newValue
                system.setAppearance(next)
            }
        )
    }

    private var motionBinding: Binding<Double> {
        Binding(
            get: { system.appearance.motion.intensity },
            set: { newValue in
                var next = system.appearance
                next.motion.intensity = newValue
                system.setAppearance(next)
            }
        )
    }

    private var presenceBinding: Binding<CompanionPresence> {
        Binding(
            get: { system.appearance.presence },
            set: { newValue in
                var next = system.appearance
                next.presence = newValue
                system.setAppearance(next)
            }
        )
    }

    private func palette(for preset: CompanionPreset) -> CompanionPalette {
        switch preset {
        case .default: return .default
        case .monochrome: return .monochrome
        case .focus: return .focus
        case .teaching: return .teaching
        }
    }
}

private enum CharacterPreviewState: String, CaseIterable, Identifiable {
    case idle
    case listening
    case working
    case success
    case attention

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .working: return "Working"
        case .success: return "Success"
        case .attention: return "Attention"
        }
    }

    var companionState: LumaCompanionState {
        switch self {
        case .idle: return .idle
        case .listening: return .listening
        case .working: return .working(progress: CompanionProgress(completed: 2, total: 5, label: "Inspecting"))
        case .success: return .success
        case .attention: return .needsAttention(message: "A decision is needed to continue.")
        }
    }
}
