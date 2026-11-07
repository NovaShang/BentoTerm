import BentoTmuxKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoSessionKit
import BentoUISharedKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

// MARK: - SessionTab (a live, self-managed session)

/// One window's terminal: its view model, its content view, and lifecycle.
///
/// Two shapes, decided by which initializer built it and never revisited:
///   - a tmux tab tiles panes (`paneHost`) and carries every session feature;
///   - a plain tab (no tmux) is one surface (`plainHost`) that offers typing,
///     voice, copy/paste, find and close — and nothing else. Its window builds
///     a minimal toolbar for it, so no tmux feature has to ask "am I plain?".
@MainActor
final class SessionTab {
    let viewModel: TerminalViewModel
    /// Exactly one of these is non-nil — `contentView` is whichever the window
    /// should host.
    let paneHost: GhosttyTiledPaneHost?
    let plainHost: PlainTerminalHost?
    /// The session's identity everywhere (strip order, active selection,
    /// persistence). A tmux rename changes that identity, so the manager
    /// migrates it to follow (`migrateSessionKey`) — the SERVER never changes,
    /// only the name on it. A plain tab has no session; its id is only a
    /// unique key for its window (see `BentoTerminalWindow.openPlain`).
    var id: TmuxSessionID
    /// String form of `id`, for the places identity has to travel as text.
    var sessionKey: String { id.key }
    /// How the tmux session is started; nil for a plain tab.
    let choice: TmuxStartChoice?
    let windowTitle: String
    /// The ssh control socket this session keeps open, so a clicked
    /// `localhost:5173` can be tunnelled without a second login. Released in
    /// `teardown` — a forward never outlives the session that carries it.
    private var controlSocket: (alias: String, path: String?)?

    /// A plain tab has no tmux behind it: closing it destroys it, and it is
    /// never persisted, restored or reconnected.
    var isPlain: Bool { plainHost != nil }
    var contentView: NSView { paneHost ?? plainHost! }
    /// What should hold the keyboard when the window comes up.
    var initialResponder: NSView { plainHost?.surface ?? paneHost! }

    /// The focused pane's file context — what the dock's directory tree roots
    /// itself at. Plain tabs have no dock.
    var previewContext: PathPreviewContext? { paneHost?.activePathPreviewContext }

    /// A tmux-backed tab.
    ///
    /// For the LOCAL server the VM types the tmux line into a login shell. For
    /// a session on an ssh host the command is built here, below, and carries
    /// the `tmux -CC` invocation as ssh's own argument.
    init(choice: TmuxStartChoice, server: TmuxServer, title: String) {
        self.choice = choice
        self.windowTitle = title
        self.id = Self.id(for: choice, on: server)
        let storedKey = id.key
        let env = Self.environment(onSessionUpdate: { _, session, awaiting, prompt in
            // The VM reports the session NAME; the notifier keys on
            // IDENTITY. On a remote session those differ, and passing the
            // bare name would let an agent waiting in `bento` on a build
            // box overwrite the notification for the local `bento`.
            let key = session.isEmpty
                ? storedKey
                : TmuxSessionID(server: server, name: session).key
            MacAwaitingNotifier.shared.update(
                sessionKey: key, awaiting: awaiting, prompt: prompt)
        })
        let transport: LocalPtyTransport
        var adopted: (alias: String, path: String?)?
        if let sshHost = server.sshHost {
            // The tmux invocation goes in as ssh's ARGUMENT rather than being
            // typed at a shell afterwards.
            //
            // Typing it is a race with the connection: the launch write is
            // gated on a fixed 500ms sleep, which is a guess about how long a
            // login takes. On a host that asks for a password or a 2FA code
            // that guess is not just wrong, it is dangerous — the launch line,
            // and then a newline, get typed into the prompt. As an argument
            // there is no window at all: ssh does not run the command until
            // authentication has completed, however long that takes and however
            // many prompts it involves.
            //
            // `-t` forces a pty, which tmux requires; ssh otherwise allocates
            // none when it is given a command to run.
            let launch = Self.remoteLaunchCommand(for: choice, name: id.name)
            // Keep a control socket on this connection. A port forward added
            // later rides it (`ssh -O forward`) instead of opening a second
            // connection and asking for the password — or the 2FA code — again.
            let socket = SSHControlSockets.adopt(alias: sshHost)
            adopted = (sshHost, socket.controlPath)
            transport = LocalPtyTransport(
                command: ["ssh", "-t"] + socket.options + [sshHost, launch],
                isLocalLink: false,
                startsInTmuxControlMode: true)
        } else {
            transport = LocalPtyTransport(command: nil)
        }
        let vm = TerminalViewModel(
            host: Host(name: server.sshHost ?? "Local"),
            transport: transport,
            environment: env)
        self.viewModel = vm
        self.controlSocket = adopted
        let tiled = GhosttyTiledPaneHost(viewModel: vm, theme: ThemeStore.shared.makeTerminalTheme())
        // Computed from the local `adopted` rather than from `self.linkHost`:
        // `self` is not fully initialised yet.
        tiled.linkHost = adopted
            .map { LinkHost(remoteID: $0.alias, label: $0.alias) }
            ?? .local(label: "This Mac")
        self.paneHost = tiled
        self.plainHost = nil
    }

