import Foundation
@preconcurrency import Combine

/// Manages the optional 6-digit PIN that protects access to Luma settings.
/// The PIN is stored in the Keychain under the "com.nox.luma.pin" key.
@MainActor
final class PINManager: ObservableObject {

    static let shared = PINManager()

    /// True if the user has set a PIN.
    @Published private(set) var hasPIN: Bool = false

    private init() {
        hasPIN = VaultManager.shared.hasPIN
    }

    // MARK: - PIN Operations

    /// Saves a new 6-digit PIN to the vault.
    func setPIN(_ pin: String) throws {
        guard pin.count == 6, pin.allSatisfy({ $0.isNumber }) else {
            throw PINError.invalidPINFormat
        }
        try VaultManager.shared.setPIN(pin)
        hasPIN = true
    }

    /// Returns true if the provided PIN matches the stored PIN.
    func validatePIN(_ enteredPIN: String) -> Bool {
        VaultManager.shared.validatePIN(enteredPIN)
    }

    /// Removes the PIN (user can access settings without PIN after this).
    func clearPIN() throws {
        try VaultManager.shared.clearPIN()
        hasPIN = false
    }

    // MARK: - Errors

    enum PINError: Error, LocalizedError {
        case invalidPINFormat

        var errorDescription: String? {
            "PIN must be exactly 6 digits."
        }
    }
}
