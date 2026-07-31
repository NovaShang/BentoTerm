import Foundation
import Crypto

/// Generates a new ed25519 SSH key pair and renders the public key in
/// OpenSSH's `authorized_keys` line format so the user can paste it onto
/// the server.
enum SSHKeyGenerator {
    struct GeneratedKey {
        /// 32-byte raw private key bytes — what Citadel's
        /// `Curve25519.Signing.PrivateKey(rawRepresentation:)` expects.
        let privateKeyData: Data
        /// `ssh-ed25519 AAAA... comment` — paste this into authorized_keys.
        let openSSHPublicKey: String
        /// Suggested keychain label.
        let label: String
    }

    /// Generate a new ed25519 key pair.
    /// - Parameter comment: Trailing comment in the public-key line. Defaults
    ///   to `bento@<host>` when called from a host edit screen.
    static func generate(comment: String) -> GeneratedKey {
        let priv = Curve25519.Signing.PrivateKey()
        let privBytes = priv.rawRepresentation
        let pubBytes = priv.publicKey.rawRepresentation

        // Wire format (string "ssh-ed25519" ‖ string <32 key bytes>) is shared
        // with the relay pairing path — see SSHKey in RelayPairingService.swift.
        let payload = SSHKey.ed25519WireFormat(rawPublicKey: pubBytes)
        let base64 = payload.base64EncodedString()
        let openSSHLine = "ssh-ed25519 \(base64) \(comment)"

        // Stable label: short hash of the public key.
        let suffix = pubBytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        let label = "bento-\(suffix).pub"

        return GeneratedKey(
            privateKeyData: privBytes,
            openSSHPublicKey: openSSHLine,
            label: label
        )
    }
}
