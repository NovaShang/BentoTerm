import Foundation

/// A pane's status, as the program running in it reports it.
///
/// Any program — or a hook configured for it (see README "Pane status") — sets
/// the tmux pane option `@bento_state` on its own pane (`working`, `awaiting`,
/// `done`) and unsets it when it's finished with the pane. The app reads it on
/// its list-panes poll. There is no other source: no option, no dot.
///
/// This replaced reading the screen. Those rules broke every time a program
/// changed its UI; the option is the program saying what it is doing.
public enum PaneStatusOption {
    /// Judge one pane. `value` is the pane's `@bento_state`; `command` is
    /// tmux's `pane_current_command`.
    ///
    /// A pane back at a bare interactive shell never has a status, whatever
    /// the option says: a program killed before it cleared the option, or one
    /// that never clears it, leaves its last state behind when it quits, and
    /// that must not keep the pane tinted.
    public static func classify(value: String?,
                                command: String?) -> (state: PaneState, hasStatus: Bool) {
        guard let value, !value.isEmpty else { return (.idle, false) }
        if let command, isInteractiveShell(command) { return (.idle, false) }
        switch value {
        case "working":  return (.working, true)
        case "awaiting": return (.awaitingInput, true)
        case "done":     return (.idle, true)
        default:         return (.idle, false)
        }
    }

    /// Process names (tmux `pane_current_command`) of a bare interactive shell
    /// sitting at its prompt.
    static let interactiveShells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "ash",
    ]

    /// True when `command` names a bare interactive shell — tolerating a login
    /// shell's leading "-" (e.g. "-zsh") and a full path.
    public static func isInteractiveShell(_ command: String) -> Bool {
        let name = (command as NSString).lastPathComponent
        let base = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return interactiveShells.contains(base.lowercased())
    }
}
