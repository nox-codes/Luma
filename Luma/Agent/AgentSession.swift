//
//  AgentSession.swift
//  leanring-buddy
//
//  Core agent session model. Each session represents one autonomous agent
//  with its own transcript, status, accent theme, and runtime binding.
//  Mirrors OpenClicky's CodexAgentSession architecture.
//

import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Task Step Model

/// The lifecycle state of a single agent task step (tool call).
enum AgentStepState {
    case inProgress
    case completed
    case failed
}

/// Represents one discrete step the agent took while executing a task.
/// Each step corresponds to one tool call (e.g. bash, read_file, write_file).
struct AgentStep: Identifiable {
    let id: UUID
    /// Human-readable label derived from the tool name, e.g. "bash", "read_file".
    let label: String
    /// Current lifecycle state of this step.
    var state: AgentStepState

    init(label: String, state: AgentStepState = .inProgress) {
        self.id = UUID()
        self.label = label
        self.state = state
    }
}

// MARK: - AgentSessionStatus

enum AgentSessionStatus: Equatable {
    case stopped
    case starting
    case ready
    case running
    case failed(String)

    var displayLabel: String {
        switch self {
        case .stopped: return "IDLE"
        case .starting: return "STARTING"
        case .ready: return "READY"
        case .running: return "WORKING"
        case .failed: return "NEEDS ATTENTION"
        }
    }

    static func == (lhs: AgentSessionStatus, rhs: AgentSessionStatus) -> Bool {
        switch (lhs, rhs) {
        case (.stopped, .stopped), (.starting, .starting), (.ready, .ready), (.running, .running):
            return true
        case (.failed(let lhsMsg), .failed(let rhsMsg)):
            return lhsMsg == rhsMsg
        default:
            return false
        }
    }
}

@MainActor
final class AgentSession: ObservableObject, Identifiable {
    let id: UUID
    @Published var title: String
    @Published var accentTheme: LumaAccentTheme
    @Published private(set) var status: AgentSessionStatus = .stopped
    @Published private(set) var entries: [AgentTranscriptEntry] = []
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var latestResponseCard: ResponseCard?
    /// A cheap-model summary of the most recently completed task. Used by
    /// buildContextualPrompt to replace raw transcript history in follow-up prompts,
    /// keeping multi-session token cost flat instead of growing linearly.
    @Published private(set) var completedTaskSummary: String?
    /// Steps extracted from tool-call command entries during the current task.
    /// Cleared when a new prompt is submitted; each tool call appends one step.
    @Published private(set) var taskSteps: [AgentStep] = []
    @Published var model: String
    @Published var workingDirectoryPath: String

    /// The shell command this session is executing, if it was spawned by the
    /// CLI classifier path. `nil` for normal agent sessions. Used by the dock
    /// bubble to switch to CLI display mode (monospace output, command disclosure).
    @Published private(set) var cliCommand: String?

    /// When true, this session was spawned automatically to handle a single
    /// classified task. It will be dismissed automatically when the task
    /// completes — the user did not explicitly request a persistent agent.
    var isTransient: Bool = false

    /// True when this session was spawned to run a single shell command.
    var isCLISession: Bool { cliCommand != nil }

    /// Random icon shape assigned at creation for visual variety in the dock
    let iconShape: AgentIconShape
    /// Random glow color for the dock bubble
    let glowColor: Color

    private var runtime: (any AgentRuntime)?
    private var cancellables = Set<AnyCancellable>()
    private var hasGeneratedTitle = false

    private static let randomGlowColors: [Color] = [
        Color(red: 0.04, green: 0.52, blue: 1.0),   // Blue
        Color(red: 0.20, green: 0.83, blue: 0.60),   // Mint
        Color(red: 1.00, green: 0.70, blue: 0.14),   // Amber
        Color(red: 0.96, green: 0.36, blue: 0.42),   // Rose
        Color(red: 0.65, green: 0.40, blue: 1.00),   // Purple
        Color(red: 0.00, green: 0.87, blue: 0.87),   // Cyan
        Color(red: 1.00, green: 0.47, blue: 0.00),   // Orange
        Color(red: 0.56, green: 0.85, blue: 0.27),   // Lime
    ]

    var statusSummaryLine: String {
        switch status {
        case .stopped: return "Agent is idle"
        case .starting: return "Starting up..."
        case .ready: return "Ready for tasks"
        case .running: return "Working on task..."
        case .failed(let message): return "Failed: \(message)"
        }
    }

