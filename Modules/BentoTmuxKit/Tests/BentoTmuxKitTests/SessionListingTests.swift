import Foundation
import Testing
@testable import BentoTmuxKit

/// Reading `list-sessions` back, from every route it travels.
///
/// The failure cases are the interesting half: an empty list and a refused
/// login look identical from a distance, and showing "no sessions" for a host
/// that simply wanted a password — or has no tmux — sends someone hunting for
/// a session they already have, or for one that can't exist.
struct SessionListingTests {

    @Test func readsTheFormatWeAskFor() {
        let sessions = TmuxSessionListing.parse("bento|1|0|1700000000\ndemo|4|1|0\n")
        #expect(sessions == [
            .init(name: "bento", windows: 1, attached: false,
                  lastActivity: Date(timeIntervalSince1970: 1_700_000_000)),
            .init(name: "demo", windows: 4, attached: true, lastActivity: nil),
        ])
    }

    @Test func aSessionNameMayContainTheSeparator() {
        // tmux allows `|` in a session name; the three trailing fields are ours.
        #expect(TmuxSessionListing.parse("a|b|2|0|5\n").map(\.name) == ["a|b"])
    }

    @Test func linesThatAreNotRowsAreSkipped() {
        let out = "\u{1b}]7;file://box/home\u{07}Last login: Mon\r\nwork|2|0|9\r\nWelcome|to|the|box\r\n"
        #expect(TmuxSessionListing.parse(out).map(\.name) == ["work"])
    }

    @Test func aRefusedLoginIsNotAnEmptyList() {
        let result = TmuxSessionListing.result(
            status: 255, stdout: "",
            stderr: "reviewer@152.70.119.5: Permission denied (publickey,password).\n")
        #expect(result == .failure(.needsCredentials))
    }

    @Test func noServerRunningIsAnEmptyList() {
        #expect(TmuxSessionListing.result(
            status: 1, stdout: "", stderr: "no server running on /tmp/tmux-501/default\n")
            == .failure(.noSessions))
        // The other wording tmux uses for the same fact — it names ENOENT, which
        // must not read as "tmux isn't installed".
        #expect(TmuxSessionListing.result(
            status: 1, stdout: "",
            stderr: "error connecting to /tmp/tmux-501/default (No such file or directory)\n")
            == .failure(.noSessions))
    }

    @Test func missingTmuxSaysSo() {
        for stderr in ["bash: line 1: tmux: command not found\n",
                       "zsh:1: command not found: tmux\n",
                       "sh: 1: tmux: not found\n",
                       "fish: Unknown command: tmux\n"] {
            #expect(TmuxSessionListing.result(status: 127, stdout: "", stderr: stderr)
                    == .failure(.noTmux), "\(stderr)")
        }
    }

    @Test func anythingElseIsQuotedRatherThanGuessedAt() {
        let result = TmuxSessionListing.result(
            status: 255, stdout: "",
            stderr: "ssh: connect to host dev port 22: Operation timed out\n")
        #expect(result == .failure(.unreachable("ssh: connect to host dev port 22: Operation timed out")))
    }

    @Test func everyFailureHasSomethingToShowTheUser() {
        for failure: TmuxSessionListing.Failure in [.needsCredentials, .noTmux, .noSessions, .unreachable("x")] {
            #expect(!failure.message.isEmpty)
        }
    }

    // MARK: - Over a shell

    @Test func probeMarkersNeverAppearContiguouslyInTheCommand() {
        let probe = TmuxSessionListing.MarkerProbe(token: "T0K3N")
        #expect(!probe.command.contains(probe.startMarker))
        #expect(!probe.command.contains(probe.endMarker))
        #expect(probe.command.contains("2>&1"))
    }

    @Test func probeCutsTheAnswerOutOfTheEcho() {
        let probe = TmuxSessionListing.MarkerProbe(token: "T0K3N")
        // The pty echoes the command line (format string and all) before the
        // output; only what sits between the printed markers counts.
        let out = probe.command.replacingOccurrences(of: "\n", with: "\r\n")
            + "\r\n\(probe.startMarker)\r\nwork|2|1|7\r\n\(probe.endMarker)\r\n$ "
        #expect(probe.result(of: out) == .success([
            .init(name: "work", windows: 2, attached: true,
                  lastActivity: Date(timeIntervalSince1970: 7)),
        ]))
    }

    /// The shape of a real iOS capture: zsh with syntax highlighting, OSC title
    /// escapes around the start marker, CRLF endings, and the `%` missing-
    /// newline indicator after the end marker.
    @Test func probeReadsThroughPtyNoise() {
        let probe = TmuxSessionListing.MarkerProbe(token: "1A547748")
        let osc = "\u{1B}]2;tmux list-sessions\u{07}\u{1B}]1;printf\u{07}"
        let promptTail = "\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[1m\u{1B}[0m"
        let body = "\r\n3|1|0|1\r\nbim-claw|1|1|2\r\nnovashang_com|2|0|3\r\n"
        let raw = osc + probe.startMarker + body + probe.endMarker + "\r\n" + promptTail
        guard case .success(let sessions) = probe.result(of: raw) else {
            Issue.record("expected sessions")
            return
        }
        #expect(sessions.map(\.name) == ["3", "bim-claw", "novashang_com"])
        #expect(sessions.map(\.attached) == [false, true, false])
    }

    /// A lost start marker still yields what came before the end marker.
    @Test func probeFallsBackWhenTheStartMarkerIsLost() {
        let probe = TmuxSessionListing.MarkerProbe(token: "x")
        let raw = "prompt junk\r\nfoo|1|0|4\r\n" + probe.endMarker + "\r\n"
        #expect(probe.result(of: raw) == .success([
            .init(name: "foo", windows: 1, attached: false,
                  lastActivity: Date(timeIntervalSince1970: 4)),
        ]))
    }

    @Test func probeTellsNoTmuxFromNoSessions() {
        let probe = TmuxSessionListing.MarkerProbe(token: "x")
        let missing = "\(probe.startMarker)\r\nzsh: command not found: tmux\r\n\(probe.endMarker)"
        #expect(probe.result(of: missing) == .failure(.noTmux))
        let empty = "\(probe.startMarker)\r\nno server running on /tmp/tmux-501/default\r\n\(probe.endMarker)"
        #expect(probe.result(of: empty) == .failure(.noSessions))
        let silent = "\(probe.startMarker)\r\n\(probe.endMarker)"
        #expect(probe.result(of: silent) == .failure(.noSessions))
    }
}

