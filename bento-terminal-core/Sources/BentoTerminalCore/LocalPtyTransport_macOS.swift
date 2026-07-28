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

    /// A pty on this machine — bulk reads (deep `capture-pane` seeds) are cheap.
    public var isLocalLink: Bool { true }

    /// `command` overrides the default login shell (e.g. a `tmux -CC` invocation).
    public init(command: [String]? = nil) {
        self.command = command
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
