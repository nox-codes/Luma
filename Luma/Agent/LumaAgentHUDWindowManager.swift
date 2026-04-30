//
//  LumaAgentHUDWindowManager.swift
//  leanring-buddy
//
//  Floating agent dashboard window — shows transcript, agent team strip,
//  response cards, and a composer. Ported from OpenClicky's CodexHUDWindowManager.
//

import AppKit
import SwiftUI

private enum LumaHUDLayout {
    static let width: CGFloat = 594
    static let height: CGFloat = 452
    static let minimumWidth: CGFloat = 594
    static let minimumHeight: CGFloat = 452
}

@MainActor
final class LumaAgentHUDWindowManager {
    private var panel: NSPanel?

    func show(
        companionManager: CompanionManager,
        openMemory: @escaping () -> Void,
        prepareVoiceFollowUp: @escaping () -> Void
    ) {
        if panel == nil {
            panel = makePanel(
                companionManager: companionManager,
                openMemory: openMemory,
                prepareVoiceFollowUp: prepareVoiceFollowUp
            )
        } else if let hostingView = panel?.contentView as? NSHostingView<LumaHUDView> {
            hostingView.rootView = LumaHUDView(
                companionManager: companionManager,
                openMemory: openMemory,
                prepareVoiceFollowUp: prepareVoiceFollowUp
            ) { [weak self] in
                self?.hide()
            }
        }
        enforceMinimumSize()
        positionPanel()
        panel?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func destroy() {
        panel?.close()
        panel = nil
    }

    private func makePanel(
        companionManager: CompanionManager,
        openMemory: @escaping () -> Void,
        prepareVoiceFollowUp: @escaping () -> Void
    ) -> NSPanel {
        let hostingView = NSHostingView(
            rootView: LumaHUDView(
                companionManager: companionManager,
                openMemory: openMemory,
                prepareVoiceFollowUp: prepareVoiceFollowUp
            ) { [weak self] in
                self?.hide()
            }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: LumaHUDLayout.width, height: LumaHUDLayout.height),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Luma"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: LumaHUDLayout.minimumWidth, height: LumaHUDLayout.minimumHeight)
        panel.contentMinSize = NSSize(width: LumaHUDLayout.minimumWidth, height: LumaHUDLayout.minimumHeight)
        panel.contentView = hostingView
        return panel
    }

    private func enforceMinimumSize() {
        guard let panel else { return }
        let currentFrame = panel.frame
        let constrainedWidth = max(currentFrame.width, LumaHUDLayout.minimumWidth)
        let constrainedHeight = max(currentFrame.height, LumaHUDLayout.minimumHeight)

        guard constrainedWidth != currentFrame.width || constrainedHeight != currentFrame.height else { return }

        panel.setFrame(
            NSRect(
                x: currentFrame.origin.x,
                y: currentFrame.maxY - constrainedHeight,
                width: constrainedWidth,
                height: constrainedHeight
            ),
            display: true
        )
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let horizontalCenter = frame.midX - size.width / 2
        let bottomWithMargin = frame.minY + 24
        panel.setFrameOrigin(NSPoint(x: horizontalCenter, y: bottomWithMargin))
    }
}

// MARK: - HUD View

private struct LumaHUDView: View {
    @ObservedObject var companionManager: CompanionManager
    @AppStorage(LumaAccentTheme.userDefaultsKey) private var selectedAccentThemeID = LumaAccentTheme.blue.rawValue
    var openMemory: () -> Void
    var prepareVoiceFollowUp: () -> Void
    var close: () -> Void
    @State private var prompt = ""

