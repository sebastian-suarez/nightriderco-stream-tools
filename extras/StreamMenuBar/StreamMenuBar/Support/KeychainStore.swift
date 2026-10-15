//
//  KeychainStore.swift
//  StreamMenuBar
//

import Foundation
import Security

/// Generic-password items in the user's login keychain, one per `account`. The app's code
/// signature (team + bundle ID) is the item ACL, so rebuilds keep access without prompts.
/// (The data-protection keychain would need a keychain-access-groups entitlement, which this
/// project does not have.) The SecItem API is thread-safe, so this can be used from any isolation.
nonisolated struct KeychainStore: Sendable {
    let service: String

    static let app = KeychainStore(service: "dev.sebastiansuarez.StreamMenuBar")

    func data(for account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status, operation: "read")
        }
    }

    func set(_ data: Data, for account: String) throws {
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError(status: updateStatus, operation: "update")
            }
        default:
            throw KeychainError(status: status, operation: "add")
        }
    }

    /// Removing an item that does not exist is not an error.
    func remove(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete")
        }
    }

    func value<Value: Decodable>(_ type: Value.Type, for account: String) throws -> Value? {
        guard let data = try data(for: account) else { return nil }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func set<Value: Encodable>(_ value: Value, for account: String) throws {
        try set(JSONEncoder().encode(value), for: account)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

nonisolated struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain \(operation) failed: \(message) (\(status))"
    }
}
