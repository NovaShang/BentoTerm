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
public enum TerminalSizingMode: String, Sendable, CaseIterable {
    /// This client governs: keep pushing our grid, and leave `window-size` on
    /// `latest` so focusing this window makes it the one tmux sizes to.
    case tracking
    /// Freeze the window at its current grid: `window-size manual` plus one
    /// `resize-window`, after which neither this client nor any other changes
    /// it. Use when another device is sharing the session and must not be
    /// reflowed, or when a program needs a fixed canvas.
    case pinned

    public var title: String {
        switch self {
        case .tracking: return "Track This Window"
        case .pinned:   return "Pin to Current Size"
        }
    }

    public var symbol: String {
        switch self {
        case .tracking: return "arrow.up.left.and.arrow.down.right"
        case .pinned:   return "pin"
        }
    }

    // MARK: - Persistence

    private static func key(_ session: String) -> String { "sizingMode.\(session)" }

    /// The stored choice for a session, or nil if the user has never chosen.
    public static func stored(for session: String) -> TerminalSizingMode? {
        UserDefaults.standard.string(forKey: key(session)).flatMap(TerminalSizingMode.init(rawValue:))
    }

    public static func store(_ mode: TerminalSizingMode, for session: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: key(session))
    }
}
