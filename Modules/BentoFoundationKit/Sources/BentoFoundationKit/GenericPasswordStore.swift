import Foundation
import Security

/// One keychain service's generic-password items: read, write (add or
/// update), delete, list. The Mac (answers to ssh prompts) and iOS (host
/// passwords and private keys for its own SSH stack) each keep one, under
/// their own service name and accessibility; both used to hand-build the
/// same SecItem dictionaries.
///
/// The service string and the account names are the stored data's address —
/// see `SecretKeys`. Changing either strands what users already saved.
public struct GenericPasswordStore: Sendable {
    public enum Accessibility: Sendable {
        /// Survives a locked screen (a Mac reconnecting unattended); never
        /// leaves the device.
        case afterFirstUnlockThisDeviceOnly
        /// Readable only while unlocked; never leaves the device.
        case whenUnlockedThisDeviceOnly

        var secValue: CFString {
            switch self {
            case .afterFirstUnlockThisDeviceOnly: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case .whenUnlockedThisDeviceOnly: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case notFound
        case status(OSStatus)
    }

    public let service: String
    public let accessibility: Accessibility

    public init(service: String, accessibility: Accessibility) {
        self.service = service
        self.accessibility = accessibility
    }

    /// The item's address — class, service, account. Every operation starts
    /// from this, so a read can never look somewhere a write didn't put it.
    func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read(_ account: String) throws -> Data {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw status == errSecItemNotFound ? Failure.notFound : Failure.status(status)
        }
        return data
    }

    /// Add, or replace the data of an existing item. Accessibility is set on
    /// add only — an update keeps whatever the item was created with.
    public func write(_ data: Data, _ account: String) throws {
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = accessibility.secValue
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updated = SecItemUpdate(query(account) as CFDictionary,
                                        [kSecValueData as String: data] as CFDictionary)
            guard updated == errSecSuccess else { throw Failure.status(updated) }
        } else if status != errSecSuccess {
            throw Failure.status(status)
        }
    }

    /// Deleting what isn't there succeeds — the caller wanted it gone.
    public func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.status(status)
        }
    }

    /// Every account name stored under this service.
    public func accounts() -> [String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: Strings

    public func readString(_ account: String) throws -> String {
        guard let s = String(data: try read(account), encoding: .utf8) else {
            throw Failure.status(errSecDecode)
        }
        return s
    }

    public func writeString(_ value: String, _ account: String) throws {
        try write(Data(value.utf8), account)
    }
}
