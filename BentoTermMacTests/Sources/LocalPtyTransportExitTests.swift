#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
import BentoTerm
import BentoFoundationKit
import BentoSessionKit

/// What the pty's child exiting MEANS depends on what was running in it.
///
/// A login shell ending is ordinary — the user typed `exit`. But when the
/// transport carried the `tmux -CC` invocation itself (`ssh -t host "tmux -CC
/// …"`), the pty IS the connection, and its child exiting is the link going
/// away. That distinction is worth a test because getting it wrong is silent
/// in both directions: report too little and a dead ssh session sits there
/// looking alive until a poll watchdog notices ~22s later; report too much and
/// an ordinary `exit` in a plain tab triggers a reconnect that resurrects a
/// shell the user just closed.
@Suite("LocalPtyTransport exit reporting")
struct LocalPtyTransportExitTests {

    /// Collect states off whatever thread the transport reports on.
    private final class States: @unchecked Sendable {
        private var seen: [TerminalConnectionState] = []
        private let lock = NSLock()
        func record(_ s: TerminalConnectionState) {
            lock.lock(); defer { lock.unlock() }
            seen.append(s)
        }
        var all: [TerminalConnectionState] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }
        var failure: String? {
            for s in all { if case .failed(let m) = s { return m } }
            return nil
        }
    }

    /// Poll until `check` passes or the deadline expires — the pty reports its
    /// exit asynchronously, on the main queue.
    private func wait(_ timeout: TimeInterval = 5, until check: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            try? await Task.sleep(for: .milliseconds(25))
            await MainActor.run {}
        }
        return check()
    }

    /// The reported bug: an ssh host with no tmux. The remote command dies in
    /// milliseconds, and the transport must call that a failure so the view
    /// model can say so, rather than a `.disconnected` that nothing acts on.
    @Test("a -CC command that dies immediately reports failure")
    func controlModeExitIsFailure() async {
        let states = States()
        let t = LocalPtyTransport(
            command: ["/bin/sh", "-c", "echo 'sh: tmux: command not found' >&2; exit 127"],
            isLocalLink: false,
            startsInTmuxControlMode: true)
        t.onStateChanged = { states.record($0) }
        await t.connect(host: BentoFoundationKit.Host(name: "test"))
        t.startShell(cols: 80, rows: 24)

        let failed = await wait { states.failure != nil }
        #expect(failed, "expected a .failed state, got \(states.all)")
    }

    /// The other direction. A plain tab's login shell exiting is the user
    /// closing it; treating that as a dropped link would reconnect a shell
    /// nobody asked to keep.
    @Test("a login shell exiting is not a failure")
    func loginShellExitIsNotFailure() async {
        let states = States()
        let t = LocalPtyTransport(command: ["/bin/sh", "-c", "exit 0"])
        t.onStateChanged = { states.record($0) }
        await t.connect(host: BentoFoundationKit.Host(name: "test"))
        t.startShell(cols: 80, rows: 24)

        _ = await wait { states.all.contains(.disconnected) }
        #expect(states.failure == nil, "login shell exit must not report failure")
    }

    /// A tear-down we asked for must stay quiet: `disconnect()` closes the fd,
    /// and the read source can still deliver the resulting EOF afterwards.
    @Test("an asked-for disconnect is not a failure")
    func deliberateDisconnectIsNotFailure() async {
        let states = States()
        let t = LocalPtyTransport(
            command: ["/bin/sh", "-c", "sleep 30"],
            isLocalLink: false,
            startsInTmuxControlMode: true)
        t.onStateChanged = { states.record($0) }
        await t.connect(host: BentoFoundationKit.Host(name: "test"))
        t.startShell(cols: 80, rows: 24)
        try? await Task.sleep(for: .milliseconds(200))
        t.disconnect()

        try? await Task.sleep(for: .milliseconds(400))
        await MainActor.run {}
        #expect(states.failure == nil, "deliberate disconnect must not report failure")
    }
}
#endif
