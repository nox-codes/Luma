//
//  LumaFloatingInputView.swift
//  Luma
//
//  The pill-shaped text input shown in the floating input bubble.
//  Shape: top-left corner is 0pt radius, all other corners 999pt (fully rounded).
//  This anchors the bubble visually to the orb above it.
//
//  Note: focus state is managed via a plain @Binding (not @FocusState.Binding)
//  because this view is hosted in an NSPanel (NSHostingView) rather than a
//  standard SwiftUI hierarchy. A local @FocusState is synced to the binding
//  via onChange so the window manager knows when to pause mouse following.
//

import SwiftUI

struct LumaFloatingInputView: View {

    @Binding var draft: String
    /// Called when the user presses Enter or taps the send button.
    var onSend: (String) -> Void
    /// Callback for focus state changes — used by the window manager to pause mouse following.
    var onFocusChanged: (Bool) -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            TextField("Ask Luma anything…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .focused($isTextFieldFocused)
                .tint(.white) // white text cursor
                .onSubmit { sendDraft() }

            if !draft.isEmpty {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(hex: "#141614"))
                        .frame(width: 28, height: 28)
                        .background(Color.white)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            // Top-left corner is square (0pt), all others fully rounded (999pt).
            // UnevenRoundedRectangle requires macOS 13+; Luma targets macOS 14.2+.
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 999,
                bottomTrailingRadius: 999,
                topTrailingRadius: 999,
                style: .continuous
            )
            .fill(Color(hex: "#141614"))
            .shadow(color: Color(hex: "#4caf50").opacity(0.08), radius: 16, x: 0, y: 0)
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 999,
                    bottomTrailingRadius: 999,
                    topTrailingRadius: 999,
                    style: .continuous
                )
                .stroke(LumaTheme.Colors.accent.opacity(0.25), lineWidth: 1)
            )
        )
        .preferredColorScheme(.dark)
        .onChange(of: isTextFieldFocused) { newValue in
            // Notify the window manager so it can pause/resume mouse following
            onFocusChanged(newValue)
        }
        .onAppear {
            // Auto-focus the text field when the view appears
            isTextFieldFocused = true
        }
    }

    private func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
    }
}
