//
//  LumaHistoryWindowManager.swift
//  leanring-buddy
//
//  Manages the "Conversation History" floating NSWindow.
//  Shows all persisted conversation entries across all agents with:
//  - Markdown rendering (**bold**, *italic*, `code`)
//  - <NEXT_ACTIONS> tags stripped from displayed content
//  - Click-to-expand entries for the full content
//  - Search across all agent history
//  - Clear All with confirmation
//  Accessible via Cmd+Shift+H or the History button in Settings.
//

import AppKit
import Combine
import SwiftUI

// MARK: - History Window Manager

@MainActor
final class LumaHistoryWindowManager {

    static let shared = LumaHistoryWindowManager()

    private var historyWindow: NSWindow?
    private var hostingController: NSHostingController<LumaHistoryWindowView>?

    private init() {
        // Register global keyboard shortcut: Cmd+Shift+H
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]),
               event.charactersIgnoringModifiers == "h" {
                Task { @MainActor in
                    self?.showHistoryWindow()
                }
                return nil
            }
            return event
        }
    }

    func showHistoryWindow() {
        if let existingWindow = historyWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = LumaHistoryWindowView {
            self.historyWindow?.close()
            self.historyWindow = nil
            self.hostingController = nil
        }

        let controller = NSHostingController(rootView: contentView)
        hostingController = controller

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Conversation History"
        window.contentViewController = controller
        // Force the desired size after assigning contentViewController — NSHostingController
        // can override the window frame with the SwiftUI view's intrinsic content size.
        window.setContentSize(NSSize(width: 860, height: 580))
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = window
    }
}

// MARK: - History Window View

struct LumaHistoryWindowView: View {
    var onClose: () -> Void

    @State private var allEntries: [ConversationEntry] = []
    @State private var searchQuery: String = ""
    @State private var isLoading: Bool = true
    @State private var showClearConfirmation: Bool = false
    /// IDs of entries the user has tapped to expand to full content.
    @State private var expandedEntryTimestamps: Set<Date> = []
    /// Combine sink that keeps the live-reload subscription alive for the view's lifetime.
    @State private var historyUpdateCancellable: AnyCancellable?

    /// Relative date formatter — "27 Apr 2026 at 19:02" style matching Image 2.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var filteredEntries: [ConversationEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allEntries }
        let lowercasedQuery = query.lowercased()
        return allEntries.filter {
            $0.content.lowercased().contains(lowercasedQuery) ||
            $0.agentTitle.lowercased().contains(lowercasedQuery) ||
            $0.role.lowercased().contains(lowercasedQuery)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Toolbar row ───────────────────────────────────────────────────
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conversation History")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.primary)
                    Text("\(filteredEntries.count) of \(allEntries.count) entries")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Search field — matches Image 2 style
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("Search history...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .tint(.white)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minWidth: 200)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(Rectangle())
                .overlay(
                    Rectangle()
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

                // Clear All button — red with trash icon, matching Image 2
                Button {
                    showClearConfirmation = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("Clear All")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.12))
                .clipShape(Rectangle())
                .overlay(
                    Rectangle()
                        .stroke(Color.red.opacity(0.35), lineWidth: 1)
                )
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .confirmationDialog(
                    "Clear all conversation history?",
                    isPresented: $showClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Clear All", role: .destructive) { clearAllHistory() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently deletes all stored conversation entries and cannot be undone.")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // ── Content area ──────────────────────────────────────────────────
            if isLoading {
                Spacer()
                HStack { Spacer(); ProgressView(); Spacer() }
                Spacer()
            } else if filteredEntries.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 34))
                        .foregroundColor(.secondary)
                    Text(allEntries.isEmpty
                         ? "No history yet"
                         : "No results for \"\(searchQuery)\"")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredEntries, id: \.timestamp) { entry in
                            historyEntryRow(entry: entry)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            loadHistory()
            // Subscribe to live updates — every new entry appended to disk
            // fires this notification so the list stays current like a log view.
            historyUpdateCancellable = NotificationCenter.default
                .publisher(for: .lumaHistoryDidUpdate)
                .receive(on: DispatchQueue.main)
                .sink { [self] _ in loadHistory() }
        }
        .onDisappear {
            historyUpdateCancellable = nil
        }
    }

    // MARK: - Entry Row

    @ViewBuilder
    private func historyEntryRow(entry: ConversationEntry) -> some View {
        let isExpanded = expandedEntryTimestamps.contains(entry.timestamp)
        let displayContent = sanitizedContent(entry.content)
        let isLuma = entry.role != "user"

        Button(action: { toggleExpansion(of: entry) }) {
            VStack(alignment: .leading, spacing: 6) {

                // ── Header: role badge + agent name + timestamp ───────────────
                HStack(spacing: 8) {
                    // Role badge — blue "Luma" pill or muted "You" pill (Image 2 style)
                    Text(isLuma ? "Luma" : "You")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            isLuma
                                ? Color(red: 0.24, green: 0.47, blue: 0.95)
                                : Color.secondary.opacity(0.50)
                        )
                        .clipShape(Rectangle())

                    // Agent name in muted text
                    Text(entry.agentTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    Spacer()

                    // Timestamp on the right — "27 Apr 2026 at 19:02" format
                    Text(Self.timestampFormatter.string(from: entry.timestamp))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                // ── Content: collapsed (line-limited) or expanded ────────────
                if isExpanded {
                    // Full content with markdown rendering, no line limit
                    Text(lumaMarkdown(displayContent))
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Preview — 3 lines, tap to expand
                    Text(lumaMarkdown(displayContent + "..."))
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.60))
            .clipShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Content Sanitization

    /// Strips <NEXT_ACTIONS>...</NEXT_ACTIONS> blocks from displayed content,
    /// then trims leading/trailing whitespace so the rendered text is clean.
    private func sanitizedContent(_ rawContent: String) -> String {
        // Remove the <NEXT_ACTIONS> XML block entirely — it's agent-internal metadata
        let nextActionsPattern = #"<NEXT_ACTIONS>[\s\S]*?</NEXT_ACTIONS>"#
        guard let regex = try? NSRegularExpression(pattern: nextActionsPattern, options: []) else {
            return rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let range = NSRange(rawContent.startIndex..., in: rawContent)
        let stripped = regex.stringByReplacingMatches(
            in: rawContent,
            options: [],
            range: range,
            withTemplate: ""
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Expansion Toggle

    private func toggleExpansion(of entry: ConversationEntry) {
        if expandedEntryTimestamps.contains(entry.timestamp) {
            expandedEntryTimestamps.remove(entry.timestamp)
        } else {
            expandedEntryTimestamps.insert(entry.timestamp)
        }
    }

    // MARK: - Data Loading

    private func loadHistory() {
        isLoading = true
        Task.detached {
            let entries = LumaMemoryManager.shared.loadAllHistory()
            await MainActor.run {
                allEntries = entries
                isLoading = false
            }
        }
    }

    private func clearAllHistory() {
        let historyDirURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Luma/history", isDirectory: true)

        if let files = try? FileManager.default.contentsOfDirectory(
            at: historyDirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for fileURL in files where fileURL.pathExtension == "json" {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        allEntries = []
        expandedEntryTimestamps = []
    }
}
