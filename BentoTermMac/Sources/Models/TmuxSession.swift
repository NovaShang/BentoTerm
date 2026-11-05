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
