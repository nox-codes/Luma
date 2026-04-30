//
//  VaultManager.swift
//  leanring-buddy
//
//  Stores ALL sensitive app data (PIN, API keys) in a single Keychain item:
//  "com.nox.luma.vault". One item = one macOS "Allow" dialog, ever.
//  The vault is decoded once at launch and kept in memory; writes go back
//  to the single item atomically.
//
//  Migration: if the vault doesn't exist yet, the old individual Keychain
//  entries (com.nox.luma.pin, com.nox.luma.apikey.*) are read, folded in,
//  and then deleted — so users upgrading never see extra prompts from old items.
//

import Foundation

// MARK: - LumaVault

/// All sensitive Luma data packed into one Codable struct.
/// Stored as a single Keychain item so macOS only needs to confirm access once.
struct LumaVault: Codable {
    var pin: String?
    var apiKeys: [String: String] = [:]   // profileID.uuidString → key
}

// MARK: - VaultManager

@MainActor
final class VaultManager {
    static let shared = VaultManager()

    private static let vaultKey = "com.nox.luma.vault"

    private var vault: LumaVault

    private init() {
        vault = Self.loadOrMigrate()
    }

    // MARK: - PIN

    var hasPIN: Bool { vault.pin != nil }

    func setPIN(_ pin: String) throws {
        vault.pin = pin
        try persist()
    }

    func validatePIN(_ entered: String) -> Bool {
        vault.pin == entered
    }

    func clearPIN() throws {
        vault.pin = nil
        try persist()
    }

    // MARK: - API Keys

    func apiKey(for profileID: UUID) -> String? {
        vault.apiKeys[profileID.uuidString]
    }

    func setAPIKey(_ key: String, for profileID: UUID) throws {
        vault.apiKeys[profileID.uuidString] = key.isEmpty ? nil : key
        try persist()
    }

    func removeAPIKey(for profileID: UUID) {
        vault.apiKeys.removeValue(forKey: profileID.uuidString)
        try? persist()
    }

    func clearAllAPIKeys() {
        vault.apiKeys.removeAll()
        try? persist()
    }

    // MARK: - Reset (wipes the entire vault)

    func deleteAll() {
        vault = LumaVault()
        try? KeychainManager.delete(key: Self.vaultKey)
    }

    // MARK: - Internal

    private func persist() throws {
        guard let data = try? JSONEncoder().encode(vault) else { return }
        try KeychainManager.save(key: Self.vaultKey, data: data)
    }

    /// Loads the vault from Keychain, or migrates from the old individual items
    /// if the vault doesn't exist yet (first run after upgrade).
    private static func loadOrMigrate() -> LumaVault {
        // Happy path: vault already exists
        if let data = try? KeychainManager.load(key: vaultKey),
           let vault = try? JSONDecoder().decode(LumaVault.self, from: data) {
            return vault
        }

        // Migration: fold old PIN item into a fresh vault
        var migrated = LumaVault()

        if let pin = try? KeychainManager.loadString(key: "com.nox.luma.pin") {
            migrated.pin = pin
            try? KeychainManager.delete(key: "com.nox.luma.pin")
        }
        // API keys (com.nox.luma.apikey.<uuid>) are migrated lazily in
        // ProfileManager.loadAPIKey(forProfileID:) once profile UUIDs are known.

        if let data = try? JSONEncoder().encode(migrated) {
            try? KeychainManager.save(key: vaultKey, data: data)
        }

        return migrated
    }
}
