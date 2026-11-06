import Foundation
import BentoFoundationKit

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
    private let store = GenericPasswordStore(service: "com.novashang.bento.ssh",
                                             accessibility: .whenUnlockedThisDeviceOnly)

    private init() {}

    // MARK: - Password

    func savePassword(_ password: String, for account: String) throws {
        try saveData(Data(password.utf8), for: account, type: "password")
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

    /// Delete every stored private key whose label starts with `prefix`.
    /// Used once at launch to reclaim the per-device keys that the removed
    /// pairing flow minted: nothing reads them any more, and a private key
    /// with no owner is a liability, not a spare.
    /// Returns the number of items removed.
    @discardableResult
    func deletePrivateKeys(labelPrefix prefix: String) -> Int {
        var removed = 0
        for account in store.accounts() where account.hasPrefix("privatekey:\(prefix)") {
            let label = String(account.dropFirst("privatekey:".count))
            if (try? deletePrivateKey(label: label)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - Internal

    private func saveData(_ data: Data, for account: String, type: String) throws {
        try mapped { try store.write(data, "\(type):\(account)") }
    }

    private func loadData(for account: String, type: String) throws -> Data {
        try mapped { try store.read("\(type):\(account)") }
    }

    private func deleteData(for account: String, type: String) throws {
        try mapped { try store.delete("\(type):\(account)") }
    }

    /// The store's failures in this app's error vocabulary.
    private func mapped<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch GenericPasswordStore.Failure.notFound {
            throw KeychainError.itemNotFound
        } catch GenericPasswordStore.Failure.status(let status) {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

// MARK: - Host Credentials

/// The Keychain, as the host form and the host store need it: which secrets a
/// host has, and the rules for changing them.
///
/// Everything goes through injectable closures because the Keychain is not
/// reachable from a unit test — the rules below are the part worth testing,
/// and they are the part that used to be wrong.
struct HostCredentialStore: Sendable {
    /// nil = nothing stored under that account.
    var load: @Sendable (_ account: String) -> String?
    var write: @Sendable (_ secret: String, _ account: String) throws -> Void
    var remove: @Sendable (_ account: String) throws -> Void

    static let keychain = HostCredentialStore(
        load: { try? KeychainService.shared.loadPassword(for: $0) },
        write: { try KeychainService.shared.savePassword($0, for: $1) },
        remove: { try KeychainService.shared.deletePassword(for: $0) }
    )

    // MARK: Account keys
    //
    // These have to match SSHService (`loadPassword(for: host.id.uuidString)`)
    // and SessionManager byte for byte. Host.id is a fresh random UUID for
    // every host, so a key derived any other way reads back empty and the
    // form reports "not saved" for a password that is sitting right there.

    static func passwordAccount(for hostID: UUID) -> String {
        hostID.uuidString
    }

    static func macKeychainAccount(for hostID: UUID) -> String {
        SecretKeys.macKeychain(hostID: hostID)
    }

    // MARK: Queries

    func hasPassword(for hostID: UUID) -> Bool {
        isStored(Self.passwordAccount(for: hostID))
    }

    func hasMacKeychainPassword(for hostID: UUID) -> Bool {
        isStored(Self.macKeychainAccount(for: hostID))
    }

    /// An empty stored string counts as "nothing stored": builds before this
    /// change could overwrite a real password with "" (see savePassword), and
    /// an empty secret is never a usable one anyway.
    private func isStored(_ account: String) -> Bool {
        guard let secret = load(account) else { return false }
        return !secret.isEmpty
    }

    // MARK: Mutations

    /// Store what the user typed, or keep what is already stored if the field
    /// was left blank.
    ///
    /// The SecureField is never seeded with the stored secret (plaintext must
    /// not travel back into the UI), so blank can only mean "unchanged".
    /// Passing "" down to the Keychain would take the SecItemUpdate path and
    /// replace the real password with an empty string — a silent, permanent
    /// loss the user cannot see until the next connect fails.
    func savePassword(_ typed: String, for hostID: UUID) throws {
        guard !typed.isEmpty else { return }
        try write(typed, Self.passwordAccount(for: hostID))
    }

    /// Same blank-means-unchanged rule as `savePassword`.
    func saveMacKeychainPassword(_ typed: String, for hostID: UUID) throws {
        guard !typed.isEmpty else { return }
        try write(typed, Self.macKeychainAccount(for: hostID))
    }

    func clearPassword(for hostID: UUID) throws {
        try remove(Self.passwordAccount(for: hostID))
    }

    func clearMacKeychainPassword(for hostID: UUID) throws {
        try remove(Self.macKeychainAccount(for: hostID))
    }

    /// Drop every secret that belongs to this host alone — used when the host
    /// is deleted. Private keys are deliberately untouched: their account key
    /// is the key file's name (`privatekey:id_ed25519`), so any number of
    /// hosts can be pointing at the same entry, and deleting one host's key
    /// would log the others out.
    func forgetAll(for hostID: UUID) {
        try? clearPassword(for: hostID)
        try? clearMacKeychainPassword(for: hostID)
    }
}
