import Foundation
import Security

public enum KeychainStoreError: Error, LocalizedError, Equatable, Sendable {
    case keychainStatus(OSStatus)
    case invalidStoredValue

    public var errorDescription: String? {
        switch self {
        case .keychainStatus(let status): "Keychain operation failed (status \(status))."
        case .invalidStoredValue: "The stored API key is not valid UTF-8."
        }
    }
}

/// Stores only the user's direct Anthropic API key. Claude subscription OAuth
/// credentials stay owned and managed by the unmodified Claude Code CLI.
public final class KeychainStore: @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "com.lectern.ai", account: String = "anthropic-api-key") {
        self.service = service
        self.account = account
    }

    public func loadAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.keychainStatus(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidStoredValue
        }
        return key
    }

    public func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.configuration("API key cannot be empty.") }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainStoreError.keychainStatus(status) }

        var item = baseQuery
        for (name, value) in attributes { item[name] = value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainStoreError.keychainStatus(addStatus) }
    }

    public func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.keychainStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
