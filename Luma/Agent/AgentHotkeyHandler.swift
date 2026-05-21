//
//  AgentHotkeyHandler.swift
//  leanring-buddy
//
//  Registers global NSEvent monitors for agent hotkeys:
//  - Ctrl+Cmd+N: Spawn new agent session
//  - Ctrl+Option+1..9: Switch focus to agent at index
//  - Ctrl+Option+Tab: Cycle to next agent session
//

import AppKit

@MainActor
final class AgentHotkeyHandler {

    static let shared = AgentHotkeyHandler()

    private weak var companionManager: CompanionManager?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    private init() {}

    /// Starts listening for agent-related hotkeys.
    /// Call once during app startup (e.g. in CompanionManager.start()).
    func startMonitoring(companionManager: CompanionManager) {
        self.companionManager = companionManager
        guard localMonitor == nil else { return }

        // Local monitor for when the app is active
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil  // Consumed
            }
            return event
        }

        // Global monitor for when the app is running in the background
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        LumaLogger.log("[AgentHotkeys] Monitoring started")
    }

    func stopMonitoring() {
        if let localMonitor = localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        companionManager = nil
    }

    // MARK: - Key Event Handling

    /// Agent spawn hotkeys have been removed. Agents are now spawned exclusively
    /// by the intent classifier when a task requires one, or by explicit voice
    /// command ("new agent", "Luma agent"). This method is kept as an empty stub
    /// so call sites don't need to be removed.
    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        return false
    }
}