    /// A plain tab: the login shell, or `command` in its place (a quick-connect
    /// `["ssh", host]`). `key` is its unique window key.
    init(plainTitle title: String, key: String, command: [String]? = nil) {
        self.choice = nil
        self.windowTitle = title
        self.id = TmuxSessionID(key: key) ?? .local(key)
        let vm = TerminalViewModel(
            host: Host(name: command.flatMap { $0.count >= 2 ? $0[1] : nil } ?? "Local"),
            transport: LocalPtyTransport(command: command),
            environment: Self.environment(onSessionUpdate: { _, _, _, _ in }))
        self.viewModel = vm
        self.controlSocket = nil
        self.plainHost = PlainTerminalHost(viewModel: vm, theme: ThemeStore.shared.makeTerminalTheme())
        self.paneHost = nil
    }

    private static func environment(
        onSessionUpdate: @escaping (UUID, String, Int, String) -> Void
    ) -> TerminalEnvironment {
        TerminalEnvironment(
            idealTerminalSize: { (120, 30) },
            // What `ssh` asks for, when the user asked us to remember it.
            loadKeychainPassword: { key in MacKeychain.load(key) },
            saveKeychainPassword: { key, value in MacKeychain.save(key, value) },
            onSessionUpdate: onSessionUpdate)
    }

    func connect() {
        Task { [weak self] in
            guard let self else { return }
            guard let choice = self.choice else {
                await self.viewModel.connectPlainShell()
                return
            }
            await self.viewModel.connect()
            await self.viewModel.applyTmuxChoice(choice)
        }
    }

    func teardown() {
        paneHost?.teardown()
        plainHost?.teardown()
        viewModel.disconnect()
        MacAwaitingNotifier.shared.clear(sessionKey: sessionKey)
        if let controlSocket {
            // The session is what the tunnels ride on: when it goes, they go.
            PortForwarders.current?.closeAll(on: linkHost)
            SSHControlSockets.release(alias: controlSocket.alias, controlPath: controlSocket.path)
            self.controlSocket = nil
        }
    }

    /// Which machine this tab's panes mean by `localhost`.
    var linkHost: LinkHost {
        guard let alias = controlSocket?.alias else { return .local(label: "This Mac") }
        return LinkHost(remoteID: alias, label: alias)
    }

    static func id(for choice: TmuxStartChoice, on server: TmuxServer) -> TmuxSessionID {
        switch choice {
        case .createOrAttach(let name): return TmuxSessionID(server: server, name: name)
        case .shareWithDesktop(let target): return TmuxSessionID(server: server, name: target)
        }
    }

    /// The `tmux -CC …` line handed to `ssh` as its argument. Built by the same
    /// builder the typed local path uses, so a remote session is created and
    /// attached on exactly the same terms as a local one — wrapped in a login
    /// shell, because unlike the local path there is no login shell here
    /// otherwise (`remoteLaunchCommandLine`).
    static func remoteLaunchCommand(for choice: TmuxStartChoice, name: String) -> String {
        switch choice {
        case .shareWithDesktop(let target):
            return TmuxControlMode.remoteLaunchCommandLine(
                sessionName: "\(target)-mobile", groupWith: target)
        case .createOrAttach:
            return TmuxControlMode.remoteLaunchCommandLine(sessionName: name)
        }
    }
}
#endif