    var latestActivitySummary: String? {
        guard let raw = entries.last(where: { $0.role == .assistant })?.text else { return nil }
        let normalized = LumaWriteEngine.normalizeForDisplay(raw)
        return normalized.isEmpty ? nil : normalized
    }

    /// ≤20-word summary shown in the compact card and spoken by the write engine.
    /// Truncates `latestActivitySummary` to 20 words with an ellipsis if needed.
    var shortSummary: String? {
        guard let full = latestActivitySummary else { return nil }
        let words = full.split(separator: " ", omittingEmptySubsequences: true)
        if words.count <= 20 { return full }
        return words.prefix(20).joined(separator: " ") + "…"
    }

    var hasVisibleActivity: Bool {
        !entries.isEmpty
    }

    init(
        id: UUID = UUID(),
        title: String = "New Agent",
        accentTheme: LumaAccentTheme = .blue,
        model: String = UserDefaults.standard.string(forKey: "luma.agent.defaultModel") ?? "claude-sonnet-4-6",
        workingDirectoryPath: String = UserDefaults.standard.string(forKey: "luma.agent.workingDirectory") ?? NSHomeDirectory(),
        restoredIconShape: AgentIconShape? = nil,
        restoredGlowColor: Color? = nil
    ) {
        self.id = id
        self.title = title
        self.accentTheme = accentTheme
        self.model = model
        self.workingDirectoryPath = workingDirectoryPath
        self.iconShape = restoredIconShape ?? AgentIconShape.random
        self.glowColor = restoredGlowColor ?? Self.randomGlowColors.randomElement() ?? Color.blue
    }

    /// Marks this session as a CLI session so the dock bubble renders in CLI display mode.
    /// Should be called immediately after creating the session, before binding the runtime.
    func markAsCLISession(command: String) {
        cliCommand = command
        title = "Shell: \(command.prefix(40))"
    }

    /// Restores a transcript entry from persisted data (does not trigger memory recording).
    func restoreTranscriptEntry(_ entry: AgentTranscriptEntry) {
        entries.append(entry)
        if entry.role == .assistant {
            latestResponseCard = ResponseCard(source: .agent, rawText: entry.text)
        }
    }

    func bind(to runtime: any AgentRuntime) {
        self.runtime = runtime

        runtime.transcriptPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entry in
                guard let self else { return }
                self.entries.append(entry)

                // Build response card from assistant messages
                if entry.role == .assistant {
                    let card = ResponseCard(source: .agent, rawText: entry.text)
                    self.latestResponseCard = card
                }

                // Parse tool-call command entries as task progress steps.
                // Each command entry corresponds to one tool invocation (bash, read_file, etc.).
                // We mark the previous in-progress step as completed when the next command
                // arrives (since the runtime only emits one command at a time sequentially).
                if entry.role == .command {
                    // Complete the previous step before starting the next one.
                    var updatedSteps = self.taskSteps
                    if let previousInProgressIndex = updatedSteps.indices.last(where: { updatedSteps[$0].state == .inProgress }) {
                        updatedSteps[previousInProgressIndex].state = .completed
                    }
                    let newStepLabel = self.stepLabelFromCommandText(entry.text)
                    updatedSteps.append(AgentStep(label: newStepLabel))
                    self.taskSteps = updatedSteps
                }

                // Persist to memory history
                switch entry.role {
                case .user:
                    AgentMemoryIntegration.recordUserMessage(
                        agentId: self.id.uuidString,
                        agentTitle: self.title,
                        content: entry.text
                    )
                case .assistant:
                    AgentMemoryIntegration.recordAgentResponse(
                        agentId: self.id.uuidString,
                        agentTitle: self.title,
                        content: entry.text,
                        taskStatus: nil
                    )
                default:
                    break
                }
            }
            .store(in: &cancellables)

        runtime.statusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (sessionId, newStatus) in
                guard let self, sessionId == self.id else { return }
                let previousStatus = self.status
                self.status = newStatus
                if case .failed(let message) = newStatus {
                    self.lastErrorMessage = message
                }

