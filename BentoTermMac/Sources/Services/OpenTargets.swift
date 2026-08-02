import Foundation

/// "Things you can open" — the one list behind every launcher surface.
///
/// Three surfaces want the same answer to "what can I open right now?": the
/// command palette (⌘P), the Dock icon's menu, and App Intents / Shortcuts.
/// They can't share a palette section, an `NSMenu`, or an `AppEntity` — so what
/// they share is this: plain data with a stable identity, plus one place that
/// knows how to act on it. Nothing here is palette-shaped; `OpenTarget` carries
/// no SwiftUI, no closures, and no palette types, so an `NSMenuItem` or an
/// `AppEntity` can be built from it just as easily as a `PaletteItem`.
///
/// Three kinds today: a tmux session on the local server, an SSH host alias
/// from `~/.ssh/config`, and a recent (directory, command) launch.

// MARK: - Recent launch record

/// A remembered launch: a directory plus the program that ran in it ("" = a
/// plain shell). This is the persisted shape — see `PaletteRecents`.

// MARK: - tmux session naming

/// Names a new session after the folder it opens in.
///
/// tmux reads `:` and `.` as target separators (`session:window.pane`), so a
/// name containing either addresses something else entirely — a session called
/// `foo.bar` is unreachable by name and every `-t` we send it goes somewhere
/// surprising. Directory basenames are full of dots (`foo.bar`, `.config`,
/// dotted version dirs), which is exactly why this exists.
public enum TmuxSessionNaming {
    /// Strip everything tmux can't address, collapse the damage, and never
    /// return an empty string.
    public static func sanitize(_ raw: String) -> String {
        var out = ""
        for ch in raw {
            if ch == ":" || ch == "." || ch == "/" || ch.isWhitespace {
                out.append("-")
            } else {
                out.append(ch)
            }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "session" : out
    }

    /// A session name for `dir`, distinct from every name in `existing`.
    /// Collisions get `-2`, `-3`, … — the same shape as the tab bar's
    /// `session-N`, so the two conventions read alike.
    public static func sessionName(forDirectory dir: String, existing: Set<String>) -> String {
        let base = sanitize(((dir as NSString).lastPathComponent))
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}

// MARK: - Session metadata

/// What the local `tmux ls` poll knows about a session beyond its name.
///
/// A bare session name answers "what is it called" and nothing else, and the
/// launcher's whole job is to help you pick between several of them — "2
/// windows · 5 minutes ago" is what turns a name into a place. The poll that
/// feeds the session list already runs `list-windows` per session for the
/// toolbar, so this costs no extra tmux round trips; it is only the numbers
/// travelling the same path the names already travel (app → core, see
/// `BentoTerminalWindow.setLocalServerSessions`).
public struct LocalSessionInfo: Equatable, Sendable {
    public let name: String
    public let windowCount: Int
    /// Last output/keystroke/attach, as tmux reports it. nil = unknown.
    public let lastActivity: Date?

    public init(name: String, windowCount: Int, lastActivity: Date?) {
        self.name = name
        self.windowCount = windowCount
        self.lastActivity = lastActivity
    }

    /// "2 windows · 5 minutes ago" — the one phrasing every launcher surface
    /// uses. tmux's own noun ("window"), and a relative time because the
    /// question is always "how stale is this", never "what o'clock was it".
    public func subtitle(now: Date = Date()) -> String? {
        var parts: [String] = []
        if windowCount > 0 {
            parts.append(windowCount == 1 ? "1 window" : "\(windowCount) windows")
        }
        if let lastActivity, lastActivity > .distantPast {
            parts.append(Self.relative(lastActivity, now: now))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// Deliberately hand-rolled and coarse. `RelativeDateTimeFormatter` would
    /// say "in 0 seconds" for a session touched a moment ago (the poll's clock
    /// and tmux's can disagree by a hair), and the launcher is read at a
    /// glance: minute buckets are all the precision the decision needs.
    static func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

// MARK: - The target model

/// One openable thing. `id` is stable across rebuilds so a menu, a palette row,
/// and an App Intent entity can all key off the same string.
public struct OpenTarget: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A tmux session on the local server (loaded or not).
        case tmuxSession(name: String)
        /// A `Host` alias from `~/.ssh/config`. Opening it runs plain
        /// `ssh <alias>` — see `OpenTargetProvider.open`.
        case sshHost(alias: String)
        /// A remembered (directory, command) pair.
        case recentLaunch(LaunchRecord)
    }

    public let kind: Kind
    /// Primary label (session name, host alias, "claude · ~/code/bento-term").
    public let title: String
    /// Dimmed secondary line, or nil.
    public let subtitle: String?
    /// SF Symbol name — AppKit menus, SwiftUI rows and App Intents all take one.
    public let systemImage: String
    /// Free-text the consumer can match against (the palette fuzzy-ranks it).
    public let matchText: String

    public var id: String {
        switch kind {
        case .tmuxSession(let name): return "session:" + name
        case .sshHost(let alias): return "ssh:" + alias
        case .recentLaunch(let r): return "launch:\(r.host ?? "")|\(r.dir)|\(r.command)"
        }
    }

    public init(kind: Kind, title: String, subtitle: String?,
                systemImage: String, matchText: String) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.matchText = matchText
    }
}

// MARK: - The three ways to make something new

/// The creation verbs, shared by every surface that offers them.
///
/// There are exactly three ways to get a terminal that did not exist a moment
/// ago, and four places offer them: the toolbar's `+` menu, the Shell menu, the
/// launcher page, and the Dock menu. Until now each place spelled them its own
/// way — the toolbar said "New Session with Agent…" while the launcher's footer
/// said "New Agent Session…", and the Shell menu called a blank tmux session
/// plain "New Session" while the toolbar called it "New Empty Session". One
/// concept with two names is two concepts to the reader. So the words live
/// here, once, and the surfaces render them.
///
/// **Order is part of the definition.** The quick throwaway shell is first
/// because it is what the user reaches for most: one command, no session, gone
/// when it closes. The two tmux creations follow as a pair — same shape, one
/// word different — because choosing between them is a second, smaller
/// question than "do I even want tmux here".
public enum LaunchAction: String, CaseIterable, Identifiable, Sendable {
    /// A raw local pty, no tmux, gone when you close it.
    case plainTerminal
    /// The agent wizard (name, folder, agent, layout).
    case agentSession
    /// A blank tmux session, auto-named `session-N`.
    case emptySession

    /// Declaration order is not display order — `allCases` would otherwise
    /// silently decide the layout of four surfaces.
    public static let displayOrder: [LaunchAction] = [.plainTerminal, .agentSession, .emptySession]

    public var id: String { "new:" + rawValue }

    public var title: String {
        switch self {
        case .plainTerminal: return "New Terminal without tmux"
        case .agentSession:  return "New Agent Session…"
        case .emptySession:  return "New Empty Session"
        }
    }

    /// The one-line explanation. It is the toolbar menu's tooltip text and the
    /// launcher row's subtitle — the same sentence, because the difference
    /// between these three is exactly what a new user needs told.
    public var detail: String {
        switch self {
        case .plainTerminal:
            return "A quick local shell. Closing it discards it for good."
        case .agentSession:
            return "A fresh tmux session running Claude, Codex or another agent, "
                 + "optionally split into panes."
        case .emptySession:
            return "A blank tmux session on the host. It keeps running after you disconnect."
        }
    }

    public var systemImage: String {
        switch self {
        case .plainTerminal: return "terminal"
        case .agentSession:  return "rectangle.stack"
        case .emptySession:  return "plus.rectangle"
        }
    }

    /// What a typed query is matched against. The detail text is deliberately
    /// excluded: "shell", "tmux" and "session" appear in all three sentences,
    /// so matching them would make every query hit every action.
    public var matchText: String {
        switch self {
        case .plainTerminal: return "new terminal without tmux shell"
        case .agentSession:  return "new agent session claude codex"
        case .emptySession:  return "new empty session tmux"
        }
    }

    /// Whether performing this INTO a launcher window uses that window up.
    ///
    /// False for the agent path only, and not as an implementation detail: the
    /// wizard is a separate window that can be cancelled, so the question the
    /// launcher is asking has not been answered yet and its window must still
    /// be there if you back out (docs/launcher-design.md §7).
    public var consumesShell: Bool { self != .agentSession }
}

/// `~`-abbreviate a path for display. Shared so every launcher surface shortens
/// the same way.
public func tildeAbbreviated(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

// MARK: - The provider

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoTerminalCore

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
