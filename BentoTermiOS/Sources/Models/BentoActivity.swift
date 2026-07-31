import ActivityKit
import Foundation

/// ActivityKit attributes for the aggregate Bento Live Activity.
/// One activity summarizes all live sessions; the lock screen / Dynamic
/// Island show counts plus a per-host status list.
struct BentoActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        struct SessionSummary: Codable, Hashable {
            let hostID: String
            let hostName: String
            let status: Status
            let awaitingPanes: Int
        }

        enum Status: String, Codable, Hashable {
            case active
            case connecting
            case suspended
            case disconnected
        }

        var sessions: [SessionSummary]
        var totalAwaiting: Int
        var totalSessions: Int
        var latestPrompt: String
        var lastUpdate: Date
    }
}