                // Detect task completion: running → ready
                if case .running = previousStatus, case .ready = newStatus {
                    // Finalize the last step that was still in-progress.
                    var finalizedSteps = self.taskSteps
                    if let idx = finalizedSteps.indices.last(where: { finalizedSteps[$0].state == .inProgress }) {
                        finalizedSteps[idx].state = .completed
                        self.taskSteps = finalizedSteps
                    }
                    self.announceTaskCompletion()
                    // Summarize the completed session in the background so follow-up
                    // prompts can use a compact summary instead of the raw transcript.
                    self.triggerTaskCompletionSummarization()
                    // Update the behavioral outlook profile with this agent interaction
                    // so Luma builds a richer user model over time across all modes.
                    self.triggerOutlookObservation()
                }

                // If the task failed, mark the last in-progress step as failed.
                if case .running = previousStatus, case .failed = newStatus {
                    var failedSteps = self.taskSteps
                    if let idx = failedSteps.indices.last(where: { failedSteps[$0].state == .inProgress }) {
                        failedSteps[idx].state = .failed
                        self.taskSteps = failedSteps
                    }
                }
            }
            .store(in: &cancellables)
    }

    func warmUp() async {
        guard let runtime else { return }
        status = .starting
        do {
            try await runtime.startSession(
                id: id,
                task: "",
                workingDirectory: workingDirectoryPath,
                systemContext: ""
            )
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func submitPrompt(_ prompt: String, systemContext: String = "") async {
        generateTitleIfNeeded(from: prompt)

        guard let runtime else { return }
        let userEntry = AgentTranscriptEntry(role: .user, text: prompt)
        entries.append(userEntry)
        status = .running
        lastErrorMessage = nil
        // Clear previous task steps so the progress section starts fresh for this task.
        taskSteps = []

        // Build full conversation context so the runtime has complete history
        let contextualPrompt = buildContextualPrompt(latestPrompt: prompt)

        do {
            try await runtime.submitPrompt(sessionId: id, prompt: contextualPrompt)
        } catch {
            status = .failed(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Builds a prompt string that includes prior conversation context so each
    /// CLI invocation has full context (Claude CLI spawns a new process per prompt).
    /// Uses a completed-task summary when available to keep follow-up cost flat,
    /// otherwise falls back to the last 6 raw transcript entries.
    private func buildContextualPrompt(latestPrompt: String) -> String {
        // If we have a summary of the previous completed task, use it instead of
        // raw history. This keeps follow-up cost flat regardless of session length.
        if let summary = completedTaskSummary {
            return """
            [Previous task summary: \(summary)]

            [New request:]
            \(latestPrompt)
            """
        }

        // No summary yet — include the last 6 raw transcript entries for context.
        // Capped to prevent linear cost growth across the first few exchanges.
        let priorEntries = entries.dropLast() // everything except the one we just appended
        guard !priorEntries.isEmpty else { return latestPrompt }

        let maximumPriorEntriesToInclude = 6
        let cappedPriorEntries = priorEntries.suffix(maximumPriorEntriesToInclude)
        let didOmitEarlierEntries = priorEntries.count > maximumPriorEntriesToInclude

        var contextLines: [String] = []
        if didOmitEarlierEntries {
            contextLines.append("[Earlier context omitted for brevity]")
        }
        contextLines.append("[Previous conversation for context:]")

        for entry in cappedPriorEntries {
            let roleLabel: String
            switch entry.role {
            case .user: roleLabel = "User"
            case .assistant: roleLabel = "Assistant"
            case .system: roleLabel = "System"
            case .command: roleLabel = "Command"
            case .plan: roleLabel = "Plan"
            }
            contextLines.append("\(roleLabel): \(entry.text)")
        }
        contextLines.append("")
        contextLines.append("[New request:]")
        contextLines.append(latestPrompt)

        return contextLines.joined(separator: "\n")
    }

    func stop() async {
        guard let runtime else { return }
        await runtime.stopSession(sessionId: id)
        status = .stopped
    }

    func dismissLatestResponseCard() {
        latestResponseCard = nil
    }

    func setResponseCard(_ card: ResponseCard) {
        latestResponseCard = card
    }

    // MARK: - Task Completion

    /// Notification posted when an agent session completes a task.
    /// userInfo contains "sessionId" (UUID), "title" (String), "summary" (String).
    static let taskCompletedNotificationName = Notification.Name("lumaAgentTaskCompleted")

    private func announceTaskCompletion() {
        // Build a spoken announcement that includes three components:
        // 1. What the user asked (task excerpt from the last user message)
        // 2. A brief summary of the response (shortSummary, ≤20 words)
        // 3. A direction to the agent bubble for the full details
        // This gives full context without reading the entire response aloud.
        let responseBrief = shortSummary ?? "Task completed."

        // Only direct the user to the agent bubble when the full response is long enough
        // that TTS would truncate or read for an unreasonable amount of time (>200 chars).
        let fullResponseText = latestResponseCard?.rawText ?? ""
        let responseIsLong = fullResponseText.count > 200
        let bubbleDirectionSuffix = responseIsLong ? " See the agent bubble for the full details." : ""

        // Speak only the response summary — never echo back the user's original request
        // as a "title" prefix before the answer.
        let spokenAnnouncement = "\(responseBrief).\(bubbleDirectionSuffix)"

        NotificationCenter.default.post(
            name: Self.taskCompletedNotificationName,
            object: nil,
            userInfo: [
                "sessionId": id,
                "title": title,
                "summary": spokenAnnouncement
            ]
        )

        LumaLogger.log("[Luma] Agent '\(title)' completed: \(responseBrief.prefix(80))")
    }

    // MARK: - Task Summarization

    /// Maps the session's configured model to the cheapest equivalent for summarization calls.
    /// Claude → Haiku, OpenAI → gpt-4o-mini, Google → gemini-flash, custom → as-is.
    static func cheapSummaryModelID(for agentModel: String) -> String {
        switch agentModel {
        case "claude-sonnet-4-6", "claude-opus-4-6":
            return "anthropic/claude-haiku-4-5-20251001"
        case "gpt-4o", "gpt-4o-mini":
            return "openai/gpt-4o-mini"
        default:
            if agentModel.hasPrefix("google/") {
                return "google/gemini-2.5-flash:free"
            }
            // Custom or OpenRouter model — use as-is (user already chose it)
            return agentModel
        }
    }

    /// Fires an outlook observation for this agent session on task completion.
    /// Uses the last user prompt and last assistant reply as the interaction snapshot.
    /// No-ops silently if either side of the conversation is absent.
    private func triggerOutlookObservation() {
        let lastUserInput = entries.last(where: { $0.role == .user })?.text ?? ""
        let lastAssistantReply = entries.last(where: { $0.role == .assistant })?.text ?? ""
        guard !lastUserInput.isEmpty, !lastAssistantReply.isEmpty else { return }
        LumaUserOutlookManager.shared.observeInteractionAsync(
            userInput: lastUserInput,
            aiResponse: lastAssistantReply
        )
    }

    /// Reads session state on the main actor, then fires a background Task to call the
    /// cheap summary model. Stores the result back in `completedTaskSummary` on main.
    private func triggerTaskCompletionSummarization() {
        let entriesToSummarize = Array(entries.suffix(20))
        guard !entriesToSummarize.isEmpty else { return }

        let cheapModel = Self.cheapSummaryModelID(for: model)
        let apiKey = ProfileManager.shared.loadActiveAPIKey()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { return }

        Task {
            await performTaskSummarization(
                entriesToSummarize: entriesToSummarize,
                cheapModel: cheapModel,
                apiKey: apiKey
            )
        }
    }

    /// Calls the cheap model on OpenRouter to produce a 2–3 sentence summary of the
    /// completed session. Stores the result in `completedTaskSummary` for use in
    /// follow-up prompts. Max 200 tokens keeps the call cheap.
    private func performTaskSummarization(
        entriesToSummarize: [AgentTranscriptEntry],
        cheapModel: String,
        apiKey: String
    ) async {
        let transcriptText = entriesToSummarize.map { entry -> String in
            let roleLabel: String
            switch entry.role {
            case .user:      roleLabel = "User"
            case .assistant: roleLabel = "Assistant"
            case .system:    roleLabel = "System"
            case .command:   roleLabel = "Command"
            case .plan:      roleLabel = "Plan"
            }
            return "\(roleLabel): \(entry.text)"
        }.joined(separator: "\n")

        let summaryPrompt = """
        Summarize this agent session in 2-3 sentences. Be factual and specific. \
        Include: what was requested, the key steps taken, and the outcome.

        \(transcriptText)
        """

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let requestBody: [String: Any] = [
            "model": cheapModel,
            "messages": [["role": "user", "content": summaryPrompt]],
            "max_tokens": 200
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmedSummary = content.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self.completedTaskSummary = trimmedSummary
                }
                LumaLogger.log("[Luma] Agent '\(title)' session summarized: \(trimmedSummary.prefix(80))...")
            }
        } catch {
            LumaLogger.log("[Luma] Agent session summarization failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Title Generation

    private func generateTitleIfNeeded(from prompt: String) {
        guard !hasGeneratedTitle else { return }
        hasGeneratedTitle = true

        // Read profile settings on the main actor (safe here — @MainActor function).
        // The active profile determines which API endpoint and auth format to use.
        // Previously this always called OpenRouter, which broke for Anthropic profiles.
        guard let activeProfile = ProfileManager.shared.activeProfile else { return }
        let apiKey = ProfileManager.shared.loadActiveAPIKey()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { return }

        let provider = activeProfile.provider
        let baseURL = activeProfile.effectiveBaseURL

        Task {
            let titlePrompt = "Generate a 3-5 word title for this task: \(prompt). Return only the title, nothing else."
            do {
                let generatedTitle: String?
                if provider == .anthropic {
                    // Anthropic uses a different API path and request/response format than OpenAI.
                    generatedTitle = try await fetchTitleFromAnthropicAPI(
                        prompt: titlePrompt, apiKey: apiKey, baseURL: baseURL
                    )
                } else {
                    // OpenRouter, Google, and Custom all use OpenAI-compatible chat completions.
                    generatedTitle = try await fetchTitleFromOpenAICompatibleAPI(
                        prompt: titlePrompt, apiKey: apiKey, baseURL: baseURL, provider: provider
                    )
                }
                if let title = generatedTitle, !title.isEmpty {
                    await MainActor.run { self.title = title }
                    LumaLogger.log("[Luma] Agent '\(title)' title generated.")
                }
            } catch {
                LumaLogger.log("[Luma] Title generation failed: \(error)")
            }
        }
    }

    /// Generates a title via any OpenAI-compatible endpoint (OpenRouter, Google, Custom).
    private func fetchTitleFromOpenAICompatibleAPI(
        prompt: String,
        apiKey: String,
        baseURL: String,
        provider: LumaAPIProvider
    ) async throws -> String? {
        guard let url = URL(string: "\(baseURL)/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let authValue = provider.requiresBearerPrefix ? "Bearer \(apiKey)" : apiKey
        request.setValue(authValue, forHTTPHeaderField: provider.authHeaderName)

        let requestBody: [String: Any] = [
            "model": cheapTitleModelID(for: provider),
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 20
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Generates a title via the Anthropic messages API (different path and schema from OpenAI).
    private func fetchTitleFromAnthropicAPI(
        prompt: String,
        apiKey: String,
        baseURL: String
    ) async throws -> String? {
        // Anthropic's endpoint is /messages, not /chat/completions.
        guard let url = URL(string: "\(baseURL)/messages") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let requestBody: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 20
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)
        // Anthropic response: { "content": [{ "type": "text", "text": "..." }] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]],
              let firstBlock = contentArray.first,
              let text = firstBlock["text"] as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Step Parsing

    /// Extracts a human-readable step label from a command transcript entry.
    /// ClaudeCodeAgentRuntime formats command entries as "[tool_name] input...",
    /// e.g. "[bash] ls -la" → "bash", "[read_file] path.swift" → "read_file".
    private func stepLabelFromCommandText(_ commandText: String) -> String {
        if commandText.hasPrefix("["), let closingBracketIndex = commandText.firstIndex(of: "]") {
            let toolName = String(commandText[commandText.index(after: commandText.startIndex)..<closingBracketIndex])
            return toolName.isEmpty ? commandText : toolName
        }
        // Fallback: use the first word as the label
        return commandText.components(separatedBy: " ").first ?? commandText
    }

    /// Returns the cheapest model suitable for title generation for a given provider.
    private func cheapTitleModelID(for provider: LumaAPIProvider) -> String {
        switch provider {
        case .openRouter: return "google/gemini-2.5-flash:free"
        case .google:     return "gemini-2.5-flash"
        case .anthropic:  return "claude-haiku-4-5-20251001"   // fallback; Anthropic handled separately
        case .custom:     return Self.cheapSummaryModelID(for: self.model)
        }
    }
}
