import Foundation
@preconcurrency import Combine

// MARK: - LumaAPIProvider

/// The AI provider type for an API profile.
enum LumaAPIProvider: String, Codable, CaseIterable {
    case openRouter = "OpenRouter"
    case anthropic = "Anthropic"
    case google = "Google"
    case custom = "Custom"

    /// Human-readable display name
    var displayName: String { rawValue }

    /// The default base URL for this provider's chat completions endpoint.
    var defaultBaseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .anthropic:  return "https://api.anthropic.com/v1"
        case .google:     return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .custom:     return ""
        }
    }

    /// The auth header name used by this provider.
    /// Anthropic uses x-api-key; everyone else uses Authorization: Bearer.
    var authHeaderName: String {
        switch self {
        case .anthropic: return "x-api-key"
        default: return "Authorization"
        }
    }

    /// Whether the auth value needs "Bearer " prefix
    var requiresBearerPrefix: Bool {
        switch self {
        case .anthropic: return false
        default: return true
        }
    }
}

// MARK: - LumaAPIProfile

/// A stored API configuration profile.
/// Profile metadata is stored in UserDefaults as JSON. Each profile's API key is stored
/// separately in the Keychain under "com.nox.luma.apikey.<profile-id>".
struct LumaAPIProfile: Codable, Identifiable {
    /// Stable UUID for this profile
    let id: UUID
    /// Human-readable profile name (e.g. "Work - OpenRouter", "Personal - Anthropic")
    var name: String
    /// The AI provider
    var provider: LumaAPIProvider
    /// Override for the base URL (used for Custom provider or custom endpoints)
    var baseURL: String
    /// Whether this is the active/default profile
    var isDefault: Bool
    /// The model selected for this profile (e.g. "google/gemini-2.5-flash:free")
    var selectedModel: String

    /// The Keychain key where this profile's API key is stored.
    /// Format: "com.nox.luma.apikey.<profile-id>"
    var keychainAPIKeyIdentifier: String {
        "com.nox.luma.apikey.\(id.uuidString)"
    }

    /// The effective base URL: uses the provider's default if baseURL is empty.
    var effectiveBaseURL: String {
        baseURL.isEmpty ? provider.defaultBaseURL : baseURL
    }

    init(id: UUID = UUID(), name: String, provider: LumaAPIProvider, baseURL: String = "", isDefault: Bool = false, selectedModel: String = "") {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.isDefault = isDefault
        self.selectedModel = selectedModel
    }
}

// MARK: - ProfileManager

/// Manages the collection of LumaAPIProfile objects.
/// Profile metadata (names, providers, models) is stored in UserDefaults.
/// Each profile's API key is stored separately in the Keychain.
@MainActor
final class ProfileManager: ObservableObject {

    static let shared = ProfileManager()

    // Profile metadata (names, providers, models — not sensitive) live in UserDefaults.
    // This avoids repeated Keychain password prompts just for loading profile list data.
    private let profilesUserDefaultsKey = "com.nox.luma.profiles"

    // Legacy key used when profiles were mistakenly stored in Keychain.
    // Kept for one-time migration only.
    private let profilesKeychainKey = "com.nox.luma.profiles"

    /// All stored profiles, ordered (default profile first).
    @Published private(set) var profiles: [LumaAPIProfile] = []

    /// The currently active (default) profile, if any.
    var activeProfile: LumaAPIProfile? {
        profiles.first(where: { $0.isDefault }) ?? profiles.first
    }

    // In-memory cache of loaded API keys so Keychain is only hit once per key.
    // Cleared when profiles are deleted or reset.
    private var apiKeyCache: [UUID: String] = [:]

    private init() {
        loadProfiles()
    }

    // MARK: - Profile CRUD

    /// Adds a new profile. If it's the first profile, marks it as default.
    func addProfile(_ profile: LumaAPIProfile) {
        var newProfile = profile
        if profiles.isEmpty { newProfile.isDefault = true }
        profiles.append(newProfile)
        saveProfiles()
    }

