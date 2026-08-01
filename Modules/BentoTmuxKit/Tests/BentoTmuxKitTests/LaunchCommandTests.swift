import Testing
@testable import BentoTmuxKit

/// Locks the working-directory quoting on the `tmux -CC` launch line.
///
/// Regression 1 (quoting): iOS new sessions defaulted to `~/code`, which got
/// wrapped in single quotes (`-c '~/code'`). The remote shell never expanded
/// the tilde, tmux couldn't find the literal `~/code`, and the session fell
/// back to the server cwd `/`. A leading `~` must stay outside the quotes.
///
/// Regression 2 (the race this moved here to fix): the directory used to be
/// carried by a `tmux new-session -d …` script typed into the freshly spawned
/// login shell a second before attaching. When that write beat the pty's
/// readiness the line was mangled, `-c` went with it, and the agent started in
/// the wrong folder — silently. It now rides the launch line, which is a write
/// the caller has to make anyway.
@Suite("tmux -CC launch line")
struct LaunchCommandTests {
    private let svc = TmuxControlMode()

    @Test func tildePathKeepsTildeUnquotedSoRemoteShellExpands() {
        let cmd = svc.launchCommand(sessionName: "work", path: "~/code")
        #expect(cmd.contains("-c ~/'code'"))
        #expect(!cmd.contains("-c '~/code'"), "fully-quoted tilde lands the session in /")
    }

    @Test func bareTildeStaysBare() {
        let cmd = svc.launchCommand(sessionName: "work", path: "~")
        #expect(cmd.contains("-c ~"))
        #expect(!cmd.contains("-c '~'"))
    }

    @Test func absolutePathIsFullyQuoted() {
        // The macOS wizard resolves to an absolute path; unchanged behavior.
        let cmd = svc.launchCommand(sessionName: "work", path: "/Users/nova/code")
        #expect(cmd.contains("-c '/Users/nova/code'"))
    }

    @Test func pathWithSpacesAndQuotesSurvives() {
        let cmd = svc.launchCommand(sessionName: "work", path: "/tmp/my proj's dir")
        #expect(cmd.contains("-c '/tmp/my proj'\\''s dir'"))
    }

    /// The whole point of the change: a directory the user picked must appear
    /// on the one line that actually launches tmux.
    @Test func directoryAndProgramRideTheLaunchLine() {
        let cmd = svc.launchCommand(sessionName: "work", path: "~/code/app", command: "claude")
        #expect(cmd.hasPrefix("tmux -CC new-session -A -s work "))
        #expect(cmd.contains("-c ~/'code/app'"))
        #expect(cmd.contains("'claude'"))
        #expect(cmd.hasSuffix("\n"))
    }

    @Test func emptyProgramAddsNothing() {
        let cmd = svc.launchCommand(sessionName: "work", path: "/tmp", command: "")
        #expect(cmd == "tmux -CC new-session -A -s work -c '/tmp'\n")
    }

    /// A grouped session shares the source's windows, so seeding a directory or
    /// program there is meaningless — and tmux rejects the combination.
    @Test func groupedSessionIgnoresSeed() {
        let cmd = svc.launchCommand(sessionName: "work-mobile", groupWith: "work",
                                    path: "/tmp", command: "claude")
        #expect(cmd == "tmux -CC new-session -A -s work-mobile -t work\n")
    }

    @Test func noSeedMatchesPreviousBehavior() {
        #expect(svc.launchCommand(sessionName: "work") == "tmux -CC new-session -A -s work\n")
        #expect(svc.launchCommand() == "tmux -CC new-session\n")
    }
}

@Suite("shell quoting for the launch line")
struct ShellQuoteTests {
    @Test func argQuotesAndEscapes() {
        #expect(TmuxShellQuote.arg("plain") == "'plain'")
        #expect(TmuxShellQuote.arg("it's") == "'it'\\''s'")
        #expect(TmuxShellQuote.arg("a b") == "'a b'")
    }

    @Test func pathPreservesLeadingTildeOnly() {
        #expect(TmuxShellQuote.path("~") == "~")
        #expect(TmuxShellQuote.path("~/a b") == "~/'a b'")
        // A tilde anywhere else is literal and must stay quoted.
        #expect(TmuxShellQuote.path("/tmp/~x") == "'/tmp/~x'")
    }
}

/// The same launch line, built for `ssh -t <host> "<line>"` instead of for a
/// shell's stdin.
///
/// Passing tmux as ssh's ARGUMENT rather than typing it after connecting is
/// what makes a host that asks for a password or a 2FA code work at all: the
/// typed version is gated on a fixed 500ms sleep, so on such a host the launch
/// line — and its newline — get typed into the authentication prompt. As an
/// argument there is no window; ssh does not run the command until
/// authentication has finished.
@Suite("tmux -CC launch line as an ssh argument")
struct LaunchCommandLineTests {
    private let svc = TmuxControlMode()

    /// A newline inside an ssh argument is a second, empty command — the one
    /// difference between the two forms, and the only one.
    @Test func hasNoTrailingNewline() {
        let line = TmuxControlMode.launchCommandLine(sessionName: "work")
        #expect(!line.contains("\n"))
        #expect(line == "tmux -CC new-session -A -s work")
    }

    /// One builder, so the local and remote launches can never drift into
    /// creating sessions on different terms.
    @Test func isExactlyTheTypedLineWithoutItsNewline() {
        for (name, path, command) in [
            ("work", nil, nil) as (String, String?, String?),
            ("work", "~/code", nil),
            ("work", "/tmp/my proj's dir", "claude"),
        ] {
            let typed = svc.launchCommand(sessionName: name, path: path, command: command)
            let arg = TmuxControlMode.launchCommandLine(
                sessionName: name, path: path, command: command)
            #expect(typed == arg + "\n")
        }
    }

    /// `tmux` stays a BARE WORD. It is resolved by the PATH of whatever shell
    /// ends up running the line — the login shell here, or the remote user's
    /// shell on the far side of an ssh hop — which is the entire reason one
    /// string works on both.
    @Test func tmuxIsNotAnAbsolutePath() {
        #expect(TmuxControlMode.launchCommandLine(sessionName: "work").hasPrefix("tmux "))
    }
}
