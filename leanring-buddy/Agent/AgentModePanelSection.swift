//
//  AgentModePanelSection.swift
//  leanring-buddy
//
//  Inline agent controls that appear in the companion panel when agent mode is enabled.
//  Ported from OpenClicky's CodexAgentModePanelSection.
//

import SwiftUI

struct AgentModePanelSection: View {
    @ObservedObject var session: AgentSession
    var responseCard: ResponseCard?
    var submitAgentPrompt: (String) -> Void
    var dismissResponseCard: () -> Void
    var runSuggestedNextAction: (String) -> Void
    var showSettings: () -> Void
    /// Whether this agent is currently recording voice via toggle.
    var isRecordingVoice: Bool = false
    /// Called when the user taps the voice button to start/stop recording.
    var onVoiceToggle: (() -> Void)?

    @State private var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status header row
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.55), radius: 4)

                Text("Ask Agent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                Text(session.status.displayLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            // Summary text
            Text(summaryText)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Prompt input
            TextField("Ask Luma to do something...", text: $prompt, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
                .onSubmit(runPrompt)

            // Error display
            if let error = visibleInlineErrorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.destructiveText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Response (single display — latest response only)
            if let card = responseCard {
                responseCardCompactView(card: card)
            } else if shouldShowInlineAgentResponse {
                inlineAgentResponse
            }

            // Send + Voice buttons
            HStack(spacing: 8) {
                Spacer()

                // Voice toggle button — click to start recording, click again to stop
                Button(action: { onVoiceToggle?() }) {
                    Image(systemName: isRecordingVoice ? "mic.fill" : "mic")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)                .foregroundColor(isRecordingVoice ? DS.Colors.destructiveText : DS.Colors.textPrimary)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(isRecordingVoice ? DS.Colors.destructive.opacity(0.2) : Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(isRecordingVoice ? DS.Colors.destructive.opacity(0.3) : Color.white.opacity(0.08), lineWidth: 0.5)
                )

                // Send button
                Button(action: runPrompt) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 42, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.textOnAccent)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(canRun ? DS.Colors.accent : DS.Colors.accent.opacity(0.35))
                )
                .disabled(!canRun)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Computed Properties

    private var canRun: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowInlineAgentResponse: Bool {
        inlineAgentResponseText != nil || session.status == .starting || session.status == .running
    }

    private var inlineAgentResponseText: String? {
        guard let raw = session.entries.last(where: { entry in
            switch entry.role {
            case .assistant, .plan, .command, .system:
                return !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .user:
                return false
            }
        })?.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // Strip control tags and normalize newlines so text flows as one line,
        // wrapping only at the panel's max width.
        let normalized = LumaWriteEngine.normalizeForDisplay(raw)
        return normalized.isEmpty ? nil : normalized
    }

    private var inlineAgentResponse: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(inlineAgentResponseLabel)
                .font(.system(size: 9, weight: .heavy))
                .foregroundColor(DS.Colors.textTertiary)
                .kerning(0.45)

            // Use RichMarkdownView when a response is ready so tables, code blocks,
            // lists, headers, and blockquotes all render correctly. Falls back to a
            // plain status placeholder while the agent is still working.
            if let responseText = inlineAgentResponseText {
                ScrollView(.vertical, showsIndicators: false) {
                    RichMarkdownView(text: responseText, accentColor: session.glowColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            } else {
                Text(inlineAgentPlaceholder)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 0.5)
        )
    }

    private var inlineAgentResponseLabel: String {
        switch session.status {
        case .starting: return "STARTING"
        case .running: return "WORKING"
        case .failed: return "NEEDS ATTENTION"
        case .ready: return "AGENT RESPONSE"
        case .stopped: return "IDLE"
        }
    }

    private var inlineAgentPlaceholder: String {
        switch session.status {
        case .starting: return "Starting the agent..."
        case .running: return "Working through the task..."
        case .failed: return "Open the dashboard for details."
        case .ready: return "Ready."
        case .stopped: return "Agent is idle."
        }
    }

    private var summaryText: String {
        if visibleInlineErrorMessage != nil {
            return "Agent needs attention. Open the dashboard for details."
        }
        return "Ask for coding, research, writing, or app tasks."
    }

    private var visibleInlineErrorMessage: String? {
        guard let errorMessage = session.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !errorMessage.isEmpty else {
            return nil
        }
        return errorMessage
    }

    private var statusColor: Color {
        switch session.status {
        case .ready: return DS.Colors.success
        case .running: return DS.Colors.accent
        case .starting: return DS.Colors.warning
        case .failed: return DS.Colors.destructive
        case .stopped: return DS.Colors.textTertiary
        }
    }

    // MARK: - Actions

    private func runPrompt() {
        guard canRun else { return }
        let submitted = prompt
        prompt = ""
        submitAgentPrompt(submitted)
    }

    // MARK: - Response Card

    @ViewBuilder
    private func responseCardCompactView(card: ResponseCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RESPONSE")
                .font(.system(size: 9, weight: .heavy))
                .foregroundColor(DS.Colors.textTertiary)
                .kerning(0.45)

            // Full rich markdown rendering — same pipeline as the agent bubble dock card.
            // Tables, code blocks, headers, lists, and blockquotes all render correctly here.
            ScrollView(.vertical, showsIndicators: false) {
                RichMarkdownView(text: card.rawText, accentColor: session.glowColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)

            if !card.suggestedActions.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(card.suggestedActions, id: \.self) { action in
                        Button(action: { runSuggestedNextAction(action) }) {
                            Text(action)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(DS.Colors.accentText)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .background(DS.Colors.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(DS.Colors.accent.opacity(0.35), lineWidth: 1)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 0.5)
        )
    }
}
