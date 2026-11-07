import BentoTmuxKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoSessionKit
import BentoUISharedKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

// MARK: - SessionTab (a live, self-managed session)

/// One session: its view model, pane host, and lifecycle. Kept alive while it's
/// a background tab — the tmux -CC client keeps streaming so the surfaces stay
/// current; only the active tab's `paneHost` is in the window.
@MainActor
final class SessionTab {
    let viewModel: TerminalViewModel
    /// A tmux tab tiles panes; a plain (no-tmux) tab is a single raw surface.
    /// Exactly one of these is non-nil — `contentView` is whichever the window
    /// should host.
    let paneHost: GhosttyTiledPaneHost?
    let plainSurface: GhosttyTerminalSurface?
    /// The session's identity everywhere (strip order, active selection,
    /// persistence). A tmux rename changes that identity, so the manager
    /// migrates it to follow (`migrateSessionKey`) — the SERVER never changes,
    /// only the name on it.
    var id: TmuxSessionID
    /// String form of `id`, for the places identity has to travel as text.
    var sessionKey: String { id.key }
    let choice: TmuxStartChoice
    let windowTitle: String
    /// The ssh control socket this session keeps open, so a clicked
    /// `localhost:5173` can be tunnelled without a second login. Released in
    /// `teardown` — a forward never outlives the session that carries it.
    private var controlSocket: (alias: String, path: String?)?

    /// A plain tab has no tmux behind it: no panes/windows/agents, and closing it
    /// destroys it (it isn't persisted or reconnected).
    var isPlain: Bool { plainSurface != nil }
    var contentView: NSView { paneHost ?? plainSurface! }

    /// The focused pane's file context (tmux host → its active pane; plain
    /// tab → its surface) — what the dock's directory tree roots itself at.
    var previewContext: PathPreviewContext? {
        paneHost?.activePathPreviewContext ?? plainSurface?.pathPreviewContext
    }

    /// `command` overrides the plain (no-tmux) tab's login shell — a
    /// quick-connect `["ssh", host]`.
    ///
    /// A tmux-backed tab must leave `command` nil for the LOCAL server (the VM
    /// types the tmux line into a login shell). For a session on an ssh host it
    /// is the opposite: the command is built here, below, and carries the
    /// `tmux -CC` invocation as ssh's own argument.
    init(choice: TmuxStartChoice, server: TmuxServer, title: String,
         key: String? = nil, command: [String]? = nil) {
        self.choice = choice
        self.windowTitle = title
        self.id = key.flatMap(TmuxSessionID.init(key:)) ?? Self.id(for: choice, on: server)
        let theme = ThemeStore.shared.makeTerminalTheme()
        let storedKey = id.key
        let env = TerminalEnvironment(
            idealTerminalSize: { (120, 30) },
            // What `ssh` asks for, when the user asked us to remember it.
            loadKeychainPassword: { key in MacKeychain.load(key) },
            saveKeychainPassword: { key, value in MacKeychain.save(key, value) },
            onSessionUpdate: { _, session, awaiting, prompt in
                // The VM reports the session NAME; the notifier keys on
                // IDENTITY. On a remote session those differ, and passing the
                // bare name would let an agent waiting in `bento` on a build
                // box overwrite the notification for the local `bento`.
                let key = session.isEmpty
                    ? storedKey
                    : TmuxSessionID(server: server, name: session).key
                MacAwaitingNotifier.shared.update(
                    sessionKey: key, awaiting: awaiting, prompt: prompt)
            }
        )
        let transport: LocalPtyTransport
        var adopted: (alias: String, path: String?)?
        if let sshHost = server.sshHost, choice != .noTmux {
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
        } else if let command, command.first == "ssh", command.count >= 2 {
            // Quick-connect (`ssh <alias>`, no tmux) gets the same treatment —
            // it is still a machine whose ports a link can point at.
            let alias = command[1]
            let socket = SSHControlSockets.adopt(alias: alias)
            adopted = (alias, socket.controlPath)
            transport = LocalPtyTransport(
                command: ["ssh"] + socket.options + Array(command.dropFirst()))
        } else {
            transport = LocalPtyTransport(command: command)
        }
        let vm = TerminalViewModel(
            host: Host(name: server.sshHost ?? "Local"),
            transport: transport,
            environment: env)
        self.viewModel = vm
        self.controlSocket = adopted
        // Computed from the local `adopted` rather than from `self.linkHost`:
        // the surfaces below are stored properties that are not set yet, so
        // `self` is still off limits here.
        let tabLinkHost: LinkHost = adopted
            .map { LinkHost(remoteID: $0.alias, label: $0.alias) }
            ?? .local(label: "This Mac")
        if choice == .noTmux {
            // No tmux → a single raw surface (no tiling host); the VM streams
            // bytes straight to/from it.
            let surface = GhosttyTerminalSurface(theme: theme)
            surface.onInput = { [weak vm] data in vm?.sendData(data) }
            surface.onSizeChanged = { [weak vm] size in
                vm?.resizeTerminal(cols: size.columns, rows: size.rows)
            }
            // Path preview: a plain tab is a local shell; cwd comes from the
            // shell's OSC 7 report (ghostty shell integration). A quick-connect
            // `ssh <host>` tab is remote for its whole life (it dies when ssh
            // exits) — refuse local browsing/preview honestly.
            let block = PathPreviewContext.localSourceBlock(sessionHost: nil,
                                                            foregroundCommand: command?.first)
            surface.pathPreviewContext = PathPreviewContext(
                source: LocalFileSource(),
                cwd: { [weak surface] in surface?.reportedPwd },
                hostLabel: "This Mac",
                isLocal: true,
                remoteBlock: block.map { reason in { @Sendable @MainActor in reason } })
            surface.onOpenPreview = { path, line, context in
                BentoTerminalWindow.openPreview(path: path, line: line, context: context)
            }
            vm.onRawDataReceived = { [weak surface] data in
                Task { @MainActor [weak surface] in surface?.feed(data) }
            }
            self.plainSurface = surface
            self.paneHost = nil
            surface.linkOriginProvider = { LinkOrigin(paneID: nil, host: tabLinkHost) }
        } else {
            let tiled = GhosttyTiledPaneHost(viewModel: vm, theme: theme)
            tiled.linkHost = tabLinkHost
            self.paneHost = tiled
            self.plainSurface = nil
        }
    }

    func connect() {
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.connect()
            await self.viewModel.applyTmuxChoice(self.choice)
        }
    }

    func teardown() {
        paneHost?.teardown()
        plainSurface?.teardown()
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
        // A plain tab has no session behind it; it is deduped by title instead
        // (see `openPlain`), and this is only its starting point.
        case .noTmux: return .local("local")
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
        case .createOrAttach, .noTmux:
            return TmuxControlMode.remoteLaunchCommandLine(sessionName: name)
        }
    }
}
#endif
