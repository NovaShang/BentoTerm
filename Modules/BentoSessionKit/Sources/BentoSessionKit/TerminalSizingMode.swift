import Foundation

/// Who decides how big the tmux window is — a sticky per-session STATE, not a
/// one-shot action.
///
/// It has to be a state because tmux recomputes a window's size from its
/// clients: under the default `window-size latest` the most recently used
/// client wins, so a single "fit it now" push is undone the moment any other
/// attached client (an iPad, a second Bento) is touched. macOS used to offer
/// exactly that one-shot — "Fit Session to This Window" — and it looked like it
/// did nothing.
///
/// It also has to live on the SERVER. The policy was stored per device in
/// `UserDefaults` and re-asserted on every attach, so two devices sharing a
/// session simply overwrote each other's choice — an iPad reconnect issued
/// `set-option -w window-size latest` and silently undid a pin made on the Mac.
/// Every case here maps 1:1 onto tmux's own `window-size` option, which is the
/// only copy of the truth; `TerminalSizingMode.stored` is a display cache for
/// the moment before the first read lands.
public enum TerminalSizingMode: String, Sendable, CaseIterable {
    /// tmux `window-size latest`: whichever client was used most recently sets
    /// the size. Self-healing (touch a device and it fits you again) at the
    /// cost of flipping the window every time you switch devices.
    case tracking
    /// tmux `window-size smallest`: the size is the minimum over all attached
    /// clients. Never flips, but an idle device on the other end of the room
    /// keeps the big screen clamped and only THAT device can release it.
    case smallest
    /// tmux `window-size manual` plus a `resize-window` to the owning device's
    /// grid. Exactly one device governs and the handoff is explicit, which is
    /// what "同一时间有且只有一个影响大小的设备" actually means. Ownership is
    /// recorded server-side (`@bento_size_owner`) and released automatically
    /// when the owning tmux client is no longer attached.
    case thisDevice

    /// The `window-size` value this policy maps to.
    public var tmuxWindowSize: String {
        switch self {
        case .tracking:   return "latest"
        case .smallest:   return "smallest"
        case .thisDevice: return "manual"
        }
    }

    /// Read tmux's own `window-size` back into a policy. `largest` is never
    /// written by Bento; it lands on `.tracking` because both derive the size
    /// from the attached clients rather than from a single owner.
    public static func fromTmuxWindowSize(_ raw: String) -> TerminalSizingMode? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "latest", "largest": return .tracking
        case "smallest":          return .smallest
        case "manual":            return .thisDevice
        default:                  return nil
        }
    }

    public var title: String {
        switch self {
        case .tracking:   return "Follow the Active Device"
        case .smallest:   return "Fit Every Device"
        case .thisDevice: return "Size to This Device"
        }
    }

    /// One line of consequence, shown under the choices. Each says what the
    /// OTHER devices experience, since that is the part a per-device menu
    /// cannot show you.
    public var explanation: String {
        switch self {
        case .tracking:
            return "Whichever device you last used sets the size."
        case .smallest:
            return "Sized to the smallest attached device, so nothing is clipped."
        case .thisDevice:
            return "This device sets the size; others can't change it."
        }
    }

    public var symbol: String {
        switch self {
        case .tracking:   return "arrow.up.left.and.arrow.down.right"
        case .smallest:   return "arrow.down.right.and.arrow.up.left"
        case .thisDevice: return "pin"
        }
    }

    // MARK: - Persistence (display cache only — tmux holds the truth)

    private static func key(_ session: String) -> String { "sizingMode.\(session)" }

    /// The last mode we SAW for a session. Used to render the menu before the
    /// server read completes; never re-asserted onto tmux on its own.
    public static func stored(for session: String) -> TerminalSizingMode? {
        guard let raw = UserDefaults.standard.string(forKey: key(session)) else { return nil }
        // "pinned" is the pre-ownership build's freeze-at-current-size mode.
        // It was already `window-size manual`, so the session it left behind is
        // exactly a `.thisDevice` session with no owner recorded — nobody
        // re-asserts a size, which is what a freeze is.
        if raw == "pinned" { return .thisDevice }
        return TerminalSizingMode(rawValue: raw)
    }

    public static func store(_ mode: TerminalSizingMode, for session: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: key(session))
    }
}

/// The device that owns a `.thisDevice` session's size, as recorded in the
/// session's `@bento_size_owner` option.
///
/// The identity is the owner's **tmux client name** (its tty), not a device id
/// Bento invents: tmux already tracks exactly which clients are attached, so
/// `list-clients` answers "is the owner still here?" with no heartbeat, no
/// pairing state, and no way for a crashed device to hold a session hostage.
/// The label rides along only so other devices can name the owner in the UI.
public struct TmuxSizingOwner: Sendable, Equatable {
    public let client: String
    public let label: String

    public init(client: String, label: String) {
        self.client = client
        self.label = label
    }

    /// `<client-name>|<label>`; the label may contain anything except a newline.
    public init?(encoded: String) {
        let parts = encoded.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let client = parts.first, !client.isEmpty else { return nil }
        self.client = String(client)
        self.label = parts.count > 1 ? String(parts[1]) : ""
    }

    public var encoded: String { "\(client)|\(label)" }

    /// What to show when another device owns the size.
    public var displayName: String { label.isEmpty ? client : label }
}
