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

    /// Wrap a command line so the far side runs it through a **login shell**.
    ///
    /// For the line typed into a shell this is unnecessary — there already is a
    /// login shell, and it is what expands `~` and resolves `tmux`. It matters
    /// for the line handed to `ssh` as an argument: given a command to run, the
    /// remote shell runs it NON-interactively and NON-login, so zsh reads only
    /// `~/.zshenv` — not `~/.zprofile`, where Homebrew's `brew shellenv` line
    /// conventionally lives. `/opt/homebrew/bin` never enters PATH and the bare
    /// word `tmux` does not resolve, on a host that has tmux installed. (`ssh
    /// -t` does not help: zsh is interactive by virtue of having no command
    /// argument, not by having a pty.)
    ///
    /// `$SHELL` rather than a fixed path, because it is the user's own login
    /// shell that has their PATH in it; sshd sets it from the passwd entry.
    /// `exec` so tmux inherits the pty directly instead of running under a shell
    /// that only waits for it.
    ///
    /// Verified against `sh`, `bash` and `zsh` (argv arrives intact, including a
    /// session name with an apostrophe); `fish` parses all of it the same way
    /// but has not been run. `tcsh` rejects `-l` alongside other flags — a known
    /// gap, accepted because tcsh reads `~/.cshrc` even non-interactively, so it
    /// is the one login shell that never had the problem this solves.
    public static func loginShell(running line: String) -> String {
        "exec $SHELL -l -c \(arg(line))"
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
