import Foundation
import Security

enum KeychainError: LocalizedError {
    case duplicateItem
    case itemNotFound
    case unexpectedStatus(OSStatus)
    case dataConversionFailed

    var errorDescription: String? {
        switch self {
        case .duplicateItem: return "Item already exists in Keychain."
        case .itemNotFound: return "Item not found in Keychain."
        case .unexpectedStatus(let status): return "Keychain error: \(status)"
        case .dataConversionFailed: return "Failed to convert Keychain data."
        }
    }
}

final class KeychainService: Sendable {
    static let shared = KeychainService()
    private let service = "com.novashang.bento.ssh"

    private init() {}

    // MARK: - Password

    func savePassword(_ password: String, for account: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.dataConversionFailed
        }
        try saveData(data, for: account, type: "password")
    }

    func loadPassword(for account: String) throws -> String {
        let data = try loadData(for: account, type: "password")
        guard let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataConversionFailed
        }
        return password
    }

    func deletePassword(for account: String) throws {
        try deleteData(for: account, type: "password")
    }

    // MARK: - Private Key

    func savePrivateKey(_ keyData: Data, label: String) throws {
        try saveData(keyData, for: label, type: "privatekey")
    }

    func loadPrivateKey(label: String) throws -> Data {
        return try loadData(for: label, type: "privatekey")
    }

    func deletePrivateKey(label: String) throws {
        try deleteData(for: label, type: "privatekey")
    }

    // MARK: - Internal

    private func saveData(_ data: Data, for account: String, type: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(type):\(account)",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "\(type):\(account)",
            ]
            let updateAttrs: [String: Any] = [
                kSecValueData as String: data,
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func loadData(for account: String, type: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(type):\(account)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }
        return data
    }

    private func deleteData(for account: String, type: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(type):\(account)",
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
