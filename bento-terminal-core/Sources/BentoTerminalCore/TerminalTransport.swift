import Foundation

/// Connection state of a terminal transport. Mirrors the four states SSHService
/// historically exposed (the app keeps `SSHConnectionState` as a typealias).
public enum TerminalConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// A bidirectional byte channel to a shell — SSH/relay on iOS, a local pty on
/// macOS. TerminalViewModel drives both through this protocol, so the session
/// logic is identical across platforms; only the concrete transport differs.
///
/// Not actor-isolated: callers invoke from the MainActor, and conformers
/// (SSHService, LocalPtyTransport) handle their own thread-safety internally.
public protocol TerminalTransport: AnyObject, Sendable {
    var state: TerminalConnectionState { get }

    /// Called on each chunk of terminal output from the remote/pty.
    var onDataReceived: (@Sendable (Data) -> Void)? { get set }
    /// Called when the connection state changes.
    var onStateChanged: (@Sendable (TerminalConnectionState) -> Void)? { get set }

    /// Establish the connection (SSH handshake, or open the pty).
    func connect(host: Host) async
    /// Start the interactive shell / PTY at the given size.
    func startShell(cols: Int, rows: Int)
    /// Send raw bytes to the shell stdin.
    func write(_ data: Data)
    /// Send a UTF-8 string to the shell stdin.
    func write(_ string: String)
    /// Resize the PTY.
    func resize(cols: Int, rows: Int)
    /// Tear down the connection.
    func disconnect()
    /// Cheap end-to-end liveness check for a connection that *claims* to be
    /// connected. Used on foreground-resume: a socket that survived the app's
    /// background suspension can simply be kept — probing avoids tearing down
    /// a healthy connection just because the suspend grace expired. Should
    /// answer within a few seconds; `false` means the caller must reconnect.
    func probeLiveness() async -> Bool

    /// Whether tmux is reached over a local pipe rather than a network link.
    ///
    /// Not cosmetic: it decides how much bulk this connection can be asked for.
    /// A `capture-pane` of deep scrollback is nearly free on a pty and expensive
    /// over SSH/relay, where the bytes are also decrypted and drained on the
    /// main thread of a phone.
    var isLocalLink: Bool { get }
}

public extension TerminalTransport {
    /// Default: trust the reported state. Transports with a real wire (relay
    /// WS) override this with an actual round-trip.
    func probeLiveness() async -> Bool {
        if case .connected = state { return true }
        return false
    }

    /// Default to the conservative answer — anything that hasn't declared itself
    /// local is assumed to be paying for every byte.
    var isLocalLink: Bool { false }
}

/// Host-app services the cross-platform TerminalViewModel needs but that are
/// platform-specific. iOS injects real implementations; macOS injects no-ops
/// or its own. Keeps UIKit / Live-Activity / Keychain / haptics out of the
/// shared package.
@MainActor
public struct TerminalEnvironment {
    /// Best-effort initial PTY size (before the surface has laid out).
    public var idealTerminalSize: () -> (cols: Int, rows: Int)
    /// Load a stored password for unlocking a remote keychain (nil if none).
    public var loadKeychainPassword: (_ key: String) async -> String?
    /// Fired when a pane transitions into awaiting-input (iOS: haptic).
    public var onAwaitingTriggered: () -> Void
    /// Fired on each state poll so the host can update aggregate UI
    /// (iOS: Live Activity). Args: hostID, tmux session name, awaiting pane
    /// count, latest prompt snippet.
    public var onSessionUpdate: (_ hostID: UUID, _ tmuxSessionName: String, _ awaitingPanes: Int, _ latestPrompt: String) -> Void

    public init(
        idealTerminalSize: @escaping () -> (cols: Int, rows: Int) = { (80, 24) },
        loadKeychainPassword: @escaping (_ key: String) async -> String? = { _ in nil },
        onAwaitingTriggered: @escaping () -> Void = {},
        onSessionUpdate: @escaping (_ hostID: UUID, _ tmuxSessionName: String, _ awaitingPanes: Int, _ latestPrompt: String) -> Void = { _, _, _, _ in }
    ) {
        self.idealTerminalSize = idealTerminalSize
        self.loadKeychainPassword = loadKeychainPassword
        self.onAwaitingTriggered = onAwaitingTriggered
        self.onSessionUpdate = onSessionUpdate
    }
}
