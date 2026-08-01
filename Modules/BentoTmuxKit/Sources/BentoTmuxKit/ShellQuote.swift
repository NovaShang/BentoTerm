import Foundation

/// Shell quoting for the few strings Bento types into a real login shell
/// (the `tmux -CC …` launch line) rather than sending over control mode.
///
/// Control-mode arguments go through `TmuxCommand.escapeArg`, which quotes for
/// *tmux's* parser. These two are not interchangeable: the launch line is read
/// by the remote shell first, and the shell is also the only thing that can
/// expand `~`.
public enum TmuxShellQuote {
    /// Single-quote an argument for `/bin/sh`, escaping embedded quotes.
    public static func arg(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quote a directory path while leaving a leading `~` / `~/` **outside**
    /// the quotes so the remote login shell expands it.
    ///
    /// On iOS the home directory lives on the remote host, so `~` cannot be
    /// resolved locally. Quoting the whole path (tilde included) makes the
    /// receiver see a literal `~/…`, which does not exist — tmux then falls
    /// back to its server cwd (`/`) and the agent silently starts in the wrong
    /// place. Everything after the tilde stays quoted, so spaces and shell
    /// metacharacters are still safe.
    public static func path(_ s: String) -> String {
        if s == "~" { return "~" }
        if s.hasPrefix("~/") { return "~/" + arg(String(s.dropFirst(2))) }
        return arg(s)
    }
}
