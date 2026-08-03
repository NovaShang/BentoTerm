import Foundation
import BentoTmuxKit
import BentoFoundationKit
import BentoSessionKit

/// One row of `tmux list-sessions` — run against the LOCAL tmux server, which
/// is why the name is typed. Everything reachable from this row (kill, rename,
/// attach) acts on this machine; a session on an ssh host never appears here
/// and cannot be substituted into one of these.
struct TmuxSession: Identifiable, Hashable {
    let name: LocalTmuxSessionName
    let attached: Bool
    /// Last time anything happened in the session (output, keystroke, attach).
    /// Falls back to `Date.distantPast` if tmux didn't return it.
    let lastActivity: Date

    var id: String { name.rawValue }
}

/// One row of `tmux list-windows -t <session>`. Window names default to
/// the running command (e.g. "claude", "vim") when the user hasn't set
/// one explicitly via `Ctrl-b ,`.
struct TmuxWindow: Identifiable, Hashable {
    /// Owning session — needed because window indices repeat across
    /// sessions (every session has its own window 0, 1, 2…).
    let session: LocalTmuxSessionName
    let index: Int
    let name: String
    let active: Bool
    let paneCount: Int

    /// Scoped so a (session, index) pair is unique across the whole list.
    var id: String { "\(session.rawValue):\(index)" }
}
