import Foundation

public enum AuthMethod: Codable, Hashable, Sendable {
    case password
    case privateKey(keyLabel: String)
}

/// Where the SSH bytes go on the wire. There is exactly one answer today —
/// a TCP connection to `host.hostname:port` — but the transport stays a
/// property of the Host so downstream code (TerminalViewModel, TmuxLister,
/// SessionManager) keeps being written transport-agnostically, and so saved
/// hosts already carry the field if a second way in is ever added.
public enum HostTransport: Codable, Hashable, Sendable {
    /// Plain TCP/SSH to host.hostname:port — what users add via the +
    /// menu's "Add SSH host…" entry. Reaching the machine (VPN, Tailscale,
    /// a jump host) is the user's own ssh plumbing, not ours.
    case directTCP
}

public struct Host: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var port: UInt16
    public var username: String
    public var authMethod: AuthMethod
    public var transport: HostTransport
    public var lastConnected: Date?
    public var lastInputMode: String?
    public var unlockMacKeychain: Bool = false

    public init(
        id: UUID = UUID(),
        name: String = "",
        hostname: String = "",
        port: UInt16 = 22,
        username: String = "root",
        authMethod: AuthMethod = .password,
        transport: HostTransport = .directTCP,
        lastConnected: Date? = nil,
        lastInputMode: String? = nil,
        unlockMacKeychain: Bool = false
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.transport = transport
        self.lastConnected = lastConnected
        self.lastInputMode = lastInputMode
        self.unlockMacKeychain = unlockMacKeychain
    }

    public var displayName: String {
        name.isEmpty ? "\(username)@\(hostname)" : name
    }

    // Lenient decoder — every field defaults if missing (or unreadable) so
    // adding new fields never invalidates previously-saved JSON. When you add
    // a new field to this struct, default it here too.
    //
    // The same leniency is what retires a transport: a `hosts.json` written by
    // a version that had more `HostTransport` cases decodes here with the
    // unknown case falling back to `.directTCP` rather than failing — one host
    // is degraded, the rest of the file still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.hostname = (try? c.decode(String.self, forKey: .hostname)) ?? ""
        self.port = (try? c.decode(UInt16.self, forKey: .port)) ?? 22
        self.username = (try? c.decode(String.self, forKey: .username)) ?? "root"
        // A missing id gets a DETERMINISTIC fallback derived from the address
        // fields — minting `UUID()` here would give a legacy hosts.json entry
        // a brand-new identity on every decode, so the same host would change
        // id across launches (HostStore keys update/delete/markConnected off
        // id, and ids flow into onSessionUpdate/Live Activity).
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? Self.stableID(username: username, hostname: hostname, port: port)
        self.authMethod = (try? c.decode(AuthMethod.self, forKey: .authMethod)) ?? .password
        self.transport = (try? c.decode(HostTransport.self, forKey: .transport)) ?? .directTCP
        self.lastConnected = try? c.decodeIfPresent(Date.self, forKey: .lastConnected)
        self.lastInputMode = try? c.decodeIfPresent(String.self, forKey: .lastInputMode)
        self.unlockMacKeychain = (try? c.decode(Bool.self, forKey: .unlockMacKeychain)) ?? false
    }

    /// Deterministic UUID for a host entry without a stored id, derived from
    /// its immutable address fields (user@host:port): the same legacy entry
    /// decodes to the same id on every launch and platform. Swift's `Hasher`
    /// is randomly seeded per process so it can't be used here; FNV-1a is a
    /// stable, dependency-free 64-bit hash.
    private static func stableID(username: String, hostname: String, port: UInt16) -> UUID {
        let material = "\(username)@\(hostname):\(port)".utf8
        // Two FNV-1a passes with different seeds fill all 16 bytes.
        let h1 = fnv1a(material, seed: 0xCBF2_9CE4_8422_2325)  // FNV-1a offset basis
        let h2 = fnv1a(material, seed: 0x9E37_79B9_7F4A_7C15)  // golden-ratio noise
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8(truncatingIfNeeded: h1 >> (8 * UInt64(i)))
            bytes[8 + i] = UInt8(truncatingIfNeeded: h2 >> (8 * UInt64(i)))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func fnv1a<S: Sequence>(_ bytes: S, seed: UInt64) -> UInt64 where S.Element == UInt8 {
        var h = seed
        for b in bytes {
            h ^= UInt64(b)
            h &*= 0x0000_0100_0000_01B3  // FNV-1a prime
        }
        return h
    }
}
