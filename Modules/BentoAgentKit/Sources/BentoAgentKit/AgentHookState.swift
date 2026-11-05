import Foundation

/// A pane's agent state, as the agent itself reports it.
///
/// Agent hooks (configured by the user on whatever host runs the agent — see
/// README "Agent hooks") set two tmux pane options on their own pane:
/// `@bento_agent` (who: `claude`, `codex`, …) and `@bento_state` (`working`,
/// `awaiting`, `done`), and unset both when the session ends. The app reads
/// them on its list-panes poll. There is no other source: no hook, no dot.
///
/// This replaced reading the screen. Those rules broke every time an agent
/// changed its UI; a hook is the agent saying what it is doing.
public enum AgentHookState {
    /// Judge one pane. `command` is tmux's `pane_current_command`.
    ///
    /// A pane back at a bare interactive shell is never an agent pane, whatever
    /// the options say: an agent killed before its session-end hook ran, or
    /// configured without one, leaves its last state behind when it quits,
    /// and that must not keep the pane tinted.
    public static func classify(agent: String?, state: String?,
                                command: String?) -> (state: PaneState, isAgent: Bool) {
        guard let state, !state.isEmpty else { return (.idle, false) }
        if let command, isInteractiveShell(command) { return (.idle, false) }
        switch state {
        case "working":
            return (.working, true)
        case "awaiting":
            let who = agent.flatMap { $0.isEmpty ? nil : $0 } ?? "agent"
            return (.awaitingInput(profile: who), true)
        case "done":
            return (.idle, true)
        default:
            return (.idle, false)
        }
    }

    /// Process names (tmux `pane_current_command`) of a bare interactive shell
    /// sitting at its prompt.
    static let interactiveShells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "ash",
    ]

    /// True when `command` names a bare interactive shell — tolerating a login
    /// shell's leading "-" (e.g. "-zsh") and a full path.
    static func isInteractiveShell(_ command: String) -> Bool {
        let name = (command as NSString).lastPathComponent
        let base = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return interactiveShells.contains(base.lowercased())
    }
}
