import Foundation

/// The two one-shot notices left. Each case's rawValue is its UserDefaults
/// key; bump the `.vN` suffix to show one again after a meaningful change.
///
/// Both explain something the app did that nothing on screen shows, the one
/// time it first happens. Teaching a feature before it is used is not what
/// these are for — that layer was removed.
public enum BentoTip: String, CaseIterable, Sendable {
    /// Phone auto-switched a tiled session to Focus on first open.
    case focusAutoSwitch = "tip.focus_auto_switch.v1"
    /// First tap handed to a program that turned on mouse tracking — links and
    /// paths still answer to one finger, so this only names the two-finger tap
    /// for everything else. A program holding the mouse is invisible otherwise.
    case mouseGrabbed = "tip.mouse_grabbed.v1"
}

/// The ledger for `BentoTip`: each fires once per install.
@MainActor
public final class TipCenter {
    public static let shared = TipCenter()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True (and marks shown) the first time only.
    public func consume(_ tip: BentoTip) -> Bool {
        guard !defaults.bool(forKey: tip.rawValue) else { return false }
        defaults.set(true, forKey: tip.rawValue)
        return true
    }
}