    private var activeSession: AgentSession {
        companionManager.activeAgentSession
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            agentTeamStrip
            if let card = activeSession.latestResponseCard {
                responseCardCompactView(card: card)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            Rectangle()
                .fill(DS.Colors.borderSubtle.opacity(0.7))
                .frame(height: 0.5)
            transcript
            Rectangle()
                .fill(DS.Colors.borderSubtle.opacity(0.7))
                .frame(height: 0.5)
            composer
        }
        .frame(
            minWidth: LumaHUDLayout.minimumWidth,
            idealWidth: LumaHUDLayout.width,
            maxWidth: .infinity,
            minHeight: LumaHUDLayout.minimumHeight,
            idealHeight: LumaHUDLayout.height,
            maxHeight: .infinity
        )
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.067, green: 0.075, blue: 0.071).opacity(0.98))
                .shadow(color: .black.opacity(0.34), radius: 22, y: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .animation(.none, value: selectedAccentThemeID)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "cursorarrow.motionlines.click")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(DS.Colors.accentText.opacity(0.12)))

            Text("Luma")
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            iconButton(systemName: "books.vertical", helpText: "Memory", action: openMemory)
            iconButton(systemName: "bolt.fill", helpText: "Warm up", action: { Task { await activeSession.warmUp() } })
            iconButton(systemName: "xmark", helpText: "Close", action: close)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Agent Team Strip

    private var agentTeamStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(companionManager.agentSessions) { agentSession in
                    HUDFloatingAgentButton(
                        session: agentSession,
                        isSelected: agentSession.id == companionManager.activeAgentSessionID,
                        select: {
                            companionManager.selectAgentSession(agentSession.id)
                        }
                    )
                }

                Button(action: {
                    companionManager.createAndSelectNewAgentSession()
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                        .overlay(
                            Circle()
                                .stroke(DS.Colors.borderSubtle.opacity(0.8), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)                .accessibilityLabel("Add agent")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 7)
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if activeSession.entries.isEmpty {
                        emptyState
                    } else {
                        ForEach(activeSession.entries) { entry in
                            transcriptRow(entry)
                                .id(entry.id)
                        }
                    }
                }
                .padding(10)
            }
            .onChange(of: activeSession.entries.count) {
                if let lastEntryID = activeSession.entries.last?.id {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(lastEntryID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask Luma to inspect, edit, explain, or automate something.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Agent tasks use the detected runtime (Claude Code CLI or API fallback) and the model selected in settings.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 0.5)
        )
    }

    private func transcriptRow(_ entry: AgentTranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(transcriptRoleLabel(for: entry.role))
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(transcriptRoleColor(for: entry.role))
            Text(entry.text)
                .font(.system(size: 11, design: entry.role == .command ? .monospaced : .default))
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(transcriptRoleBackground(for: entry.role))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 0.5)
        )
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Agent HUD...", text: $prompt, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 0.5)
                )
                .onSubmit(sendPrompt)

            HUDRunButton(canSend: canSend, action: sendPrompt)
        }
        .padding(10)
    }

    // MARK: - Response Card

    @ViewBuilder
    private func responseCardCompactView(card: ResponseCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RESPONSE")
                .font(.system(size: 9, weight: .heavy))
                .foregroundColor(DS.Colors.textTertiary)
                .kerning(0.45)

            Text(card.truncatedText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !card.suggestedActions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(card.suggestedActions, id: \.self) { action in
                        Button(action) {
                            activeSession.dismissLatestResponseCard()
                            companionManager.submitAgentPromptFromUI(action)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.accentText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DS.Colors.accent.opacity(0.12))
                        .clipShape(Capsule())                    }

                    Spacer()

                    Button(action: {
                        activeSession.dismissLatestResponseCard()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    .buttonStyle(.plain)
                    Button(action: {
                        activeSession.dismissLatestResponseCard()
                        close()
                        prepareVoiceFollowUp()
                    }) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)                }
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

    // MARK: - Helpers

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendPrompt() {
        guard canSend else { return }
        let submitted = prompt
        prompt = ""
        companionManager.submitAgentPromptFromUI(submitted)
    }

    private func iconButton(systemName: String, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(
            DSIconButtonStyle(
                size: 28,
                isDestructiveOnHover: systemName == "xmark",
                tooltipText: helpText,
                tooltipAlignment: .trailing
            )
        )
    }

    private func transcriptRoleLabel(for role: TranscriptRole) -> String {
        switch role {
        case .user: return "YOU"
        case .assistant: return "LUMA"
        case .system: return "SYSTEM"
        case .command: return "COMMAND"
        case .plan: return "PLAN"
        }
    }

    private func transcriptRoleColor(for role: TranscriptRole) -> Color {
        switch role {
        case .user: return DS.Colors.accentText
        case .assistant: return DS.Colors.textSecondary
        case .system: return DS.Colors.destructiveText
        case .command: return Color.yellow.opacity(0.9)
        case .plan: return Color.purple.opacity(0.9)
        }
    }

    private func transcriptRoleBackground(for role: TranscriptRole) -> Color {
        switch role {
        case .user: return DS.Colors.accentSubtle
        case .assistant: return Color.white.opacity(0.05)
        case .system: return DS.Colors.destructive.opacity(0.12)
        case .command: return Color.yellow.opacity(0.08)
        case .plan: return Color.purple.opacity(0.10)
        }
    }
}

// MARK: - Floating Agent Button

private struct HUDFloatingAgentButton: View {
    @ObservedObject var session: AgentSession
    var isSelected: Bool
    var select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(backgroundColor)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Circle()
                            .stroke(borderColor, lineWidth: isSelected ? 1.4 : 0.8)
                    )
                    .shadow(
                        color: session.accentTheme.cursorColor.opacity(isSelected ? 0.34 : 0.10),
                        radius: isSelected ? 7 : 3,
                        x: 0,
                        y: 0
                    )

                Image(systemName: "cursorarrow")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(session.accentTheme.cursorColor)
                    .rotationEffect(.degrees(-18))
                    .offset(x: -1, y: 1)

                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 1))
                    .offset(x: 1, y: -1)
            }
            .frame(width: 34, height: 34)
            .scaleEffect(isHovered ? 1.04 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(session.title)")
        .help(session.title)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return session.accentTheme.cursorColor.opacity(0.18)
        }
        return Color.white.opacity(isHovered ? 0.09 : 0.06)
    }

    private var borderColor: Color {
        if isSelected {
            return session.accentTheme.cursorColor.opacity(0.82)
        }
        return DS.Colors.borderSubtle.opacity(isHovered ? 0.9 : 0.55)
    }

    private var statusColor: Color {
        switch session.status {
        case .starting, .running:
            return Color.yellow
        case .ready:
            return DS.Colors.success
        case .failed:
            return DS.Colors.destructiveText
        case .stopped:
            return DS.Colors.textTertiary
        }
    }
}

// MARK: - Run Button

private struct HUDRunButton: View {
    var canSend: Bool
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Run")
                    .font(.system(size: 10, weight: .heavy))
            }
            .foregroundColor(canSend ? DS.Colors.textOnAccent : DS.Colors.disabledText)
            .frame(width: 76, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .scaleEffect(isHovered && canSend ? 1.015 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundColor: Color {
        guard canSend else {
            return DS.Colors.disabledBackground
        }
        return isHovered ? DS.Colors.accentHover : DS.Colors.accent
    }

    private var borderColor: Color {
        guard canSend else {
            return DS.Colors.borderSubtle.opacity(0.45)
        }
        return Color.white.opacity(isHovered ? 0.22 : 0.10)
    }
}
