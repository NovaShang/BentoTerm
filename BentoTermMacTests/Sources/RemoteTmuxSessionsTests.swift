import Foundation
import Testing
import BentoTerm

/// Reading `tmux list-sessions` back off an ssh pipe.
///
/// The parse is where a remote host's answer becomes a list a user picks from,
/// and its failure cases are the interesting half: an empty list and a refused
/// login look identical from a distance, and showing "no sessions" for a host
/// that simply wanted a password would send someone hunting for a session they
/// already have.
@Suite @MainActor struct RemoteTmuxSessionsTests {

    @Test func readsTheFormatWeAskedFor() {
        // Verbatim from `ssh dev` — one session, one window, nobody attached.
        let result = RemoteTmuxSessions.parse(status: 0, stdout: "bento|1|0\n", stderr: "")
        #expect(result == .success([.init(name: "bento", windows: 1, attached: false)]))
    }

    @Test func readsSeveralSessionsAndTheAttachedFlag() {
        let out = "bento|1|0\ndemo|4|1\n"
        guard case .success(let sessions) = RemoteTmuxSessions.parse(
            status: 0, stdout: out, stderr: "") else {
            Issue.record("expected sessions")
            return
        }
        #expect(sessions.count == 2)
        #expect(sessions[1] == .init(name: "demo", windows: 4, attached: true))
    }

    @Test func aSessionNameMayContainTheSeparator() {
        // tmux allows `|` in a session name; the two trailing fields are ours.
        let result = RemoteTmuxSessions.parse(status: 0, stdout: "a|b|2|0\n", stderr: "")
        #expect(result == .success([.init(name: "a|b", windows: 2, attached: false)]))
    }

    @Test func aRefusedLoginIsNotAnEmptyList() {
        // What `bento-review` actually says with no password available.
        let result = RemoteTmuxSessions.parse(
            status: 255, stdout: "",
            stderr: "reviewer@152.70.119.5: Permission denied (publickey,password).\n")
        #expect(result == .failure(.needsCredentials))
    }

    @Test func noServerRunningIsAnEmptyList() {
        let result = RemoteTmuxSessions.parse(
            status: 1, stdout: "", stderr: "no server running on /tmp/tmux-501/default\n")
        #expect(result == .failure(.noSessions))
    }

    @Test func missingTmuxSaysSo() {
        let result = RemoteTmuxSessions.parse(
            status: 127, stdout: "", stderr: "bash: line 1: tmux: command not found\n")
        #expect(result == .failure(.noTmux))
    }

    @Test func anythingElseIsQuotedRatherThanGuessedAt() {
        let result = RemoteTmuxSessions.parse(
            status: 255, stdout: "", stderr: "ssh: connect to host dev port 22: Operation timed out\n")
        #expect(result == .failure(.unreachable("ssh: connect to host dev port 22: Operation timed out")))
    }

    @Test func everyFailureHasSomethingToShowTheUser() {
        for failure: RemoteTmuxSessions.Failure in [
            .needsCredentials, .noTmux, .noSessions, .unreachable("x"),
        ] {
            #expect(!failure.message.isEmpty)
        }
    }
}
