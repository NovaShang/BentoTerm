import Foundation

/// DaemonStatus mirrors rpc.StatusResp returned by `bento status`.
/// Keep field names in sync with desktop/internal/rpc/types.go.
struct DaemonStatus: Codable, Equatable {
    let version: String
    let pid: Int
    let uptimeSec: Int64
    let relayURL: String?
    let relayConnected: Bool
    let daemonID: String?
    let pairedDevices: Int

    enum CodingKeys: String, CodingKey {
        case version
        case pid
        case uptimeSec = "uptime_sec"
        case relayURL = "relay_url"
        case relayConnected = "relay_connected"
        case daemonID = "daemon_id"
        case pairedDevices = "paired_devices"
    }
}

struct PairedDevice: Codable, Identifiable, Equatable {
    let deviceID: String
    let label: String?
    let pairedAt: Int64
    let keyFingerprint: String

    var id: String { deviceID }
    var pairedDate: Date { Date(timeIntervalSince1970: TimeInterval(pairedAt)) }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case label
        case pairedAt = "paired_at"
        case keyFingerprint = "key_fingerprint"
    }
}

