//
//  LumaFloatingInputView.swift
//  Luma
//
//  Three visual styles for the floating ⌘⌘/^^ text input bubble.
//  Style is driven by FloatingInputStyleManager.shared.currentStyle so the
//  window manager can observe it and resize the panel without recreating it.
//
//  Focus note: @FocusState is managed locally and synced to onFocusChanged
//  via onChange because @FocusState.Binding cannot cross an NSHostingView boundary.
//

import SwiftUI

struct LumaFloatingInputView: View {

    @Binding var draft: String
    var onSend: (String) -> Void
    var onFocusChanged: (Bool) -> Void

    @FocusState private var isTextFieldFocused: Bool
    @StateObject private var styleManager = FloatingInputStyleManager.shared

    var body: some View {
        Group {
            switch styleManager.currentStyle {
            case .pillClean:
                PillCleanFloatingInput(
                    draft: $draft,
                    isTextFieldFocused: $isTextFieldFocused,
                    onSend: { sendDraft() }
                )
            case .widerCard:
                WiderCardFloatingInput(
                    draft: $draft,
                    isTextFieldFocused: $isTextFieldFocused,
                    onSend: { sendDraft() }
                )
            case .cursorAnchored:
                CursorAnchoredFloatingInput(
                    draft: $draft,
                    isTextFieldFocused: $isTextFieldFocused,
                    onSend: { sendDraft() }
                )
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: isTextFieldFocused) { newValue in
            onFocusChanged(newValue)
        }
        .onAppear {
            // Slight delay so the NSPanel is fully key before activating @FocusState
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isTextFieldFocused = true
            }
        }
    }

    private func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
    }
}

// MARK: - Style A: Clean Pill

/// Fully rounded pill with green orb dot on the left. 440 × 52 pt.
private struct PillCleanFloatingInput: View {

    @Binding var draft: String
    var isTextFieldFocused: FocusState<Bool>.Binding
    var onSend: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Green orb dot — pulses to indicate Luma is listening
            ZStack {
                Circle()
                    .fill(Color(hex: "#4caf50").opacity(0.18))
                    .frame(width: 24, height: 24)
                Circle()
                    .fill(Color(hex: "#4caf50"))
                    .frame(width: 8, height: 8)
                    .shadow(color: Color(hex: "#4caf50").opacity(0.7), radius: 4, x: 0, y: 0)
            }
            .overlay(
                Circle()
                    .stroke(Color(hex: "#4caf50").opacity(0.35), lineWidth: 1)
                    .frame(width: 24, height: 24)
            )

            TextField("Ask Luma anything…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .focused(isTextFieldFocused)
                .tint(.white)
                .onSubmit { onSend() }

            if !draft.isEmpty {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(hex: "#141614"))
                        .frame(width: 34, height: 34)
                        .background(Color.white)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(width: 440, height: 52)
        .background(
            Capsule()
                .fill(Color(hex: "#141614"))
                .shadow(color: Color(hex: "#4caf50").opacity(0.12), radius: 20, x: 0, y: 0)
                .overlay(
                    Capsule()
                        .stroke(Color(hex: "#4caf50").opacity(0.28), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.15), value: draft.isEmpty)
    }
}

// MARK: - Style B: Wider Frosted Card

/// Wider frosted card with animated gradient border. 500 × 56 pt.
private struct WiderCardFloatingInput: View {

    @Binding var draft: String
    var isTextFieldFocused: FocusState<Bool>.Binding
    var onSend: () -> Void

    @State private var gradientRotation: Double = 0

    var body: some View {
        HStack(spacing: 0) {
            // Keyboard shortcut badge
            Text("⌘⌘")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: "#555D58"))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(hex: "#1A1C1A"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color(hex: "#2E322E"), lineWidth: 1)
                        )
                )
                .padding(.leading, 16)

            // Vertical divider
            Rectangle()
                .fill(Color(hex: "#2E322E"))
                .frame(width: 1, height: 22)
                .padding(.horizontal, 12)

            TextField("Ask Luma anything…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .focused(isTextFieldFocused)
                .tint(.white)
                .onSubmit { onSend() }

            if !draft.isEmpty {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 36, height: 36)
                        .background(Color(hex: "#4caf50"))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .transition(.scale.combined(with: .opacity))
                .padding(.trailing, 10)
            } else {
                Spacer()
                    .frame(width: 16)
            }
        }
        .frame(width: 500, height: 56)
        .background(Color(hex: "#0E1210"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color(hex: "#4caf50").opacity(0.6),
                            Color(hex: "#4caf50").opacity(0.05),
                            Color(hex: "#4caf50").opacity(0.3),
                            Color(hex: "#4caf50").opacity(0.6),
                        ]),
                        center: .center,
                        angle: .degrees(gradientRotation)
                    ),
                    lineWidth: 1.5
                )
        )
        .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 8)
        .animation(.easeInOut(duration: 0.15), value: draft.isEmpty)
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                gradientRotation = 360
            }
        }
    }
}

// MARK: - Style C: Cursor Anchored

/// Cursor-anchored shape with green tab above input. 420 × 66 pt total.
private struct CursorAnchoredFloatingInput: View {

    @Binding var draft: String
    var isTextFieldFocused: FocusState<Bool>.Binding
    var onSend: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Green anchor tab — sits flush above the input, aligned to leading edge
            HStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(hex: "#4caf50"))
                    .frame(width: 42, height: 14)
                    .shadow(color: Color(hex: "#4caf50").opacity(0.5), radius: 6, x: 0, y: -2)
                Spacer()
            }
            .padding(.leading, 16)

            // Input row — top-left corner is square (anchored to tab), others rounded
            HStack(spacing: 10) {
                TextField("Ask Luma anything…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .focused(isTextFieldFocused)
                    .tint(.white)
                    .onSubmit { onSend() }

                if !draft.isEmpty {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Color(hex: "#141614"))
                            .frame(width: 34, height: 34)
                            .background(Color.white)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Text("esc")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(hex: "#3A3F3A"))
                }
            }
            .padding(.horizontal, 16)
            .frame(width: 420, height: 52)
            .background(Color(hex: "#141614"))
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 16,
                    topTrailingRadius: 16,
                    style: .continuous
                )
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 16,
                    topTrailingRadius: 16,
                    style: .continuous
                )
                .stroke(Color(hex: "#4caf50").opacity(0.3), lineWidth: 1)
            )
            .shadow(color: Color(hex: "#4caf50").opacity(0.08), radius: 20, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 6)
        }
        .animation(.easeInOut(duration: 0.15), value: draft.isEmpty)
    }
}
