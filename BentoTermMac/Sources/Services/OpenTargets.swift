import Foundation
import BentoUISharedKit

/// "Things you can open" — the list behind the Dock menu.
///
/// Several surfaces want the same answer to "what can I open right now?": the
/// Dock icon's menu and App Intents / Shortcuts. They
/// can't share a SwiftUI row, an `NSMenu`, or an `AppEntity` — so what
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
                launches: @escaping @MainActor () -> [LaunchRecord] = { LaunchRecents.shared.launches },
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
                       systemImage: "macwindow")
        }
    }

    public func sshTargets() -> [OpenTarget] {
        sshHostSource().map { alias in
            OpenTarget(kind: .sshHost(alias: alias), title: alias, subtitle: "ssh \(alias)",
                       systemImage: "network")
        }
    }

    public func recentTargets() -> [OpenTarget] {
        // Local rows only: a target opens a session on the LOCAL server (see
        // `route`), and a directory remembered on an ssh host names nothing
        // here. Remote rows are offered by the split menus of a window
        // attached to that host instead.
        launchSource().filter { $0.host == nil }.map { record in
            let program = record.command.isEmpty ? "shell" : record.command
            let where_ = tildeAbbreviated(record.dir)
            return OpenTarget(kind: .recentLaunch(record),
                              title: "\(program)  ·  \(where_)",
                              subtitle: nil,
                              systemImage: "clock.arrow.circlepath")
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
    /// The decision is made once, here; `open` picks the destination
    /// (`focusOrOpen`: a session switches the front window, the rest get a
    /// window of their own).
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
            // cannot produce. The remote-tmux route lives in the ＋ menu's SSH
            // submenu beside the plain shell.
            return .sshShell(alias: alias)

        case .recentLaunch(let record):
            // `recentTargets` never offers a remote row; this is the backstop.
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
                                    agentCommand: record.command))
        }
    }

    /// Do the thing, in a window of its own (Dock menu, Shortcuts).
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
    /// Here rather than in each surface for the same reason `open` is here.
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

}
#endif
