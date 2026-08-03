import Foundation

/// The catalog of one-shot coach marks. Each case's rawValue is its
/// UserDefaults key; bump the `.vN` suffix to re-trigger a tip after a
/// meaningful redesign (same pattern as GestureOnboardingOverlay).
public enum BentoTip: String, CaseIterable, Sendable {
    /// "It's working — you can open another one." First agent working ≥ 10s.
    case parallelSecondAgent = "tip.parallel_second_agent.v1"
    /// "This is parallel — whoever needs you changes color." Two panes working.
    case parallelBothWorking = "tip.parallel_both_working.v1"
    /// The 4-color state legend. First time any pane hits awaiting-input.
    case stateLegend = "tip.state_legend.v1"
    /// iPad/Mac sidebar first shown with ≥ 2 windows.
    case sidebarIntro = "tip.sidebar_intro.v1"
    /// iPhone bottom window tabs first shown.
    case windowTabsIntro = "tip.window_tabs.v1"
    /// Right-swipe review / left-swipe NL→command. After 3rd voice send.
    case voiceAdvanced = "tip.voice_advanced.v1"
    /// Parallel|Focus segmented control blue-dot intro.
    case modeToggleIntro = "tip.mode_toggle.v1"
    /// "Agents kept working while you were away." First reconnect.
    case persistence = "tip.persistence.v1"
    /// Phone auto-switched a tiled session to Focus on first open.
    case focusAutoSwitch = "tip.focus_auto_switch.v1"
    /// Chinese system → suggest the Qwen engine once, after first voice send.
    case qwenSuggestion = "tip.qwen_suggestion.v1"
    /// First tap swallowed by a program that turned on mouse tracking — says
    /// where Bento's own tap went (two fingers). Invisible otherwise.
    case mouseGrabbed = "tip.mouse_grabbed.v1"
}

/// TipCenter is the single ledger for in-context teaching moments: each tip
/// fires once per install, at the moment the user first meets the feature
/// (design doc §6 — "teach at the moment of use, not up front"). Views ask
/// `shouldShow`, present their own UI, and `markShown` on dismiss.
/// Settings → Help can `resetAll()` to replay the whole curriculum.
@MainActor
public final class TipCenter: ObservableObject {
    public static let shared = TipCenter()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func shouldShow(_ tip: BentoTip) -> Bool {
        !defaults.bool(forKey: tip.rawValue)
    }

    public func markShown(_ tip: BentoTip) {
        defaults.set(true, forKey: tip.rawValue)
        // Some tips fire at exactly the funnel moments the opt-in telemetry
        // wants to count (first amber pane, first parallel pair, first
        // reconnect, mode-toggle discovery). Recording here keeps those
        // signals without touching the view code that shows the tip.
        // No-op unless the user opted in.
        if let event = Self.telemetryEvent(for: tip) {
            TelemetryService.shared.record(event)
        }
        objectWillChange.send()
    }

    /// Tip → telemetry-event mapping for the one-shot teaching moments that
    /// double as funnel milestones. Tips fire once per install, so these
    /// events inherit the same once-only semantics.
    private static func telemetryEvent(for tip: BentoTip) -> TelemetryEvent? {
        switch tip {
        case .stateLegend: return .stateAwaitingFirstSeen
        case .parallelBothWorking: return .secondAgentOpened
        case .persistence: return .reconnectResumed
        case .modeToggleIntro: return .modeToggled
        default: return nil
        }
    }

    /// Consume in one step: true (and marks shown) the first time only.
    /// For fire-and-forget moments like toasts where there is no dismiss.
    public func consume(_ tip: BentoTip) -> Bool {
        guard shouldShow(tip) else { return false }
        markShown(tip)
        return true
    }

    /// Replay every tip (Settings → Help). One-shot keys owned by other
    /// subsystems (e.g. the iOS gesture overlay's `storageKey`) are passed in
    /// by the caller — TipCenter is the ledger for BentoTips, not for every
    /// app-specific flag.
    public func resetAll(extraKeys: [String] = []) {
        for tip in BentoTip.allCases {
            defaults.removeObject(forKey: tip.rawValue)
        }
        defaults.removeObject(forKey: Self.voiceSendCountKey)
        for key in extraKeys {
            defaults.removeObject(forKey: key)
        }
        objectWillChange.send()
    }

    // MARK: - Counters

    /// Successful voice sends, for pacing the advanced-gesture tip (fires on
    /// the 3rd send — after the basic gesture is muscle memory, not before).
    public static let voiceSendCountKey = "tip.voice_send_count"

    @discardableResult
    public func recordVoiceSend() -> Int {
        let n = defaults.integer(forKey: Self.voiceSendCountKey) + 1
        defaults.set(n, forKey: Self.voiceSendCountKey)
        return n
    }

    public var recordedVoiceSendCount: Int {
        defaults.integer(forKey: Self.voiceSendCountKey)
    }
}
