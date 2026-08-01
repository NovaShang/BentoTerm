import Foundation
import Testing
@testable import BentoTmuxKit

/// A connection that never reaches control mode has to be able to say why.
///
/// The motivating report was a user pointing the app at an ssh host with no
/// tmux installed. `ssh` connects, the remote shell says `tmux: command not
/// found` and exits — and because that line is not control-mode protocol, the
/// parser dropped it. The failure then had nothing to show for itself, which
/// is how "no tmux on that box" — the likeliest first-run mistake there is,
/// given the product's premise is "any sshd plus tmux" — presented as a window
/// that simply sat there.
@Suite("Output before control mode")
struct PreGreetingOutputTests {

    private func service() -> TmuxControlMode {
        TmuxControlMode()
    }

    @Test("keeps what the remote said instead of tmux starting")
    func capturesRemoteError() {
        let s = service()
        s.feedData(Data("/bin/sh: 1: tmux: not found\r\n".utf8))
        s.feedData(Data("Connection to 10.0.0.1 closed.\r\n".utf8))

        let captured = s.outputBeforeControlMode
        #expect(captured.contains("tmux: not found"))
        #expect(captured.contains("Connection to 10.0.0.1 closed."))
    }

    @Test("keeps ssh's own failures too")
    func capturesSshError() {
        let s = service()
        s.feedData(Data("ssh: Could not resolve hostname nope: nodename nor servname provided\r\n".utf8))
        #expect(s.outputBeforeControlMode.contains("Could not resolve hostname"))
    }

    /// The whole point is that this is empty on a healthy connection — the
    /// diagnosis must never leak into a session that actually worked.
    @Test("stops collecting once tmux greets")
    func stopsAfterGreeting() {
        let s = service()
        s.feedData(Data("\u{1b}P1000p\r\n".utf8))
        s.feedData(Data("%begin 1 1 0\r\n".utf8))
        s.feedData(Data("%end 1 1 0\r\n".utf8))
        // Anything after the greeting is session traffic, not a bring-up
        // diagnosis, and must not be collected.
        s.feedData(Data("some later shell noise\r\n".utf8))

        #expect(!s.outputBeforeControlMode.contains("some later shell noise"))
    }

    /// Protocol lines are never diagnosis, even before the greeting.
    @Test("ignores protocol lines")
    func ignoresProtocol() {
        let s = service()
        s.feedData(Data("%sessions-changed\r\n".utf8))
        #expect(s.outputBeforeControlMode.isEmpty)
    }

    /// A shell that drops to an interactive prompt instead of starting tmux can
    /// print without limit; the diagnosis is in the first lines either way.
    @Test("is bounded")
    func bounded() {
        let s = service()
        for i in 0..<200 { s.feedData(Data("noise line \(i)\r\n".utf8)) }
        let lines = s.outputBeforeControlMode.split(separator: "\n")
        #expect(lines.count <= 12)
    }

    /// `reset()` runs per connection, so a reconnect must not inherit the
    /// previous attempt's error text.
    @Test("reset clears it")
    func resetClears() {
        let s = service()
        s.feedData(Data("tmux: not found\r\n".utf8))
        #expect(!s.outputBeforeControlMode.isEmpty)
        s.reset()
        #expect(s.outputBeforeControlMode.isEmpty)
    }
}