    /// Updates an existing profile (matched by id).
    func updateProfile(_ updatedProfile: LumaAPIProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == updatedProfile.id }) else { return }
        profiles[index] = updatedProfile
        saveProfiles()
    }

    /// Deletes a profile and its API key from the vault.
    func deleteProfile(withID profileID: UUID) throws {
        guard profiles.first(where: { $0.id == profileID }) != nil else { return }
        VaultManager.shared.removeAPIKey(for: profileID)
        apiKeyCache.removeValue(forKey: profileID)
        profiles.removeAll(where: { $0.id == profileID })
        // If we removed the default, promote the first remaining profile
        if !profiles.isEmpty && !profiles.contains(where: { $0.isDefault }) {
            profiles[0].isDefault = true
        }
        saveProfiles()
    }

    /// Sets the given profile as the default, unsets all others.
    func setDefaultProfile(withID profileID: UUID) {
        for index in profiles.indices {
            profiles[index].isDefault = (profiles[index].id == profileID)
        }
        saveProfiles()
    }

    // MARK: - API Key Storage

    /// Saves the API key for a profile to the vault and updates the in-memory cache.
    func saveAPIKey(_ apiKey: String, forProfileID profileID: UUID) throws {
        guard profiles.first(where: { $0.id == profileID }) != nil else { return }
        try VaultManager.shared.setAPIKey(apiKey, for: profileID)
        apiKeyCache[profileID] = apiKey
    }

    /// Loads the API key for a profile. Served from in-memory cache after the first
    /// vault read so Keychain is never accessed more than once per session.
    func loadAPIKey(forProfileID profileID: UUID) -> String? {
        if let cached = apiKeyCache[profileID] { return cached }
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return nil }

        // Try the vault (current storage)
        if let key = VaultManager.shared.apiKey(for: profileID) {
            apiKeyCache[profileID] = key
            return key
        }

        // Lazy migration: key was stored in the old per-profile Keychain item
        if let key = try? KeychainManager.loadString(key: profile.keychainAPIKeyIdentifier) {
            try? VaultManager.shared.setAPIKey(key, for: profileID)
            try? KeychainManager.delete(key: profile.keychainAPIKeyIdentifier)
            apiKeyCache[profileID] = key
            return key
        }

        return nil
    }

    /// Loads the API key for the active profile.
    func loadActiveAPIKey() -> String? {
        guard let activeProfile = activeProfile else { return nil }
        return loadAPIKey(forProfileID: activeProfile.id)
    }

    /// Deletes all profiles and their API keys (used by Reset Luma).
    func deleteAllProfiles() throws {
        apiKeyCache.removeAll()
        VaultManager.shared.clearAllAPIKeys()
        profiles = []
        UserDefaults.standard.removeObject(forKey: profilesUserDefaultsKey)
        // Clean up any legacy Keychain entries
        try? KeychainManager.delete(key: profilesKeychainKey)
    }

    // MARK: - Persistence

    private func saveProfiles() {
        guard let encoded = try? JSONEncoder().encode(profiles) else { return }
        // Profile metadata is not sensitive — store in UserDefaults to avoid
        // Keychain password prompts on every profile list read.
        UserDefaults.standard.set(encoded, forKey: profilesUserDefaultsKey)
    }

    private func loadProfiles() {
        // Prefer UserDefaults (current storage)
        if let data = UserDefaults.standard.data(forKey: profilesUserDefaultsKey),
           let decoded = try? JSONDecoder().decode([LumaAPIProfile].self, from: data) {
            profiles = decoded
            return
        }

        // Migration path: profiles were previously stored in Keychain.
        // Move them to UserDefaults on first load, then remove the Keychain entry.
        guard
            let data = try? KeychainManager.load(key: profilesKeychainKey),
            let decoded = try? JSONDecoder().decode([LumaAPIProfile].self, from: data)
        else { return }

        profiles = decoded
        saveProfiles()  // Write to UserDefaults
        try? KeychainManager.delete(key: profilesKeychainKey)  // Clean up Keychain
    }
}
