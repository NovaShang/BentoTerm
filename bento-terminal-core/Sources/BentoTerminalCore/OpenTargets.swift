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
///
/// `host` is nil for everything today and means "this Mac". It exists NOW,
/// unused, purely so that remembering a launch on a remote machine later is a
/// new value rather than a store migration: the synthesized `Codable` encodes a
/// nil optional by omitting the key and decodes a missing key as nil, so JSON
/// written before this field existed still decodes, and JSON written today is
/// still readable by a build that predates it.
public struct LaunchRecord: Codable, Equatable, Sendable {
    public let dir: String
    /// "" = plain shell.
    public let command: String
    /// nil = local. Reserved for remote entries; nothing writes it yet.
    public let host: String?

    public init(dir: String, command: String, host: String? = nil) {
        self.dir = dir
        self.command = command
        self.host = host
    }
}

// MARK: - The noise rule

/// Which launches are worth remembering.
///
/// Every creation path now reports in (that's the point — the list was
/// permanently empty while only the palette's own rows recorded). But most
/// creations are the boring default: a plain login shell in `$HOME`, which is
/// what "new window" already does with no help from a recents list. Twenty of
/// those would push out the one row the user actually wanted.
///
/// So: **remember a launch when it says something the default doesn't** —
/// either a real program was requested, or the directory isn't home. A plain
/// shell in home is the only combination that's pure noise, and it's also by
/// far the most common, which is exactly why it's the one we drop.
///
/// A launch with no known directory is dropped too: the row's whole job is to
/// reopen *somewhere*, and it can't name a session without a folder to name it
/// after.
public enum RecentLaunchPolicy {
    /// Trim, expand `~`, and drop a trailing slash so `/a/b` and `/a/b/` are
    /// one entry rather than two.
    public static func normalizedDir(_ raw: String?) -> String? {
        guard var dir = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty
        else { return nil }
        dir = (dir as NSString).expandingTildeInPath
        while dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
        return dir.isEmpty ? nil : dir
    }

    public static func normalizedCommand(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// nil = don't remember this one.
    public static func record(dir: String?, command: String?, host: String? = nil) -> LaunchRecord? {
        guard let dir = normalizedDir(dir) else { return nil }
        let command = normalizedCommand(command)
        let home = NSHomeDirectory()
        guard !command.isEmpty || dir != home else { return nil }
        return LaunchRecord(dir: dir, command: command, host: host)
    }
}

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

/// Composes the three sources into `[OpenTarget]` and performs them.
///
/// **Where the session list comes from.** The live `tmux ls` result is polled
/// every 5s by the Mac app and pushed *into* core via
/// `BentoTerminalWindow.setServerSessions` — the dependency already points app
/// → core, and this reads the value where it lands
/// (`BentoTerminalWindow.serverSessions`) rather than reaching back out to the
/// app. Sessions this app has open are unioned in, so a cold start (poll hasn't
/// fired yet) still lists what's on screen. Every source is an injectable
/// closure, which is also how the tests compose a provider with no tmux, no
/// `~/.ssh/config` and no `UserDefaults` in sight.
@MainActor
public final class OpenTargetProvider {
    public static let shared = OpenTargetProvider()

    private let sessionSource: @MainActor () -> [String]
    private let sshHostSource: @MainActor () -> [String]
    private let launchSource: @MainActor () -> [LaunchRecord]

    public init(sessions: @escaping @MainActor () -> [String] = { BentoTerminalWindow.serverSessions },
                sshHosts: @escaping @MainActor () -> [String] = { SSHConfigHosts.hosts() },
                launches: @escaping @MainActor () -> [LaunchRecord] = { PaletteRecents.shared.launches }) {
        self.sessionSource = sessions
        self.sshHostSource = sshHosts
        self.launchSource = launches
    }

    public func sessionTargets() -> [OpenTarget] {
        sessionSource().map { name in
            OpenTarget(kind: .tmuxSession(name: name), title: name, subtitle: nil,
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

    /// Do the thing.
    public func open(_ target: OpenTarget) {
        switch target.kind {
        case .tmuxSession(let name):
            BentoTerminalWindow.focusOrOpen(session: name)

        case .sshHost(let alias):
            // Plain `ssh <alias>` in a no-tmux tab, deliberately. A "connect
            // with tmux" variant would have to namespace session keys per host
            // and fix every `TmuxCLI` call site — all of which run against the
            // LOCAL server — so offering it today would silently drive the
            // wrong machine.
            BentoTerminalWindow.newSSHWindow(host: alias)

        case .recentLaunch(let record):
            // Local only for now (`host` is reserved, never written).
            guard record.host == nil else { return }
            let name = TmuxSessionNaming.sessionName(
                forDirectory: record.dir, existing: Set(sessionSource()))
            // A new tmux SESSION, not a pane in whatever window happens to be
            // front: a remembered launch is a place you go back to work, and it
            // shouldn't graft itself onto an unrelated session. The launch line
            // is `new-session -A`, so a stale session list (the poll runs every
            // 5s) attaches instead of failing.
            BentoTerminalWindow.newWindow(agent: AgentSpec(
                sessionName: name,
                workingDir: record.dir,
                agentCommand: record.command,
                layout: .solo))
        }
    }
}
#endif
