import Foundation
import SwiftUI
@preconcurrency import Combine

// MARK: - LumaAccount Model

/// Represents the local user account for the Luma app.
/// Stored in UserDefaults (non-sensitive; API keys are stored separately in Keychain).
struct LumaAccount: Codable {
    /// Short username used for display and avatar initials (e.g. "nox")
    let username: String
    /// Display name shown in the UI (e.g. "Omoju Oluwamayowa")
    let displayName: String
    /// When the account was created
    let createdAt: Date

    /// The first two characters of displayName, uppercased, used as the avatar initials.
    /// Falls back to the first two characters of username if displayName is too short.
    var avatarInitials: String {
        let source = displayName.count >= 2 ? displayName : username
        return String(source.prefix(2)).uppercased()
    }
}

// MARK: - AccountManager

/// Manages the local Luma user account, persisted in UserDefaults.
/// Observable so SwiftUI views update automatically when the account changes.
@MainActor
final class AccountManager: ObservableObject {

    static let shared = AccountManager()

    private let userDefaultsKey = "com.nox.luma.account"

    /// The current account, or nil if onboarding has not been completed.
    @Published private(set) var currentAccount: LumaAccount?

    private init() {
        loadAccount()
    }

    // MARK: - Account Lifecycle

    /// Creates and persists a new account.
    func createAccount(username: String, displayName: String) {
        let newAccount = LumaAccount(
            username: username.trimmingCharacters(in: .whitespaces).lowercased(),
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            createdAt: Date()
        )
        saveAccount(newAccount)
    }

    /// Updates the display name of the current account.
    func updateDisplayName(_ newDisplayName: String) {
        guard let existingAccount = currentAccount else { return }
        let updatedAccount = LumaAccount(
            username: existingAccount.username,
            displayName: newDisplayName.trimmingCharacters(in: .whitespaces),
            createdAt: existingAccount.createdAt
        )
        saveAccount(updatedAccount)
    }

    /// Clears the account (called by "Reset Luma").
    func deleteAccount() {
        currentAccount = nil
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    // MARK: - Persistence

    private func saveAccount(_ account: LumaAccount) {
        guard let encoded = try? JSONEncoder().encode(account) else { return }
        UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        currentAccount = account
    }

    private func loadAccount() {
        guard
            let data = UserDefaults.standard.data(forKey: userDefaultsKey),
            let account = try? JSONDecoder().decode(LumaAccount.self, from: data)
        else { return }
        currentAccount = account
    }
}

// MARK: - AvatarView

/// Black circle with white initials, used in the CompanionPanelView bottom bar.
struct LumaAvatarView: View {
    let initials: String
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle()
                .fill(DS.Colors.textOnAccent)
                .frame(width: size, height: size)
            Text(initials)
                .font(.system(size: size * 0.35, weight: .semibold))
                .foregroundColor(LumaAccentTheme.current.accent)
        }
    }
}
