import Foundation
import Security

/// Secrets `ssh` asks for and the user chose to remember: account passwords and
/// key passphrases. One generic-password item per key, in the login keychain.
///
/// Deliberately small and separate from the iOS `KeychainService`: that one also
/// stores private keys for the iOS app's own SSH stack, which the Mac does not
/// have — the Mac shells out to `ssh` and lets it use the keys already on disk.
/// The only thing the Mac ever needs to keep is an answer to a prompt.
enum MacKeychain {
    private static let service = "com.bento.term.mac.ssh"

    static func load(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String, _ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            // The Mac may be unattended when a session reconnects, so the secret
            // has to survive a locked screen — but it never leaves this Mac.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            return SecItemUpdate(query as CFDictionary,
                                 [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
