//
//  LumaWorkspaceView.swift
//  Luma
//
//  Persistent workspace surface inspired by the current HeyClicky interaction
//  model: conversation rail, transcript, task progress, response actions, and
//  a composer. It deliberately reuses AgentSession instead of creating a
//  second conversation runtime.
//

import AppKit
import SwiftUI

struct LumaWorkspaceView: View {
    @ObservedObject var companionManager: CompanionManager
    var onClose: () -> Void

    @State private var selectedSessionID: UUID?
    @State private var searchQuery = ""

    private var visibleSessions: [AgentSession] {
        let normalizedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return companionManager.agentSessions }

        return companionManager.agentSessions.filter { session in
            session.title.lowercased().contains(normalizedQuery)
                || (session.latestActivitySummary?.lowercased().contains(normalizedQuery) ?? false)
        }
    }

    private var selectedSession: AgentSession? {
        let preferredSessionID = selectedSessionID ?? companionManager.activeAgentSessionID
        guard let preferredSessionID else { return companionManager.agentSessions.first }
        return companionManager.agentSessions.first(where: { $0.id == preferredSessionID })
            ?? companionManager.agentSessions.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)

            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(width: 1)

            if let selectedSession {
                workspaceColumn(for: selectedSession)
            } else {
                emptyWorkspaceState
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
        .onAppear {
            selectedSessionID = selectedSession?.id
        }
        .onChange(of: companionManager.activeAgentSessionID) { newSessionID in
            guard selectedSessionID == nil else { return }
            selectedSessionID = newSessionID
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                LumaCompanionView(
                    state: companionManager.companionSystem.state,
                    appearance: companionManager.companionSystem.appearance,
                    size: .compact
                )
                .scaleEffect(0.42)
                .frame(width: 28, height: 28)

                Text("Luma")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                workspaceIconButton(
                    systemName: "square.and.pencil",
                    helpText: "New conversation",
                    action: createNewSession
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)

                TextField("Search conversations", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Rectangle().fill(DS.Colors.surface2))
            .overlay(Rectangle().stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            Text("CONVERSATIONS")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
                .tracking(0.7)
                .padding(.horizontal, 14)
                .padding(.bottom, 7)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(visibleSessions) { session in
                        WorkspaceSessionRow(
                            session: session,
                            isSelected: session.id == selectedSession?.id,
                            onSelect: {
                                selectedSessionID = session.id
                                companionManager.selectAgentSession(session.id)
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }

            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 1)
                .padding(.top, 10)

            HStack(spacing: 4) {
                workspaceFooterButton(systemName: "clock", helpText: "Conversation history") {
                    LumaHistoryWindowManager.shared.showHistoryWindow()
                }
                workspaceFooterButton(systemName: "brain", helpText: "Memory") {
                    LumaMemoryWindowManager.shared.showMemoryWindow()
                }
                workspaceFooterButton(systemName: "gearshape", helpText: "Settings") {
                    LumaSettingsWindowManager.shared.showSettingsWindow(companionManager: companionManager)
                }

                Spacer()

                Text("\(companionManager.agentSessions.count) active")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(DS.Colors.surface1)
    }

    // MARK: - Main Workspace

    private func workspaceColumn(for session: AgentSession) -> some View {
        VStack(spacing: 0) {
            workspaceHeader(for: session)

            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 1)

            WorkspaceTranscriptView(session: session)

            if let responseCard = session.latestResponseCard,
               !responseCard.suggestedActions.isEmpty {
                suggestedActions(responseCard.suggestedActions, session: session)
            }

            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 1)

            WorkspaceComposerView(
                session: session,
                companionManager: companionManager
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.background)
    }

    private func workspaceHeader(for session: AgentSession) -> some View {
        HStack(spacing: 10) {
            LumaCompanionView(
                state: companionManager.companionSystem.state,
                appearance: companionManager.companionSystem.appearance,
                size: .compact
            )
            .scaleEffect(0.46)
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Rectangle()
                        .fill(statusColor(for: session))
                        .frame(width: 6, height: 6)
                    Text(session.status.displayLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            Text(session.model)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)

            if session.status == .running || session.status == .starting {
                Button {
                    Task { await session.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.destructiveText)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(DS.Colors.destructive.opacity(0.12))
                .overlay(Rectangle().stroke(DS.Colors.destructive.opacity(0.35), lineWidth: 0.5))
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }

            workspaceIconButton(systemName: "xmark", helpText: "Close workspace", action: onClose)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func suggestedActions(_ actions: [String], session: AgentSession) -> some View {
        HStack(spacing: 8) {
            ForEach(actions, id: \.self) { action in
                Button {
                    companionManager.submitAgentPromptForSession(sessionID: session.id, prompt: action)
                } label: {
                    Text(action)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.accentText)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(DS.Colors.accent.opacity(0.12))
                        .overlay(Rectangle().stroke(DS.Colors.accent.opacity(0.22), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(DS.Colors.surface1)
    }

    private var emptyWorkspaceState: some View {
        VStack(spacing: 12) {
            LumaCompanionView(
                state: companionManager.companionSystem.state,
                appearance: companionManager.companionSystem.appearance,
                size: .large
            )
            .padding(.bottom, 6)

            Text("What are we working on?")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("Start a conversation to inspect, explain, edit, research, or automate work on your Mac.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("New conversation", action: createNewSession)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(DS.Colors.accent)
                .onHover { isHovering in
                    if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions and Styling

    private func createNewSession() {
        let newSession = companionManager.createAndSelectNewAgentSession()
        selectedSessionID = newSession.id
    }

    private func statusColor(for session: AgentSession) -> Color {
        switch session.status {
        case .ready: return DS.Colors.success
        case .running: return DS.Colors.accentText
        case .starting: return DS.Colors.warning
        case .failed: return DS.Colors.destructive
        case .stopped: return DS.Colors.textTertiary
        }
    }

    private func workspaceIconButton(systemName: String, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .background(Rectangle().fill(Color.white.opacity(0.045)))
        .overlay(Rectangle().stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
        .help(helpText)
        .onHover { isHovering in
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private func workspaceFooterButton(systemName: String, helpText: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { isHovering in
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

private struct WorkspaceSessionRow: View {
    @ObservedObject var session: AgentSession
    let isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 9) {
                Rectangle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)

                    Text(session.latestActivitySummary ?? session.statusSummaryLine)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Rectangle().fill(isSelected ? DS.Colors.accentSubtle : Color.clear))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? DS.Colors.accentText : Color.clear)
                    .frame(width: 2)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .ready: return DS.Colors.success
        case .running: return DS.Colors.accentText
        case .starting: return DS.Colors.warning
        case .failed: return DS.Colors.destructive
        case .stopped: return DS.Colors.textTertiary
        }
    }
}

private struct WorkspaceTranscriptView: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !session.taskSteps.isEmpty {
                        taskProgress
                    }

                    if session.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ask Luma to inspect, edit, explain, or automate something.")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("Luma will keep the task visible here while its agent runtime works.")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.Colors.surface1)
                        .overlay(Rectangle().stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
                    } else {
                        ForEach(session.entries) { entry in
                            workspaceTranscriptEntry(entry)
                                .id(entry.id)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
            .onChange(of: session.entries.count) { _ in
                guard let lastEntryID = session.entries.last?.id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(lastEntryID, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var taskProgress: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)

                Text("TASK PROGRESS")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .tracking(0.7)

                Spacer()

                Text(progressSummary)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            ForEach(session.taskSteps) { step in
                HStack(spacing: 8) {
                    Image(systemName: progressIcon(for: step.state))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(progressColor(for: step.state))
                        .frame(width: 14)

                    Text(step.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)

                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(DS.Colors.surface1)
        .overlay(Rectangle().stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 0.5))
    }

    private var progressSummary: String {
        let completedCount = session.taskSteps.filter { step in
            if case .completed = step.state { return true }
            return false
        }.count
        return "\(completedCount)/\(session.taskSteps.count)"
    }

    private func progressIcon(for state: AgentStepState) -> String {
        switch state {
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private func progressColor(for state: AgentStepState) -> Color {
        switch state {
        case .inProgress: return DS.Colors.accentText
        case .completed: return DS.Colors.success
        case .failed: return DS.Colors.destructiveText
        }
    }

    @ViewBuilder
    private func workspaceTranscriptEntry(_ entry: AgentTranscriptEntry) -> some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(entry.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(DS.Colors.accent)
            }

        case .assistant, .plan:
            VStack(alignment: .leading, spacing: 6) {
                transcriptRoleLabel(for: entry.role)
                RichMarkdownView(
                    text: LumaWriteEngine.normalizeForDisplay(entry.text),
                    accentColor: DS.Colors.accentText
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(DS.Colors.surface1)
            .overlay(Rectangle().stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 0.5))

        case .command:
            VStack(alignment: .leading, spacing: 6) {
                transcriptRoleLabel(for: entry.role)
                Text(entry.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.surface2)
            .overlay(Rectangle().stroke(DS.Colors.borderSubtle.opacity(0.65), lineWidth: 0.5))

        case .system:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(DS.Colors.warning)
                Text(entry.text)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.warning.opacity(0.08))
            .overlay(Rectangle().stroke(DS.Colors.warning.opacity(0.22), lineWidth: 0.5))
        }
    }

    private func transcriptRoleLabel(for role: TranscriptRole) -> some View {
        Text(roleLabel(for: role))
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .foregroundColor(roleColor(for: role))
            .tracking(0.6)
    }

    private func roleLabel(for role: TranscriptRole) -> String {
        switch role {
        case .user: return "YOU"
        case .assistant: return "LUMA"
        case .system: return "SYSTEM"
        case .command: return "TOOL"
        case .plan: return "PLAN"
        }
    }

    private func roleColor(for role: TranscriptRole) -> Color {
        switch role {
        case .user: return DS.Colors.accentText
        case .assistant: return DS.Colors.success
        case .system: return DS.Colors.warning
        case .command: return DS.Colors.textTertiary
        case .plan: return DS.Colors.accentText
        }
    }
}

private struct WorkspaceComposerView: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var companionManager: CompanionManager
    @State private var draft = ""

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isRecording: Bool {
        companionManager.agentVoiceRecordingSessionID == session.id
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            TextField("Message Luma...", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .tint(DS.Colors.accentText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(DS.Colors.surface2)
                .overlay(Rectangle().stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
                .onSubmit(send)

            Button {
                companionManager.toggleAgentVoiceRecording(sessionID: session.id)
            } label: {
                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isRecording ? DS.Colors.destructiveText : DS.Colors.textSecondary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(isRecording ? DS.Colors.destructive.opacity(0.16) : DS.Colors.surface2)
            .overlay(Rectangle().stroke(isRecording ? DS.Colors.destructive.opacity(0.35) : DS.Colors.borderSubtle, lineWidth: 0.5))
            .help(isRecording ? "Stop voice input" : "Start voice input")
            .onHover { isHovering in
                if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(canSend ? DS.Colors.accent : DS.Colors.accent.opacity(0.3))
            .disabled(!canSend)
            .help("Send message")
            .onHover { isHovering in
                if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(DS.Colors.surface1)
    }

    private func send() {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else { return }
        draft = ""
        companionManager.submitAgentPromptForSession(sessionID: session.id, prompt: trimmedDraft)
    }
}
