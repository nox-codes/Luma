//
//  AgentMemoryIntegration.swift
//  leanring-buddy
//
//  Bridges LumaMemoryManager with the agent system. Provides methods for:
//  - Loading and summarizing memory.md as system context for API calls
//  - Appending conversation entries to per-agent history
//  - Searching history when users ask about past tasks
//

import Foundation

/// Integrates LumaMemoryManager with the agent system. All methods are
/// safe to call from any context — file I/O is handled by LumaMemoryManager's lock.
enum AgentMemoryIntegration {

    // MARK: - Memory as System Context

    /// Maximum character count for the summarized memory prepended to agent API calls.
    /// Roughly equivalent to ~500 tokens at 4 chars/token.
    private static let maximumMemorySummaryCharacterCount = 2000

    /// Loads memory.md and returns a summarized version suitable for prepending
    /// to the system prompt in an agent's first API call. Returns an empty string
    /// if no memory is available.
    static func loadSummarizedMemoryForSystemContext() -> String {
        let rawMemory = LumaMemoryManager.shared.loadMemory()
        guard !rawMemory.isEmpty else { return "" }

        // Truncate to max character count, preserving complete lines
        if rawMemory.count <= maximumMemorySummaryCharacterCount {
            return rawMemory
        }

        let truncatedMemory = truncateToCompleteLine(rawMemory, maxCharacters: maximumMemorySummaryCharacterCount)
        return truncatedMemory + "\n\n(Memory truncated for brevity)"
    }

    /// Builds a system prompt prefix containing the user's memory context.
    /// Returns nil if there is no memory to include.
    static func memorySystemPromptPrefix() -> String? {
        let summarizedMemory = loadSummarizedMemoryForSystemContext()
        guard !summarizedMemory.isEmpty else { return nil }

        return """
        ## User Memory & Preferences
        The following is remembered context about this user and their preferences:

        \(summarizedMemory)

        ---
        """
    }

    // MARK: - History Recording

    /// Records a user message to the agent's conversation history.
    static func recordUserMessage(agentId: String, agentTitle: String, content: String) {
        let entry = ConversationEntry(
            timestamp: Date(),
            agentId: agentId,
            agentTitle: agentTitle,
            role: "user",
            content: content,
            taskStatus: nil
        )
        LumaMemoryManager.shared.appendToHistory(agentId: agentId, entry: entry)
    }

    /// Records a Luma agent response to the conversation history.
    static func recordAgentResponse(agentId: String, agentTitle: String, content: String, taskStatus: String?) {
        let entry = ConversationEntry(
            timestamp: Date(),
            agentId: agentId,
            agentTitle: agentTitle,
            role: "luma",
            content: content,
            taskStatus: taskStatus
        )
        LumaMemoryManager.shared.appendToHistory(agentId: agentId, entry: entry)
    }

    // MARK: - History Search

    /// Searches conversation history for entries matching a query.
    /// Returns a human-readable summary of the results for display in agent bubbles.
    static func searchHistoryAndSummarize(query: String, maxResults: Int = 5) -> String {
        let results = LumaMemoryManager.shared.searchHistory(query: query)

        guard !results.isEmpty else {
            return "No matching entries found in conversation history."
        }

        let limitedResults = Array(results.prefix(maxResults))
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        var summary = "Found \(results.count) matching entries"
        if results.count > maxResults {
            summary += " (showing first \(maxResults))"
        }
        summary += ":\n\n"

        for entry in limitedResults {
            let dateString = dateFormatter.string(from: entry.timestamp)
            let truncatedContent = entry.content.count > 120
                ? String(entry.content.prefix(120)) + "..."
                : entry.content
            let statusLabel = entry.taskStatus.map { " [\($0)]" } ?? ""
            summary += "- **\(dateString)** (\(entry.agentTitle)\(statusLabel)): \(truncatedContent)\n"
        }

        return summary
    }

    // MARK: - Private Helpers

    /// Truncates text to the given max character count, cutting at the last complete line.
    private static func truncateToCompleteLine(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let truncated = String(text.prefix(maxCharacters))
        if let lastNewlineIndex = truncated.lastIndex(of: "\n") {
            return String(truncated[truncated.startIndex...lastNewlineIndex])
        }
        return truncated
    }
}
