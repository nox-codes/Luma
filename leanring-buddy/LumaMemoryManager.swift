//
//  LumaMemoryManager.swift
//  leanring-buddy
//
//  Manages two file types in ~/Library/Application Support/Luma/:
//  - memory.md:  global markdown file for AI persona and remembered preferences
//  - history/:   per-agent conversation history as timestamped JSON files
//
//  When a JSON history file exceeds 2MB, a new timestamped file is created automatically.
//

import Foundation

// MARK: - Notification Names

extension Notification.Name {
    /// Posted on any thread immediately after a new ConversationEntry is written to disk.
    /// The history window subscribes to this to update its list in real time.
    static let lumaHistoryDidUpdate = Notification.Name("com.luma.historyDidUpdate")
}

/// A single conversation entry stored in per-agent history files.
struct ConversationEntry: Codable {
    let timestamp: Date
    let agentId: String
    let agentTitle: String
    let role: String         // "user" or "luma"
    let content: String
    let taskStatus: String?  // "complete", "failed", "in_progress"
}

/// Manages persistent memory (memory.md) and per-agent conversation history (JSON files).
/// Thread-safe — all file I/O is serialized through a lock.
final class LumaMemoryManager: @unchecked Sendable {

    static let shared = LumaMemoryManager()

    // MARK: - Configuration

    /// Maximum size of a single history JSON file before rotation (2 MB).
    private let maximumHistoryFileSizeInBytes: Int = 2 * 1024 * 1024

    // MARK: - File Paths

    private let lumaDataDirectoryURL: URL
    private let memoryFileURL: URL
    private let historyDirectoryURL: URL

    // MARK: - Threading

    private let lock = NSLock()
    private let fileManager = FileManager.default

    // MARK: - JSON Coding

    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Init

    private init() {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        lumaDataDirectoryURL = appSupportURL.appendingPathComponent("Luma", isDirectory: true)
        memoryFileURL = lumaDataDirectoryURL.appendingPathComponent("memory.md")
        historyDirectoryURL = lumaDataDirectoryURL.appendingPathComponent("history", isDirectory: true)

        ensureDirectoriesExist()
        ensureMemoryFileExists()
    }

    // MARK: - Memory (memory.md)

