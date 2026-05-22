//
//  LumaFloatingInputView.swift
//  Luma
//
//  Three visual styles for the floating text input bubble.
//  Style is driven by FloatingInputStyleManager.shared.currentStyle.
//
//  All styles use LumaDirectTextField (NSViewRepresentable wrapping NSTextField)
//  instead of SwiftUI TextField — SwiftUI's .focused() modifier fights AppKit's
//  makeFirstResponder and silently yanks focus away. Direct NSTextField ownership
//  means the window manager's makeFirstResponder lands cleanly every time.
//
//  The AI response renders inside the same visual container as the input field.
//  The pill style morphs from a true capsule (cornerRadius 100, compact) to a
//  rounded rectangle (cornerRadius 26, expanded) as the response slides in.
//  Card and anchored styles expand downward without morphing corner radius.
//
//  Draft text is owned by FloatingPanelState.shared (@Published) so the send
//  button updates reactively as the user types — no manual binding needed.
//

import AppKit
import SwiftUI

struct LumaFloatingInputView: View {

    var onSend: (String) -> Void

    @StateObject private var styleManager = FloatingInputStyleManager.shared
    @ObservedObject private var panelState = FloatingPanelState.shared

    var body: some View {
        switch styleManager.currentStyle {
        case .pillClean:
            PillCleanFloatingInput(onSend: { sendDraft() })
        case .widerCard:
            WiderCardFloatingInput(onSend: { sendDraft() })
        case .cursorAnchored:
            CursorAnchoredFloatingInput(onSend: { sendDraft() })
        }
    }

    private func sendDraft() {
        let trimmed = panelState.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
    }
}

// MARK: - Shared Response Area

/// Renders the streaming AI response below the input row.
/// Shared by all three style containers. Uses FloatingPanelState.shared.displayResponse
/// (POINT tags stripped) and shows animated streaming dots while isStreaming is true.
private struct FloatingResponseArea: View {

    @ObservedObject private var panelState = FloatingPanelState.shared

    var body: some View {
        VStack(spacing: 0) {
            // Thin divider separating input from response
            Rectangle()
                .fill(Color(hex: "#2E322E"))
                .frame(height: 1)

            // 200pt scrollable response region
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        responseContent
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .id("bottom")

                        // Streaming dots — visible while the AI is still generating
                        if panelState.isStreaming {
                            HStack(spacing: 4) {
                                ForEach(0..<3, id: \.self) { dotIndex in
                                    StreamingDot(delaySeconds: Double(dotIndex) * 0.2)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        }
                    }
                }
                .frame(height: 200)
                .onChange(of: panelState.displayResponse) { _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
        // Total height: 1pt divider + 200pt scroll = 201pt (matches responseAreaHeight in the window manager)
    }

    @ViewBuilder
    private var responseContent: some View {
        // Attempt inline markdown rendering; fall back to plain text on parse failure
        if let attributed = try? AttributedString(
            markdown: panelState.displayResponse,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            Text(attributed)
                .foregroundColor(Color.white.opacity(0.88))
                .font(.system(size: 13))
                .lineSpacing(3)
                .textSelection(.enabled)
        } else {
            Text(panelState.displayResponse)
                .foregroundColor(Color.white.opacity(0.88))
                .font(.system(size: 13))
                .lineSpacing(3)
                .textSelection(.enabled)
        }
    }
}

// Three dots that pulse while the AI is streaming a response
private struct StreamingDot: View {
    let delaySeconds: Double
    @State private var opacity: Double = 0.3

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.7))
            .frame(width: 4, height: 4)
            .opacity(opacity)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.6)
                    .repeatForever(autoreverses: true)
                    .delay(delaySeconds)
                ) {
                    opacity = 1.0
                }
            }
    }
}

// MARK: - AppKit-backed text field

/// NSViewRepresentable wrapping NSTextField directly.
/// SwiftUI's TextField with .focused() actively fights AppKit's makeFirstResponder —
/// this bypasses the SwiftUI focus system entirely so keyboard events always arrive.
struct LumaDirectTextField: NSViewRepresentable {

    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.4)]
        )
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = .white
        field.font = .systemFont(ofSize: 14)
        field.focusRingType = .none
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Only write back if value changed to avoid cursor-jump on every keystroke
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self._text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            return false
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            // Set insertion cursor color to white to match the dark theme
            if let textView = (obj.object as? NSTextField)?.currentEditor() as? NSTextView {
                textView.insertionPointColor = .white
            }
        }
    }
}

// MARK: - Style A: Clean Pill

/// Fully rounded pill with green orb dot on the left. 440 × 52 pt input row.
/// Morphs from a true capsule (cornerRadius 100) when the response area is hidden to a
/// rounded rectangle (cornerRadius 26) when the response streams in — one unified
/// background shape that grows downward without changing the input row's appearance.
private struct PillCleanFloatingInput: View {

