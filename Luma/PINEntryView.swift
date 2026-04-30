import SwiftUI

/// A 6-digit PIN entry view with numeric keypad.
/// Used both for entering an existing PIN (settings access guard)
/// and for setting a new PIN during onboarding/settings.
struct PINEntryView: View {

    enum Mode {
        case verify    // Check existing PIN — calls onSuccess/onFailure
        case set       // Set a new PIN — shows confirm step
    }

    let mode: Mode
    let title: String
    var onSuccess: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    @StateObject private var pinManager = PINManager.shared
    @State private var enteredDigits: String = ""
    @State private var confirmDigits: String = ""
    @State private var isConfirmingStep: Bool = false
    @State private var shakeAmount: CGFloat = 0
    @State private var showIncorrectError: Bool = false
    @State private var showMismatchError: Bool = false

    var body: some View {
        VStack(spacing: DS.Spacing.xxxl) {
            // Title
            Text(isConfirmingStep ? "Confirm PIN" : title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            // PIN dots display
            pinDotsView
                .modifier(ShakeEffect(shakeAmount: shakeAmount))

            // Error messages
            if showIncorrectError {
                Text("Incorrect PIN")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.destructive)
            }
            if showMismatchError {
                Text("PINs don't match")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.destructive)
            }

            // Numeric keypad
            numericKeypad

            // Cancel button
            if let onCancel = onCancel {
                Button("Cancel", action: onCancel)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
            }
        }
        .padding(DS.Spacing.xxxl)
    }

    // MARK: - Subviews

    private var pinDotsView: some View {
        HStack(spacing: DS.Spacing.lg) {
            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .fill(currentDigits.count > index ? DS.Colors.accent : DS.Colors.textTertiary)
                    .frame(width: 12, height: 12)
            }
        }
    }

    private var currentDigits: String {
        isConfirmingStep ? confirmDigits : enteredDigits
    }

    private var numericKeypad: some View {
        VStack(spacing: DS.Spacing.sm) {
            ForEach([[1,2,3],[4,5,6],[7,8,9],[0]], id: \.self) { row in
                HStack(spacing: DS.Spacing.lg) {
                    ForEach(row, id: \.self) { digit in
                        PINKeypadButton(digit: digit) {
                            appendDigit(String(digit))
                        }
                    }
                }
            }
            // Delete button row
            HStack {
                Spacer()
                Button(action: deleteLastDigit) {
                    Image(systemName: "delete.backward")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(width: 60, height: 60)
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
    }

    // MARK: - Actions

    private func appendDigit(_ digit: String) {
        showIncorrectError = false
        showMismatchError = false

        if isConfirmingStep {
            guard confirmDigits.count < 6 else { return }
            confirmDigits += digit
            if confirmDigits.count == 6 { handleConfirmComplete() }
        } else {
            guard enteredDigits.count < 6 else { return }
            enteredDigits += digit
            if enteredDigits.count == 6 { handleEntryComplete() }
        }
    }

    private func deleteLastDigit() {
        if isConfirmingStep {
            confirmDigits = String(confirmDigits.dropLast())
        } else {
            enteredDigits = String(enteredDigits.dropLast())
        }
    }

    private func handleEntryComplete() {
        switch mode {
        case .verify:
            if pinManager.validatePIN(enteredDigits) {
                onSuccess?()
            } else {
                triggerShake()
                showIncorrectError = true
                enteredDigits = ""
            }
        case .set:
            isConfirmingStep = true
        }
    }

    private func handleConfirmComplete() {
        guard enteredDigits == confirmDigits else {
            triggerShake()
            showMismatchError = true
            confirmDigits = ""
            return
        }
        do {
            try pinManager.setPIN(enteredDigits)
            onSuccess?()
        } catch {
            showMismatchError = true
            confirmDigits = ""
        }
    }

    private func triggerShake() {
        withAnimation(.default) { shakeAmount += 1 }
    }
}

// MARK: - Supporting Views

private struct PINKeypadButton: View {
    let digit: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text("\(digit)")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: 60, height: 60)
                .background(
                    Circle()
                        .fill(isHovering ? DS.Colors.surface2 : DS.Colors.surface1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Shake Animation

struct ShakeEffect: GeometryEffect {
    var shakeAmount: CGFloat

    var animatableData: CGFloat {
        get { shakeAmount }
        set { shakeAmount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = 8 * sin(shakeAmount * .pi * 4)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}
