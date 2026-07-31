import Foundation

/// The complete collection surface of Bento's opt-in telemetry.
///
/// This list IS the privacy story: a closed enum of bare event names, no
/// associated payloads, no free-form strings. It is shown verbatim to users
/// in the Settings consent UI and mirrored server-side as the relay's
/// allowlist (relay/src/telemetry.ts `CLIENT_EVENTS`) — keep it publishable,
/// and keep the two lists in sync.
///
/// Never add anything that could carry terminal content, commands,
/// transcripts, paths, or hostnames.
public enum TelemetryEvent: String, CaseIterable, Sendable {
    case firstRunStarted = "first_run_started"
    case firstRunCompleted = "first_run_completed"
    case firstRunSkipped = "first_run_skipped"
    case agentWizardLaunched = "agent_wizard_launched"
    case workspaceCreated = "workspace_created"
    case pairingSucceeded = "pairing_succeeded"
    case voiceSend = "voice_send"
    case voiceFirstSend = "voice_first_send"
    case voiceSwipeLeftLLM = "voice_swipe_left_llm"
    case voiceSwipeRightPreview = "voice_swipe_right_preview"
    case secondAgentOpened = "second_agent_opened"
    case modeToggled = "mode_toggled"
    case stateAwaitingFirstSeen = "state_awaiting_first_seen"
    case reconnectResumed = "reconnect_resumed"
    case sshDirectConnected = "ssh_direct_connected"
    /// Fired at most once per calendar day, when the app becomes active.
    case appActiveDay = "app_active_day"
}

/// TelemetryService — privacy-first, opt-in usage counters.
///
/// Principles (matching the product's privacy posture):
///   * Default OFF. Nothing is buffered, stored, or sent until the user
///     flips the explicit consent toggle in Settings.
///   * No third-party SDK. Batches go to the user's own trusted relay
///     (`POST <relay>/v1/telemetry`) and land in Cloudflare Analytics Engine.
///   * Closed collection surface: only `TelemetryEvent` names + a timestamp.
///   * `install_id` is a random UUID with no link to any account or device
///     identifier. It is DELETED the moment the toggle goes off, so opted-out
///     installs hold no identifier at rest; re-opting-in mints a fresh one.
///   * Fire-and-forget: failed sends are dropped — never retried in a loop,
///     never logged with payload contents, never allowed to block UI.
@MainActor
public final class TelemetryService: ObservableObject {
    public static let shared = TelemetryService()

    // MARK: - Storage keys

    public static let enabledKey = "telemetry_enabled"
    private static let installIDKey = "telemetry_install_id"
    private static let lastActiveDayKey = "telemetry_last_active_day"
    private static func onceKey(_ event: TelemetryEvent) -> String {
        "telemetry.once.\(event.rawValue)"
    }

    /// Events that only ever make sense once per install (funnel milestones).
    /// A small UserDefaults ledger dedupes them across launches.
    private static let oneShotEvents: Set<TelemetryEvent> = [
        .firstRunStarted, .firstRunCompleted, .firstRunSkipped,
        .voiceFirstSend, .stateAwaitingFirstSeen, .secondAgentOpened,
    ]

    private static let defaultRelayBaseURL = "https://bento-relay.styleshang.workers.dev"
    private static let flushThreshold = 20
    private static let maxBufferedEvents = 50 // matches the relay's batch cap

    /// Apps that resolve their relay URL outside UserDefaults (the macOS
    /// app reads the daemon's config.json) can install the resolved
    /// value here at launch. Falls back to the `relayURL` UserDefaults
    /// override (iOS test hook), then the production default.
    public static var relayBaseURLOverride: String?

    private let defaults: UserDefaults
    private var buffer: [(name: String, ts: Int)] = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Consent

    /// The user-facing consent switch. Default false. Turning it OFF deletes
    /// the install identifier, the one-shot ledger, and anything buffered —
    /// opted-out installs hold no telemetry state at rest.
    public var enabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.enabledKey)
            if !newValue {
                defaults.removeObject(forKey: Self.installIDKey)
                defaults.removeObject(forKey: Self.lastActiveDayKey)
                for event in TelemetryEvent.allCases {
                    defaults.removeObject(forKey: Self.onceKey(event))
                }
                buffer.removeAll()
            }
        }
    }

    /// Random UUID minted lazily on first use after opt-in; stable while the
    /// toggle stays on; deleted on opt-out (see `enabled`).
    public var installID: String {
        if let existing = defaults.string(forKey: Self.installIDKey) {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: Self.installIDKey)
        return fresh
    }

    // MARK: - Recording

    /// Record an event. No-op while disabled. One-shot events are deduped via
    /// the persistent ledger. Buffered in memory and flushed in batches.
    public func record(_ event: TelemetryEvent) {
        guard enabled else { return }
        if Self.oneShotEvents.contains(event) {
            guard !defaults.bool(forKey: Self.onceKey(event)) else { return }
            defaults.set(true, forKey: Self.onceKey(event))
        }
        buffer.append((name: event.rawValue, ts: Int(Date().timeIntervalSince1970)))
        if buffer.count > Self.maxBufferedEvents {
            buffer.removeFirst(buffer.count - Self.maxBufferedEvents)
        }
        if buffer.count >= Self.flushThreshold {
            flush()
        }
    }

    /// Call when the app becomes active (foreground). Fires `app_active_day`
    /// at most once per calendar day.
    public func appBecameActive() {
        guard enabled else { return }
        let today = Self.dayString(Date())
        guard defaults.string(forKey: Self.lastActiveDayKey) != today else { return }
        defaults.set(today, forKey: Self.lastActiveDayKey)
        record(.appActiveDay)
    }

    /// Send whatever is buffered, then forget it. Call on app-background /
    /// termination (also triggered automatically at the batch threshold).
    /// Fire-and-forget: failures drop the batch — no retry, no logging of
    /// payload contents, no UI impact.
    public func flush() {
        guard enabled, !buffer.isEmpty else { return }
        let events = buffer
        buffer.removeAll()

        let payload: [String: Any] = [
            "v": 1,
            "install_id": installID,
            "platform": Self.platform,
            "app_version": Self.appVersion,
            "events": events.map { ["name": $0.name, "ts": $0.ts] },
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: relayBaseURLString)?.appendingPathComponent("v1/telemetry")
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - Environment

    private var relayBaseURLString: String {
        if let override = Self.relayBaseURLOverride, !override.isEmpty {
            return override
        }
        return defaults.string(forKey: "relayURL") ?? Self.defaultRelayBaseURL
    }

    private static var platform: String {
        #if os(iOS)
        return "ios"
        #else
        return "macos"
        #endif
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func dayString(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}
