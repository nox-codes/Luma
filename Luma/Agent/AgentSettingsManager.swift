//
//  AgentSettingsManager.swift
//  leanring-buddy
//
//  Manages agent-mode settings: maximum agent count, agent profiles,
//  and the global agent-mode toggle. All values persist to UserDefaults.
//

import Combine
import Foundation
import UserNotifications

@MainActor
final class AgentSettingsManager: ObservableObject {

    static let shared = AgentSettingsManager()

    // MARK: - UserDefaults Keys

    static let maxAgentCountKey     = "luma.agents.maxCount"
    static let agentProfilesKey     = "luma.agents.profiles"
    static let agentModeEnabledKey  = "luma.agentMode.enabled"

    // MARK: - Published State

    /// Maximum number of agents allowed simultaneously (1–10, default 3).
    @Published var maxAgentCount: Int {
        didSet {
            let normalizedMaxAgentCount = max(1, min(10, maxAgentCount))
            if normalizedMaxAgentCount != maxAgentCount {
                maxAgentCount = normalizedMaxAgentCount
                return
            }
            UserDefaults.standard.set(normalizedMaxAgentCount, forKey: Self.maxAgentCountKey)
        }
    }

    /// Whether agent mode is globally enabled.
    @Published var isAgentModeEnabled: Bool {
        didSet { UserDefaults.standard.set(isAgentModeEnabled, forKey: Self.agentModeEnabledKey) }
    }

    /// Stored agent profiles with per-agent model configuration.
    @Published var agentProfiles: [AgentProfile] {
        didSet { persistAgentProfiles() }
    }

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard

        // Max agent count — default to 3 if never set
        let storedMaxCount = defaults.object(forKey: Self.maxAgentCountKey) as? Int
        self.maxAgentCount = max(1, min(10, storedMaxCount ?? 3))

        // Agent mode toggle
        self.isAgentModeEnabled = defaults.bool(forKey: Self.agentModeEnabledKey)

        // Load persisted agent profiles
        self.agentProfiles = Self.loadAgentProfiles(from: defaults)
    }

    // MARK: - Profile Management

    func addAgentProfile(_ profile: AgentProfile) {
        agentProfiles.append(profile)
    }

    func removeAgentProfile(withID profileID: UUID) {
        agentProfiles.removeAll { $0.id == profileID }
    }

    func updateAgentProfile(_ updatedProfile: AgentProfile) {
        if let index = agentProfiles.firstIndex(where: { $0.id == updatedProfile.id }) {
            agentProfiles[index] = updatedProfile
        }
    }

    // MARK: - Agent Limit Enforcement

    /// Checks if adding a new agent would exceed the maximum count.
    /// If so, removes the oldest idle agent (by `lastUsedAt`) and sends a macOS notification.
    /// Called by AgentManager before spawning a new agent.
    /// - Parameter activeAgents: Array of tuples (id, lastUsedAt, isProcessing) describing live agents.
    /// - Returns: The UUID of the dismissed agent, or nil if no dismissal was needed.
    @discardableResult
    func enforceAgentLimit(activeAgents: [(id: UUID, lastUsedAt: Date, isProcessing: Bool)]) -> UUID? {
        guard activeAgents.count >= maxAgentCount else { return nil }

        // Find the idle agent with the oldest lastUsedAt timestamp
        let idleAgents = activeAgents.filter { !$0.isProcessing }
        guard let oldestIdleAgent = idleAgents.min(by: { $0.lastUsedAt < $1.lastUsedAt }) else {
            // All agents are processing — can't auto-dismiss
            return nil
        }

        sendAgentLimitNotification()
        return oldestIdleAgent.id
    }

    private func sendAgentLimitNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Agent limit reached. Removed idle agent."
        content.body = "Luma removed the oldest idle agent."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "luma.agentLimit.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LumaLogger.log("Failed to send agent limit notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Persistence

    private func persistAgentProfiles() {
        if let encoded = try? JSONEncoder().encode(agentProfiles) {
            UserDefaults.standard.set(encoded, forKey: Self.agentProfilesKey)
        }
    }

    private struct LegacyAgentProfile: Decodable {
        let id: UUID?
        let name: String?
        let model: String?
    }

    private static func loadAgentProfiles(from defaults: UserDefaults) -> [AgentProfile] {
        guard let profileData = defaults.data(forKey: Self.agentProfilesKey) else { return [] }

        if let decodedProfiles = try? JSONDecoder().decode([AgentProfile].self, from: profileData) {
            return decodedProfiles
        }

        if let legacyProfiles = try? JSONDecoder().decode([LegacyAgentProfile].self, from: profileData) {
            let migratedProfiles = legacyProfiles.map { legacyProfile -> AgentProfile in
                let legacyModelRawValue = legacyProfile.model ?? AgentModel.claudeSonnet.rawValue
                let resolvedModel = AgentModel(rawValue: legacyModelRawValue) ?? .claudeSonnet
                let resolvedName = legacyProfile.name ?? "Agent"
                return AgentProfile(
                    id: legacyProfile.id ?? UUID(),
                    name: resolvedName,
                    model: resolvedModel
                )
            }
            if let encodedMigratedProfiles = try? JSONEncoder().encode(migratedProfiles) {
                defaults.set(encodedMigratedProfiles, forKey: Self.agentProfilesKey)
            }
            return migratedProfiles
        }

        defaults.removeObject(forKey: Self.agentProfilesKey)
        return []
    }
}
