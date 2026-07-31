import Foundation
import CryptoKit

/// RelayPairingService talks to the Bento relay's /v1/pair endpoint.
///
/// Flow (matches relay/src/daemon-do.ts handlePair):
///   1. User opens "Pair iPhone" on the Mac → daemon mints a 6-digit code.
///   2. iOS calls `pair(code:label:)`:
///        a. Generates a fresh Ed25519 keypair (`Curve25519.Signing`).
///        b. Encodes the public key in SSH wire format (ssh-ed25519 || raw).
///        c. POSTs {code, device_pubkey, device_label} to the relay.
///        d. Relay forwards to the daemon, daemon installs the key in its
///           authorized_keys and replies with device_id + host_fingerprint.
///   3. We persist the private key in Keychain under a fresh label, then
///      hand back a populated `RelayDaemon` for the store to add.
///
/// The daemon_id the user is pairing with must be supplied — for the MVP
/// the user picks "Pair new daemon" without knowing the id in advance, so
/// the call site asks the relay to enumerate "open pairing windows" first.
/// In v1 we keep it simpler: the user enters BOTH the daemon_id (or its
/// label) AND the 6-digit code. A future "discovery" pass can simplify.
@MainActor
final class RelayPairingService {
    static let shared = RelayPairingService()

    /// Relay base URL string (UserDefaults["relayURL"] override for testing,
    /// else production default). Single source for both the pairing REST calls
    /// and BentoRelayClient's tunnel WSS.
    static var relayBaseURLString: String {
        UserDefaults.standard.string(forKey: "relayURL")
            ?? "https://bento-relay.styleshang.workers.dev"
    }

    /// Default relay URL. Override via UserDefaults["relayURL"] for testing.
    static var relayURL: URL {
        URL(string: relayBaseURLString) ?? URL(string: "https://bento-relay.styleshang.workers.dev")!
    }

    /// Performs the pairing exchange. On success, returns the RelayDaemon
    /// the caller should store (key already persisted in Keychain).
    func pair(daemonID: String, code: String, label: String) async throws -> RelayDaemon {
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            throw PairingError.invalidCode
        }

        // 1. Generate device keypair. Curve25519.Signing IS Ed25519.
        let privKey = Curve25519.Signing.PrivateKey()
        let pubWireFormat = SSHKey.ed25519WireFormat(rawPublicKey: privKey.publicKey.rawRepresentation)
        let pubB64 = pubWireFormat.base64EncodedString()

        // 2. POST to relay.
        var url = Self.relayURL
        url.append(path: "v1/pair")
        url.append(queryItems: [URLQueryItem(name: "daemon_id", value: daemonID)])

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: String] = [
            "code": code,
            "device_pubkey": pubB64,
            "device_label": label,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw PairingError.network("no HTTP response")
        }
        // The relay returns several shapes:
        //   200 { status: "ok", device_id, host_fingerprint }   success
        //   200 { status: "error", error }                       daemon nack
        //   401 { error: "bad code" }                            bad code
        //   429 { error: "pairing locked", retry_after_ms }      brute-force lockout
        //   503 { error: "daemon offline" }                      daemon WSS down
        // Make all fields optional so a non-2xx body decodes cleanly.
        let parsed = (try? JSONDecoder().decode(PairAck.self, from: data)) ?? PairAck()
        guard http.statusCode == 200, parsed.status == "ok" else {
            let msg = parsed.error
                ?? parsed.status.map { "daemon: \($0)" }
                ?? "HTTP \(http.statusCode)"
            throw PairingError.rejected(msg)
        }
        guard let deviceID = parsed.device_id, let fingerprint = parsed.host_fingerprint else {
            throw PairingError.rejected("malformed daemon ack")
        }

        // 3. Persist the private key in Keychain.
        let keyLabel = "relay-device-\(UUID().uuidString)"
        try KeychainService.shared.savePrivateKey(privKey.rawRepresentation, label: keyLabel)

        // If the user didn't type a label, fall back to the computer name
        // the daemon reported (macOS ComputerName, or hostname elsewhere).
        let resolvedLabel = label.isEmpty ? (parsed.daemon_label ?? "") : label

        return RelayDaemon(
            daemonID: daemonID,
            label: resolvedLabel,
            hostFingerprint: fingerprint,
            deviceKeyLabel: keyLabel,
            deviceID: deviceID
        )
    }
}

enum PairingError: LocalizedError {
    case invalidCode
    case network(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidCode: return "Pairing code must be six digits."
        case .network(let m): return "Network error: \(m)"
        case .rejected(let m): return "Pairing rejected: \(m)"
        }
    }
}

/// Matches the daemon's `pair.ack` payload echoed back through the relay,
/// AND the relay's own error responses. Every field is optional so a
/// 401/429/503 body (which only has `error`) still decodes.
private struct PairAck: Decodable {
    var status: String?
    var device_id: String?
    var host_fingerprint: String?
    var daemon_label: String?
    var error: String?
}

/// SSH wire-format helpers. Ed25519 public keys on the wire are:
///   string "ssh-ed25519"          (4-byte big-endian length + bytes)
///   string <32 raw key bytes>     (4-byte big-endian length + 32 bytes)
enum SSHKey {
    static func ed25519WireFormat(rawPublicKey: Data) -> Data {
        var out = Data()
        out.append(sshString("ssh-ed25519"))
        out.append(sshString(rawPublicKey))
        return out
    }

    private static func sshString(_ s: String) -> Data {
        sshString(Data(s.utf8))
    }

    private static func sshString(_ d: Data) -> Data {
        var out = Data()
        var len = UInt32(d.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(d)
        return out
    }
}
