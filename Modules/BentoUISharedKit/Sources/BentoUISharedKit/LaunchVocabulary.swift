import Foundation
import BentoSessionKit

/// "Things you can open" — the vocabulary behind every launcher surface.
///
/// Three surfaces want the same answer to "what can I open right now?": the
/// command palette (⌘P), the Dock icon's menu, and App Intents / Shortcuts.
/// They can't share a palette section, an `NSMenu`, or an `AppEntity` — so what
/// they share is this: plain data with a stable identity. Nothing here is
/// palette-shaped; `OpenTarget` carries no SwiftUI, no closures, and no palette
/// types, so an `NSMenuItem` or an `AppEntity` can be built from it just as
/// easily as a `PaletteItem`. The provider that composes these targets and
/// performs them stays app-side (`OpenTargetProvider` on Mac) because acting on
/// a target means calling the app's own window API.
///
/// Three kinds today: a tmux session on the local server, an SSH host alias
/// from `~/.ssh/config`, and a recent (directory, command) launch.

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

/// One window of a local session, as the poll saw it.
public struct LocalWindowInfo: Equatable, Sendable, Identifiable {
    /// tmux's window INDEX — sparse (1, 3, 7…) once windows are closed, and the
    /// number `select-window -t` and the user's `prefix 3` both take.
    public let index: Int
    public let name: String
    public let isActive: Bool
    public let paneCount: Int

    public var id: Int { index }

    public init(index: Int, name: String, isActive: Bool, paneCount: Int) {
        self.index = index
        self.name = name
        self.isActive = isActive
        self.paneCount = paneCount
    }

    /// "3: claude  ·  2 panes" — the pane count only when there is more than
    /// one, since "1 pane" is the default and says nothing.
    public var label: String {
        paneCount > 1 ? "\(index): \(name)  ·  \(paneCount) panes" : "\(index): \(name)"
    }
}

/// What the local `tmux ls` poll knows about a session beyond its name.
///
/// A bare session name answers "what is it called" and nothing else, and the
/// launcher's whole job is to help you pick between several of them — "2
/// windows · 5 minutes ago" is what turns a name into a place. The poll that
/// feeds the session list already runs `list-windows` per session for the
/// toolbar, so this costs no extra tmux round trips; it is only the numbers
/// travelling the same path the names already travel.
public struct LocalSessionInfo: Equatable, Sendable {
    public let name: String
    public let windowCount: Int
    /// Last output/keystroke/attach, as tmux reports it. nil = unknown.
    public let lastActivity: Date?
    /// Does tmux have a client on it? Distinct from "open as a Bento tab": a
    /// session can be attached from another terminal entirely, and a menu that
    /// cannot tell those apart cannot answer "is anyone else in here".
    public let attached: Bool
    /// The session's windows, as the same poll saw them. Carried so a menu can
    /// offer "jump straight into window 3" without an async fetch that would
    /// land after the menu is already on screen. Empty when unknown.
    public let windows: [LocalWindowInfo]

    public init(name: String, windowCount: Int, lastActivity: Date?,
                attached: Bool = false, windows: [LocalWindowInfo] = []) {
        self.name = name
        self.windowCount = windowCount
        self.lastActivity = lastActivity
        self.attached = attached
        self.windows = windows
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
    public static func relative(_ date: Date, now: Date) -> String {
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
        /// `ssh <alias>`.
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
/// ago, and several places offer them. Until now each place spelled them its
/// own way — the toolbar said "New Session with Agent…" while the launcher's
/// footer said "New Agent Session…", and the Shell menu called a blank tmux
/// session plain "New Session" while the toolbar called it "New Empty Session".
/// One concept with two names is two concepts to the reader. So the words live
/// here, once, and the surfaces render them. (iOS's host-sessions sheet was
/// hand-rolling the same three labels until it adopted this type.)
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
    /// be there if you back out.
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
