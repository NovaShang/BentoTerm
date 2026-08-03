import Foundation
import BentoUISharedKit

/// "Things you can open" — the one list behind every launcher surface.
///
/// Three surfaces want the same answer to "what can I open right now?": the
/// command palette (⌘P), the Dock icon's menu, and App Intents / Shortcuts.
/// They can't share a palette section, an `NSMenu`, or an `AppEntity` — so what
/// they share is this: plain data with a stable identity, plus one place that
/// knows how to act on it. The data types (`OpenTarget`, `LaunchAction`,
/// `LocalSessionInfo`, `TmuxSessionNaming`, `tildeAbbreviated`) now live in
/// BentoUISharedKit so iOS renders the same vocabulary; this file is the
/// Mac-only half: composing the sources and performing targets through
/// `BentoTerminalWindow`.

// MARK: - The provider

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoAgentKit
import BentoSessionKit
import BentoFoundationKit

/// Composes the three sources into `[OpenTarget]` and performs them.
///
/// **Where the session list comes from.** The live `tmux ls` result is polled
/// every 5s by the Mac app and pushed *into* core via
/// `BentoTerminalWindow.setLocalServerSessions` — the dependency already points
/// app → core, and this reads the value where it lands
/// (`BentoTerminalWindow.serverSessions`) rather than reaching back out to the
/// app. That list is the LOCAL server's, so sessions open on an ssh host are
/// deliberately excluded from it: these rows attach on the local machine, and a
/// remote name here would create an empty local session under it. Sessions this app has open are unioned in, so a cold start (poll hasn't
/// fired yet) still lists what's on screen. Every source is an injectable
/// closure, which is also how the tests compose a provider with no tmux, no
/// `~/.ssh/config` and no `UserDefaults` in sight.
@MainActor
public final class OpenTargetProvider {
    public static let shared = OpenTargetProvider()

    private let sessionSource: @MainActor () -> [String]
    private let sshHostSource: @MainActor () -> [String]
    private let launchSource: @MainActor () -> [LaunchRecord]
    private let sessionInfoSource: @MainActor () -> [String: LocalSessionInfo]

    public init(sessions: @escaping @MainActor () -> [String] = { BentoTerminalWindow.serverSessions },
                sshHosts: @escaping @MainActor () -> [String] = { SSHConfigHosts.hosts() },
                launches: @escaping @MainActor () -> [LaunchRecord] = { PaletteRecents.shared.launches },
                sessionInfo: @escaping @MainActor () -> [String: LocalSessionInfo] = { BentoTerminalWindow.serverSessionInfo }) {
        self.sessionSource = sessions
        self.sshHostSource = sshHosts
        self.launchSource = launches
        self.sessionInfoSource = sessionInfo
    }

    public func sessionTargets() -> [OpenTarget] {
        // The name list stays the authority on WHICH sessions exist; the info
        // map only decorates. A session the poll hasn't described yet (created
        // a second ago) is therefore a row with no subtitle, never a missing
        // row — which is the same rule `serverSessions` already follows.
        let info = sessionInfoSource()
        return sessionSource().map { name in
            OpenTarget(kind: .tmuxSession(name: name), title: name,
                       subtitle: info[name]?.subtitle(),
                       systemImage: "macwindow", matchText: "session \(name)")
        }
    }

    public func sshTargets() -> [OpenTarget] {
        sshHostSource().map { alias in
            OpenTarget(kind: .sshHost(alias: alias), title: alias, subtitle: "ssh \(alias)",
                       systemImage: "network", matchText: "ssh \(alias)")
        }
    }

    public func recentTargets() -> [OpenTarget] {
        launchSource().map { record in
            let program = record.command.isEmpty ? "shell" : record.command
            let where_ = tildeAbbreviated(record.dir)
            return OpenTarget(kind: .recentLaunch(record),
                              title: "\(program)  ·  \(where_)",
                              subtitle: nil,
                              systemImage: "clock.arrow.circlepath",
                              matchText: "\(program) \(record.dir)")
        }
    }

    /// Everything, in the order a flat consumer (Dock menu, Shortcuts) should
    /// show it: what's running, then what you ran recently, then where you can
    /// reach.
    public func allTargets() -> [OpenTarget] {
        sessionTargets() + recentTargets() + sshTargets()
    }

