import Foundation
import BentoFoundationKit

/// Secrets `ssh` asks for and the user chose to remember: account passwords and
/// key passphrases. One generic-password item per key, in the login keychain.
///
/// Deliberately small and separate from the iOS `KeychainService`: that one also
/// stores private keys for the iOS app's own SSH stack, which the Mac does not
/// have — the Mac shells out to `ssh` and lets it use the keys already on disk.
/// The only thing the Mac ever needs to keep is an answer to a prompt.
enum MacKeychain {
    /// The Mac may be unattended when a session reconnects, so the secret has
    /// to survive a locked screen — but it never leaves this Mac.
    private static let store = GenericPasswordStore(
        service: "com.bento.term.mac.ssh", accessibility: .afterFirstUnlockThisDeviceOnly)

    static func load(_ key: String) -> String? {
        try? store.readString(key)
    }

    @discardableResult
    static func save(_ key: String, _ value: String) -> Bool {
        (try? store.writeString(value, key)) != nil
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        (try? store.delete(key)) != nil
    }
}