/// The same parser, fed by a real tmux: the format string has to survive
/// tmux's own expansion (the conditional, the activity clock) for any of the
/// above to mean anything.
@Suite("live tmux — session listing", .enabled(if: LiveTmux.isAvailable))
struct SessionListingLiveTests {

    @Test func readsWhatARealServerPrints() throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }
        try tmux.run(["new-session", "-d", "-s", "work"])
        try tmux.run(["new-window", "-t", "work"])
        try tmux.run(["new-session", "-d", "-s", "odd|name"])

        let sessions = TmuxSessionListing.parse(try tmux.capture(TmuxSessionListing.arguments))
        #expect(Set(sessions.map(\.name)) == ["work", "odd|name"])
        let work = try #require(sessions.first { $0.name == "work" })
        #expect(work.windows == 2)
        #expect(!work.attached)
        #expect(work.lastActivity != nil)
    }

    @Test func theControlModeCommandParsesTheSame() throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }
        try tmux.run(["new-session", "-d", "-s", "work"])
        let viaParser = try tmux.capture(LiveTmux.splitTmuxArgs(TmuxCommand.listSessions.commandString))
        #expect(TmuxSessionListing.parse(viaParser).map(\.name) == ["work"])
    }

    @Test func anEmptyServerReadsAsNoSessions() throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }
        let out = try tmux.capture(TmuxSessionListing.arguments)
        #expect(TmuxSessionListing.result(status: 1, stdout: "", stderr: out) == .failure(.noSessions))
    }
}
