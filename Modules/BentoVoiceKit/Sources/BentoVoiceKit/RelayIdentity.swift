import Foundation

/// Identifies this install to the bundled relay so the free voice quota can be
/// counted per install (30 min of audio a day) instead of per IP address.
///
/// Deliberately NOT the telemetry install id: that one is consent-bound and is
/// deleted the moment the user opts out of telemetry, and reusing it would make
/// a metering counter double as an analytics identifier. This id exists only so
/// the relay can count seconds; it is random, local, and never travels with an
/// event, an account, or a device identifier.
///
/// BYOK requests don't carry it — those go straight to the vendor on the user's
/// own key and the relay never sees them.
public enum RelayInstall {
    /// UserDefaults key. Stable across launches; a reinstall mints a new id.
    static let storageKey = "relay_install_id"

    /// Header the relay reads. Missing/malformed → the relay falls back to
    /// metering by IP address, which is shared and therefore stricter in
    /// practice; shipped builds that predate this header keep working.
    static let header = "x-bento-install"

    private static let lock = NSLock()

    /// Minted lazily on first zero-config voice call.
    public static func id(defaults: UserDefaults = .standard) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = defaults.string(forKey: storageKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: storageKey)
        return fresh
    }

    /// Stamp a relay-bound request. No-op for BYOK callers by construction —
    /// only the relay paths call this.
    public static func stamp(_ request: inout URLRequest, defaults: UserDefaults = .standard) {
        request.setValue(id(defaults: defaults), forHTTPHeaderField: header)
    }
}

/// A refusal from the relay's quota gate, in the shape both the WebSocket error
/// frame and the HTTP 429 body use. Kept in one place so the copy is written
/// once — the relay reports the machine-readable reason, the app owns the words.
public struct RelayQuotaError: LocalizedError, Equatable, Sendable {
    public enum Reason: String, Sendable {
        /// This install spent its daily free minutes.
        case quotaExhausted = "quota_exhausted"
        /// Everyone's shared daily budget is spent — rare, and not the user's fault.
        case globalQuota = "global_quota"
        /// Too many installs claimed from one address in a day.
        case tooManyInstalls = "too_many_installs"
        /// One clip carried more audio than a single utterance plausibly can.
        case clipTooLong = "clip_too_long"
    }

    public let reason: Reason
    /// Seconds until the quota window rolls over. 0 when the relay didn't say.
    public let resetSeconds: Int

    public init(reason: Reason, resetSeconds: Int = 0) {
        self.reason = reason
        self.resetSeconds = resetSeconds
    }

    /// Parse a relay error payload — the `error` object of a WS error frame, or
    /// the body of a 429. Returns nil for anything that isn't a quota refusal.
    public static func from(payload: [String: Any]) -> RelayQuotaError? {
        let code = (payload["code"] as? String) ?? (payload["error"] as? String) ?? ""
        guard let reason = Reason(rawValue: code) else { return nil }
        let reset = (payload["reset_seconds"] as? Int)
            ?? (payload["reset_seconds"] as? NSNumber)?.intValue ?? 0
        return RelayQuotaError(reason: reason, resetSeconds: reset)
    }

    public var errorDescription: String? {
        switch reason {
        case .quotaExhausted:
            return "Free voice recognition is used up for today\(waitClause). "
                + "Add your own key in Settings → Speech to keep going."
        case .globalQuota:
            return "Free voice recognition is paused for today\(waitClause). "
                + "Add your own key in Settings → Speech to keep going."
        case .tooManyInstalls:
            return "Too many installs are sharing this network's free voice quota. "
                + "Add your own key in Settings → Speech."
        case .clipTooLong:
            return "That recording is too long to transcribe. Record it in shorter takes."
        }
    }

    /// "(back in 3h)" — only when the relay told us, and only in whole hours or
    /// minutes. A countdown to the second reads like a punishment timer.
    private var waitClause: String {
        guard resetSeconds > 0 else { return "" }
        if resetSeconds >= 3600 { return " (back in \(resetSeconds / 3600)h)" }
        return " (back in \(max(1, resetSeconds / 60))m)"
    }
}