    /// WHAT opening a target means, with no opinion about WHERE it lands.
    ///
    /// Two surfaces open targets into two different places — the palette and
    /// the Dock menu into a new window, the launcher into the window it is
    /// already occupying — and the one thing they must never disagree about is
    /// what a row does. So the decision is made once, here, and the
    /// destination is chosen by the caller.
    enum Route {
        /// Attach (or create) a session on the LOCAL server.
        case localSession(String)
        /// A plain no-tmux shell running `ssh <alias>`.
        case sshShell(alias: String)
        /// Build a session for a remembered launch.
        case agent(AgentSpec)
    }

    func route(for target: OpenTarget) -> Route? {
        switch target.kind {
        case .tmuxSession(let name):
            // `.local` explicitly: every source behind `sessionTargets` is the
            // local server's list, and a bare name would be ambiguous now that
            // a session can live on an ssh host.
            return .localSession(name)

        case .sshHost(let alias):
            // Plain `ssh <alias>` in a no-tmux tab. The reason this used to be
            // the only option — that session keys weren't namespaced per host
            // and every `TmuxCLI` call site ran against the local server — no
            // longer holds: keys are `TmuxSessionID`s now and the local-only
            // operations take a `LocalTmuxSessionName` that a remote session
            // cannot produce. The launcher's host row now carries the second
            // action (`tmux`) beside this one; see `LauncherView`.
            return .sshShell(alias: alias)

        case .recentLaunch(let record):
            // Local only for now (`host` is reserved, never written).
            guard record.host == nil else { return nil }
            let name = TmuxSessionNaming.sessionName(
                forDirectory: record.dir, existing: Set(sessionSource()))
            // A new tmux SESSION, not a pane in whatever window happens to be
            // front: a remembered launch is a place you go back to work, and it
            // shouldn't graft itself onto an unrelated session. The launch line
            // is `new-session -A`, so a stale session list (the poll runs every
            // 5s) attaches instead of failing.
            return .agent(AgentSpec(sessionName: name,
                                    workingDir: record.dir,
                                    agentCommand: record.command,
                                    layout: .solo))
        }
    }

    /// Do the thing, in a window of its own (palette, Dock menu, Shortcuts).
    public func open(_ target: OpenTarget) {
        switch route(for: target) {
        case .localSession(let name): BentoTerminalWindow.focusOrOpen(.local(name))
        case .sshShell(let alias):    BentoTerminalWindow.newSSHWindow(host: alias)
        case .agent(let spec):        BentoTerminalWindow.newWindow(agent: spec)
        case nil:                     break
        }
    }

    /// Perform a creation verb in a window of its own (Dock menu, Shortcuts).
    ///
    /// Here rather than in each surface for the same reason `open` is here: the
    /// Dock menu and the launcher must not be able to disagree about what "New
    /// Empty Session" builds, only about where it lands.
    public func perform(_ action: LaunchAction) {
        switch action {
        case .plainTerminal:
            BentoTerminalWindow.newWindowNoTmux()
        case .agentSession:
            BentoTerminalWindow.onNewAgentSession?()
        case .emptySession:
            BentoTerminalWindow.newWindow(session: BentoTerminalWindow.nextSessionName())
        }
    }

    /// The same verb, into the launcher's own window. Returns false when the
    /// shell was not consumed — see `LaunchAction.consumesShell`.
    @discardableResult
    func perform(_ action: LaunchAction, into shell: TerminalSessionWindow) -> Bool {
        switch action {
        case .plainTerminal:
            BentoTerminalWindow.fill(shell, plainTitle: "Terminal")
            return true
        case .agentSession:
            BentoTerminalWindow.onNewAgentSession?()
            return false
        case .emptySession:
            return BentoTerminalWindow.fill(shell, localSession: BentoTerminalWindow.nextSessionName())
        }
    }

    /// Do the same thing, but INTO `shell` — a window that is currently showing
    /// the launcher and has no session yet. Returns false when the shell was
    /// not consumed (the session was already open elsewhere and got fronted
    /// instead), which is the caller's cue to close the launcher window itself.
    @discardableResult
    func open(_ target: OpenTarget, into shell: TerminalSessionWindow) -> Bool {
        switch route(for: target) {
        case .localSession(let name):
            return BentoTerminalWindow.fill(shell, localSession: name)
        case .sshShell(let alias):
            BentoTerminalWindow.fill(shell, plainTitle: alias, command: ["ssh", alias])
            return true
        case .agent(let spec):
            return BentoTerminalWindow.fill(shell, agent: spec)
        case nil:
            return false
        }
    }
}
#endif
