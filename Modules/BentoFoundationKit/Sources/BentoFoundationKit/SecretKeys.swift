import Foundation

/// The keychain account names secrets are stored under, spelled once.
///
/// These strings ARE the stored data's address: a key built any other way
/// reads back empty and the user is asked again for a password that is
/// sitting right there. Never change one without migrating what's stored.
public enum SecretKeys {
    /// The password `ssh` asks for, per host alias (iOS: the host's name, Mac:
    /// the ssh-config alias — the same thing seen from each side).
    public static func sshPassword(host: String) -> String {
        "sshPassword:\(host)"
    }

    /// A key's passphrase — per key file, not per host: one key opens many
    /// hosts.
    public static func sshPassphrase(keyPath: String) -> String {
        "sshPassphrase:\(keyPath)"
    }

    /// The remote Mac's login-keychain password, used to unlock it after
    /// connecting.
    public static func macKeychain(hostID: UUID) -> String {
        "macKeychain:\(hostID.uuidString)"
    }
}
