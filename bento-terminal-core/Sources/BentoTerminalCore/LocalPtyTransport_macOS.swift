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
        pty.onExit = { [weak self] in self?.setState(.disconnected) }
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
        pty.stop()
        setState(.disconnected)
    }

    private func setState(_ s: TerminalConnectionState) {
        _state = s
        onStateChanged?(s)
    }
}
#endif
