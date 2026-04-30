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

    /// Returns true if the event was consumed (matched an agent hotkey).
    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let companionManager else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Ctrl+Cmd+N → Spawn new agent session
        if flags == [.control, .command] && event.charactersIgnoringModifiers == "n" {
            companionManager.createAndSelectNewAgentSession()
            return true
        }

        // Ctrl+Option+Tab → Cycle to next agent session
        if flags == [.control, .option] && event.keyCode == 48 { // Tab key
            companionManager.cycleActiveAgent()
            return true
        }

        // Ctrl+Option+1 through Ctrl+Option+9 → Switch to agent at index
        if flags == [.control, .option],
           let characters = event.charactersIgnoringModifiers,
           let digit = characters.first,
           digit >= "1" && digit <= "9" {
            let agentIndex = Int(String(digit))! - 1
            companionManager.switchToAgentAtIndex(agentIndex)
            return true
        }

        return false
    }
}