    /// Returns the full contents of memory.md, or an empty string if the file doesn't exist.
    func loadMemory() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: memoryFileURL, encoding: .utf8)) ?? ""
    }

    /// Overwrites the entire memory.md file with the given content.
    /// Used by the Memory Window editor to persist user edits.
    func saveMemory(content: String) {
        lock.lock()
        defer { lock.unlock() }
        try? content.data(using: .utf8)?.write(to: memoryFileURL, options: .atomic)
    }

    /// Appends a new fact to memory.md with a timestamp header.
    func updateMemory(newFact: String) {
        lock.lock()
        defer { lock.unlock() }

        let timestampString = ISO8601DateFormatter().string(from: Date())
        let entryToAppend = "\n\n## \(timestampString)\n\(newFact)\n"

        guard let data = entryToAppend.data(using: .utf8) else { return }

        if let fileHandle = try? FileHandle(forWritingTo: memoryFileURL) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            fileHandle.closeFile()
        }
    }

    // MARK: - History (per-agent JSON files)

    /// Appends a conversation entry to the current history file for the given agent.
    /// If the current file exceeds 2MB, a new timestamped file is created.
    func appendToHistory(agentId: String, entry: ConversationEntry) {
        lock.lock()
        defer { lock.unlock() }

        let currentFileURL = currentHistoryFileURL(forAgentId: agentId)

        // Load existing entries (or start fresh)
        var entries = loadEntriesFromFile(at: currentFileURL)
        entries.append(entry)

        // Write back
        writeEntriesToFile(entries, at: currentFileURL)

        // Check size and rotate if needed
        rotateHistoryFileIfNeeded(forAgentId: agentId, currentFileURL: currentFileURL)

        // Notify observers (e.g. the live history window) that a new entry was written.
        // Posted on a background thread — observers must dispatch to main if needed.
        NotificationCenter.default.post(name: .lumaHistoryDidUpdate, object: nil)
    }

    /// Searches all JSON history files for entries containing the query string.
    /// Returns matching entries across all agents sorted by timestamp (newest first).
    func searchHistory(query: String) -> [ConversationEntry] {
        lock.lock()
        defer { lock.unlock() }

        let lowercasedQuery = query.lowercased()
        var matchingEntries: [ConversationEntry] = []

        guard let historyFiles = try? fileManager.contentsOfDirectory(
            at: historyDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for fileURL in historyFiles where fileURL.pathExtension == "json" {
            let entries = loadEntriesFromFile(at: fileURL)
            let matches = entries.filter {
                $0.content.lowercased().contains(lowercasedQuery) ||
                $0.agentTitle.lowercased().contains(lowercasedQuery)
            }
            matchingEntries.append(contentsOf: matches)
        }

        return matchingEntries.sorted { $0.timestamp > $1.timestamp }
    }

    /// Loads every conversation entry across all agents and all history files.
    /// Returns entries sorted by timestamp, newest first.
    func loadAllHistory() -> [ConversationEntry] {
        lock.lock()
        defer { lock.unlock() }

        guard let historyFiles = try? fileManager.contentsOfDirectory(
            at: historyDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var allEntries: [ConversationEntry] = []
        for fileURL in historyFiles where fileURL.pathExtension == "json" {
            allEntries.append(contentsOf: loadEntriesFromFile(at: fileURL))
        }

        return allEntries.sorted { $0.timestamp > $1.timestamp }
    }

    /// Loads all history entries for a specific agent, across all of its history files.
    func loadHistory(forAgentId agentId: String) -> [ConversationEntry] {
        lock.lock()
        defer { lock.unlock() }

        guard let historyFiles = try? fileManager.contentsOfDirectory(
            at: historyDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let agentPrefix = "agent_\(agentId)"
        var allEntries: [ConversationEntry] = []

        for fileURL in historyFiles where fileURL.lastPathComponent.hasPrefix(agentPrefix) {
            let entries = loadEntriesFromFile(at: fileURL)
            allEntries.append(contentsOf: entries)
        }

        return allEntries.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Private: Directory & File Setup

    private func ensureDirectoriesExist() {
        try? fileManager.createDirectory(at: lumaDataDirectoryURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: historyDirectoryURL, withIntermediateDirectories: true)
    }

    private func ensureMemoryFileExists() {
        guard !fileManager.fileExists(atPath: memoryFileURL.path) else { return }
        let initialContent = "# Luma Memory\n\nThis file stores remembered preferences and facts about the user.\n"
        try? initialContent.data(using: .utf8)?.write(to: memoryFileURL, options: .atomic)
    }

    // MARK: - Private: History File Management

    /// Returns the current (latest) history file URL for the given agent.
    /// If no file exists yet, returns a URL for a new timestamped file.
    private func currentHistoryFileURL(forAgentId agentId: String) -> URL {
        let prefix = "agent_\(agentId)"

        // Find existing files for this agent
        if let files = try? fileManager.contentsOfDirectory(
            at: historyDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let agentFiles = files
                .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
                .sorted { first, second in
                    let firstDate = (try? first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let secondDate = (try? second.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return firstDate > secondDate
                }

            if let latestFile = agentFiles.first {
                return latestFile
            }
        }

        // No existing file — create a new one
        return newHistoryFileURL(forAgentId: agentId)
    }

    private func newHistoryFileURL(forAgentId agentId: String) -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return historyDirectoryURL
            .appendingPathComponent("agent_\(agentId)_\(timestamp).json")
    }

    /// If the file at the given URL exceeds 2MB, starts a new timestamped file.
    private func rotateHistoryFileIfNeeded(forAgentId agentId: String, currentFileURL: URL) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: currentFileURL.path),
              let fileSize = attributes[.size] as? Int,
              fileSize >= maximumHistoryFileSizeInBytes else { return }

        LumaLogger.log("[LumaMemory] History file for agent \(agentId) exceeded 2MB — rotating to new file")
        // Next call to currentHistoryFileURL will find the current file is too large;
        // we create a fresh file proactively so the next append goes to a new file.
        let freshFileURL = newHistoryFileURL(forAgentId: agentId)
        try? "[]".data(using: .utf8)?.write(to: freshFileURL, options: .atomic)
    }

    // MARK: - Private: JSON Read/Write

    private func loadEntriesFromFile(at fileURL: URL) -> [ConversationEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? jsonDecoder.decode([ConversationEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private func writeEntriesToFile(_ entries: [ConversationEntry], at fileURL: URL) {
        guard let data = try? jsonEncoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
