#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation

/// A `TerminalTransport` backed by a local pseudo-terminal. Lets the shared
/// `TerminalViewModel` drive a local macOS shell exactly the way it drives SSH
/// on iOS — same session logic, different byte source.
public final class LocalPtyTransport: TerminalTransport, @unchecked Sendable {
    private let pty = LocalPty()
    private let command: [String]?
    private var _state: TerminalConnectionState = .disconnected

    public var state: TerminalConnectionState { _state }
    public var onDataReceived: (@Sendable (Data) -> Void)?
    public var onStateChanged: (@Sendable (TerminalConnectionState) -> Void)?

    private let _isLocalLink: Bool
    private let _startsInTmuxControlMode: Bool
    /// Set by `disconnect()` so the pty's own EOF, which follows, is recognised
    /// as the tear-down we asked for rather than a link that dropped.
    private var tearingDown = false

    /// A pty on this machine is only a *local link* when what runs in it stays
    /// on this machine. This used to be hardcoded `true`, which was fine while
    /// the pty always held a login shell — but the pty is also how we run
    /// `ssh`, and then every byte crosses a network. Reporting `true` there
    /// asked the seed path for 2000 lines of `capture-pane` per pane over the
    /// link, which is exactly the first-paint stall the flag exists to avoid.
    public var isLocalLink: Bool { _isLocalLink }

    public var startsInTmuxControlMode: Bool { _startsInTmuxControlMode }

    /// `command` overrides the default login shell (e.g. `["ssh", "-t", host]`).
    ///
    /// `isLocalLink` defaults to "a bare pty is local", which is true for the
    /// login shell and for local `exec`-style commands; callers that put a
    /// network hop in `command` pass `false`. `startsInTmuxControlMode` says
    /// `command` *is* a `tmux -CC` invocation, so nothing should be typed at it.
    public init(
        command: [String]? = nil,
        isLocalLink: Bool = true,
        startsInTmuxControlMode: Bool = false
    ) {
        self.command = command
        self._isLocalLink = isLocalLink
        self._startsInTmuxControlMode = startsInTmuxControlMode
        pty.onData = { [weak self] data in self?.onDataReceived?(data) }
        pty.onExit = { [weak self] in self?.handlePtyExit() }
    }

    /// The pty's child is gone. What that MEANS depends on what was running in
    /// it, and reporting the same thing for both cost ~22 seconds of a frozen
    /// window every time an ssh link dropped.
    ///
    /// When the pty holds a login shell, its exit is the shell ending — the
    /// user typed `exit`, or the local `tmux -CC` client detached. Nothing
    /// failed, and nothing should be reconnected.
    ///
    /// When the transport carried the `tmux -CC` invocation itself, the pty IS
    /// the connection: `ssh` exiting means the link is gone, and it is the only
    /// definitive, immediate signal we get. Without it the loss was noticed
    /// only by the poll watchdog — two consecutive 10s command timeouts, so
    /// ~22s of a window that still painted the last frame and silently answered
    /// nothing (measured against a real host: link cut at 10:29:31, reconnect
    /// began at 10:29:53). `.disconnected` is not that signal, because nothing
    /// acts on it; `.failed` is the state `TerminalViewModel` recovers from.
    ///
    /// A tear-down we asked for is excluded, since `disconnect()` closes the fd
    /// and the read source can still deliver the resulting EOF afterwards.
    private func handlePtyExit() {
        guard !tearingDown, _startsInTmuxControlMode else {
            setState(.disconnected)
            return
        }
        setState(.failed("The connection to the terminal was lost."))
    }

    public func connect(host: Host) async {
        // Local: nothing to dial. Mark connected so the VM proceeds to start
        // the shell (mirrors SSHService reaching `.connected`).
        setState(.connected)
    }

    public func startShell(cols: Int, rows: Int) {
        pty.start(cols: cols, rows: rows, command: command)
    }

    public func write(_ data: Data) { pty.write(data) }

    public func write(_ string: String) {
        if let d = string.data(using: .utf8) { pty.write(d) }
    }

    public func resize(cols: Int, rows: Int) { pty.resize(cols: cols, rows: rows) }

    public func disconnect() {
        tearingDown = true
        pty.stop()
        setState(.disconnected)
    }

    private func setState(_ s: TerminalConnectionState) {
        _state = s
        onStateChanged?(s)
    }
}
#endif
