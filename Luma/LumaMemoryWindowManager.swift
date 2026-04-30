//
//  LumaMemoryWindowManager.swift
//  leanring-buddy
//
//  Manages the "Global Memory" floating NSWindow.
//  Shows and allows editing of the memory.md file that the agent system
//  uses to remember user preferences and facts between sessions.
//  Accessible via Cmd+Shift+M or the Memory button in Settings.
//

import AppKit
import SwiftUI

// MARK: - Default Memory Template

/// Predefined instructional template shown when the memory file is empty or newly initialized.
/// Uses markdown comment syntax (#) to explain the structure without injecting real preferences.
private let defaultMemoryTemplate = """
# Luma Memory

# This file is read by Luma at the start of every session.
# Use it to store facts you want Luma to always remember.
# Lines starting with # are comments and will be ignored by Luma.
#
# --- STRUCTURE GUIDE ---
#
# ## Preferences
# Add any working or communication preferences here.
# Example:
#   - I prefer concise responses without unnecessary explanation.
#   - Always use British English spelling.
#   - When writing code, prefer Swift and avoid Objective-C.
#
# ## Context
# Add background about yourself, your projects, or your environment.
# Example:
#   - I'm a solo iOS developer working on a SwiftUI app called Luma.
#   - My main machine is an M3 MacBook Pro running macOS Sequoia.
#   - My primary coding language is Swift; I'm learning Rust on the side.
#
# ## Instructions
# Specific behavioral instructions for how Luma should act.
# Example:
#   - Do not suggest refactors unless I explicitly ask.
#   - When I ask for help with writing, preserve my tone and voice.
#   - Never add emojis to responses unless I ask for them.
#
# --- START YOUR MEMORY BELOW THIS LINE ---

"""

// MARK: - Memory Window Manager

@MainActor
final class LumaMemoryWindowManager {

    static let shared = LumaMemoryWindowManager()

    private var memoryWindow: NSWindow?
    private var hostingController: NSHostingController<LumaMemoryWindowView>?

    private init() {
        // Register global keyboard shortcut: Cmd+Shift+M
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]),
               event.charactersIgnoringModifiers == "m" {
                Task { @MainActor in
                    self?.showMemoryWindow()
                }
                return nil
            }
            return event
        }
    }

    func showMemoryWindow() {
        if let existingWindow = memoryWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = LumaMemoryWindowView {
            self.memoryWindow?.close()
            self.memoryWindow = nil
            self.hostingController = nil
        }

        let controller = NSHostingController(rootView: contentView)
        hostingController = controller

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Global Memory"
        window.contentViewController = controller
        // Force the desired size after assigning contentViewController — NSHostingController
        // can override the window frame with the SwiftUI view's intrinsic content size.
        window.setContentSize(NSSize(width: 760, height: 500))
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 340)
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        memoryWindow = window
    }
}

// MARK: - Memory Window View

struct LumaMemoryWindowView: View {
    var onClose: () -> Void

    @State private var memoryContent: String = ""
    @State private var originalMemoryContent: String = ""
    @State private var isSaving: Bool = false
    @State private var lastSavedMessage: String = ""

    /// True only when the editor content differs from what was last saved/loaded.
    private var hasUnsavedChanges: Bool {
        memoryContent != originalMemoryContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Toolbar row ───────────────────────────────────────────────────
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Global Memory")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primary)
                    Text("Luma reads this file to remember preferences and facts between sessions.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if !lastSavedMessage.isEmpty {
                    Text(lastSavedMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .animation(.easeInOut, value: lastSavedMessage)
                }

                Button("Clear") {
                    memoryContent = defaultMemoryTemplate
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Button(hasUnsavedChanges ? "Save" : "Saved") {
                    saveMemory()
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    hasUnsavedChanges
                        ? Color.accentColor
                        : Color(NSColor.controlColor).opacity(0.60)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .disabled(!hasUnsavedChanges || isSaving)
                .onHover { hovering in
                    if hovering && hasUnsavedChanges { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // ── Text editor ───────────────────────────────────────────────────
            TextEditor(text: $memoryContent)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(NSColor.textBackgroundColor))
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            let loaded = LumaMemoryManager.shared.loadMemory()
            // If the file is blank or only contains the old bare-minimum header, show the template
            let trimmed = loaded.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "# Luma Memory\n\nThis file stores remembered preferences and facts about the user." || trimmed == "# Luma Memory" {
                memoryContent = defaultMemoryTemplate
                originalMemoryContent = defaultMemoryTemplate
                // Persist the template so next open shows it without changes
                LumaMemoryManager.shared.saveMemory(content: defaultMemoryTemplate)
            } else {
                memoryContent = loaded
                originalMemoryContent = loaded
            }
        }
    }

    private func saveMemory() {
        guard hasUnsavedChanges else { return }
        isSaving = true
        LumaMemoryManager.shared.saveMemory(content: memoryContent)
        originalMemoryContent = memoryContent
        isSaving = false
        lastSavedMessage = "Saved"
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { lastSavedMessage = "" }
        }
    }
}