    var onSend: () -> Void

    @ObservedObject private var panelState = FloatingPanelState.shared

    var body: some View {
        VStack(spacing: 0) {
            // Input row
            HStack(spacing: 10) {
                // White square indicator — shows Luma is ready
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 6, height: 6)

                LumaDirectTextField(
                    text: $panelState.draft,
                    placeholder: "Ask Luma anything…",
                    onSubmit: onSend
                )

                // Send button — dims when draft is empty, fills solid white when ready
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(hex: "#141614"))
                        .frame(width: 30, height: 30)
                        .background(panelState.draft.isEmpty ? Color.white.opacity(0.25) : Color.white)
                        .clipShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(panelState.draft.isEmpty)
                .onHover { isHovering in
                    if isHovering && !panelState.draft.isEmpty { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .animation(.easeInOut(duration: 0.15), value: panelState.draft.isEmpty)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(width: 440, height: 52)

            // Response area — slides in below the input inside the same container
            if !panelState.response.isEmpty {
                FloatingResponseArea()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            Rectangle()
                .fill(Color(hex: "#141614"))
                .overlay(
                    Rectangle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.4), radius: 20, x: 0, y: 8)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: panelState.response.isEmpty)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Style B: Wider Frosted Card

/// Wider frosted card with animated gradient border. 500 × 56 pt input row.
/// The response area expands below the input inside the same rounded-rect container.
private struct WiderCardFloatingInput: View {

    var onSend: () -> Void

    @ObservedObject private var panelState = FloatingPanelState.shared
    @State private var gradientRotation: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            // Input row
            HStack(spacing: 0) {
                // Keyboard shortcut badge
                Text("⌘⌘")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(hex: "#555D58"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Rectangle()
                            .fill(Color(hex: "#1A1C1A"))
                            .overlay(
                                Rectangle()
                                    .stroke(Color(hex: "#2E322E"), lineWidth: 1)
                            )
                    )
                    .padding(.leading, 16)

                // Vertical divider
                Rectangle()
                    .fill(Color(hex: "#2E322E"))
                    .frame(width: 1, height: 22)
                    .padding(.horizontal, 12)

                LumaDirectTextField(
                    text: $panelState.draft,
                    placeholder: "Ask Luma anything…",
                    onSubmit: onSend
                )

                // Send button — dims when draft is empty, fills green when ready
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(panelState.draft.isEmpty ? Color.black.opacity(0.4) : .black)
                        .frame(width: 34, height: 34)
                        .background(panelState.draft.isEmpty ? Color.white.opacity(0.25) : Color.white)
                        .clipShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(panelState.draft.isEmpty)
                .onHover { isHovering in
                    if isHovering && !panelState.draft.isEmpty { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .animation(.easeInOut(duration: 0.15), value: panelState.draft.isEmpty)
                .padding(.trailing, 10)
            }
            .frame(width: 500, height: 56)

            // Response area — expands below the input inside the same card container
            if !panelState.response.isEmpty {
                FloatingResponseArea()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(hex: "#0E0F0E"))
        .overlay(
            Rectangle()
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 8)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: panelState.response.isEmpty)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Style C: Cursor Anchored

/// Cursor-anchored shape with green tab above input. 420 × 52 pt input + 14 pt tab.
/// The response area expands below the input inside the same anchored body.
private struct CursorAnchoredFloatingInput: View {

    var onSend: () -> Void

    @ObservedObject private var panelState = FloatingPanelState.shared

    var body: some View {
        VStack(spacing: 0) {
            // White anchor tab — sits flush above the input body
            HStack {
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 42, height: 4)
                Spacer()
            }
            .padding(.leading, 16)

            // Anchored body: input row + optional response area, clipped together
            VStack(spacing: 0) {
                // Input row
                HStack(spacing: 10) {
                    LumaDirectTextField(
                        text: $panelState.draft,
                        placeholder: "Ask Luma anything…",
                        onSubmit: onSend
                    )

                    // Send button — dims when draft is empty, fills solid white when ready
                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Color(hex: "#141614"))
                            .frame(width: 30, height: 30)
                            .background(panelState.draft.isEmpty ? Color.white.opacity(0.25) : Color.white)
                            .clipShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(panelState.draft.isEmpty)
                    .onHover { isHovering in
                        if isHovering && !panelState.draft.isEmpty { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    .animation(.easeInOut(duration: 0.15), value: panelState.draft.isEmpty)
                }
                .padding(.horizontal, 16)
                .frame(width: 420, height: 52)

                // Response area — inside the anchored body, slides in below the input
                if !panelState.response.isEmpty {
                    FloatingResponseArea()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(Color(hex: "#141614"))
            .overlay(
                Rectangle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 6)
            .animation(.spring(response: 0.45, dampingFraction: 0.78), value: panelState.response.isEmpty)
        }
        .preferredColorScheme(.dark)
    }
}
