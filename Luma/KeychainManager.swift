import Foundation
import Security

/// Manages secure storage of sensitive data (API keys, PIN) in the macOS Keychain.
/// Service identifier: "com.nox.luma"
enum KeychainManager {

    static let serviceName = "com.nox.luma"

    // MARK: - Errors

    enum KeychainError: Error, LocalizedError {
        case unhandledError(status: OSStatus)
        case dataConversionFailed
        case itemNotFound

        var errorDescription: String? {
            switch self {
            case .unhandledError(let status):
                return "Keychain error with status: \(status)"
            case .dataConversionFailed:
                return "Failed to convert data to/from Keychain format"
            case .itemNotFound:
                return "Item not found in Keychain"
            }
        }
    }

    // MARK: - Core Operations

    /// Saves data to the Keychain under the given key.
    /// If an item with the same key already exists, it is updated.
    static func save(key: String, data: Data) throws {
        // Build the base query identifying the item
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        // kSecAttrAccessibleAfterFirstUnlock: accessible after the device is unlocked
        // once after a reboot, without prompting the user again. Applied on both add
        // and update so pre-existing items written before this policy was enforced
        // also get upgraded, preventing Keychain prompts on every launch.
        let accessibilityPolicy = kSecAttrAccessibleAfterFirstUnlock

        // First try to update an existing item (also updates its accessibility policy)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibilityPolicy
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        } else if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet — add it.
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessibilityPolicy
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandledError(status: addStatus)
            }
        } else {
            throw KeychainError.unhandledError(status: updateStatus)
        }
    }

    /// Convenience: saves a String value to the Keychain.
    static func save(key: String, string: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw KeychainError.dataConversionFailed
        }
        try save(key: key, data: data)
    }

    /// Loads data from the Keychain for the given key.
    /// Throws `KeychainError.itemNotFound` if the key does not exist.
    static func load(key: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unhandledError(status: status)
        }
        return data
    }

    /// Convenience: loads a String value from the Keychain.
    static func loadString(key: String) throws -> String {
        let data = try load(key: key)
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataConversionFailed
        }
        return string
    }

    /// Deletes an item from the Keychain. Silently succeeds if the item doesn't exist.
    static func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    /// Deletes all Luma items from the Keychain (used by "Reset Luma").
    static func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }
}
