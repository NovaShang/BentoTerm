#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Foundation

/// The launcher's content: what a window with no session yet offers to open.
///
/// This is the **level-0 palette, rendered as a page** (docs/launcher-design.md
/// §2). It is deliberately not a new screen with its own idea of what exists —
/// it reads `OpenTargetProvider`, exactly like the ⌘P palette and the Dock
/// menu, in the same order those two use (`allTargets`: what's running, then
/// what you ran recently, then where you can reach). What differs is *weight*,
/// not vocabulary and not membership.
///
/// **Weight, and why the three kinds don't get equal space** (§5): sessions and
/// recents are "continue" — few of them, high intent, you are probably going
/// back to one, so they get full rows. Hosts are "go somewhere new" — a
/// `~/.ssh/config` can hold dozens of aliases of which a handful are ever
/// opened by hand, so they collapse to one line of chips plus a count. Typing
/// dissolves that distinction (a query means you know what you're looking for),
/// which is why a filtered host becomes a full row with its two actions.
///
/// **Nothing here touches the network.** Every source is a local read: the
/// session list is the poll's cached array, `~/.ssh/config` is one small file,
/// the recents are `UserDefaults`. Enumerating sessions on a host is a round
/// trip and belongs to the step stack (§3 level 1), which is not built yet.
@MainActor
public final class LauncherModel: ObservableObject {
    /// The three kinds, in the order they render. Named for the tmux/ssh nouns
    /// the rest of the app uses — a launcher that invents its own words is the
    /// first place the vocabulary splits.
    public enum Section: String, CaseIterable, Sendable {
        case sessions, recents, hosts

        public var title: String {
            switch self {
            case .sessions: return "Sessions"
            case .recents:  return "Recent Launches"
            case .hosts:    return "SSH Hosts"
            }
        }
    }

    /// One selectable thing. `action` is data, not a closure, so a test (and
    /// the structure dump) can assert what a row would DO without doing it.
    public struct Row: Identifiable, Equatable {
        public enum Action: Equatable {
            /// Open this target, in the launcher's own window.
            case open(OpenTarget)
            /// Reveal the hosts as full rows (the "16 ▸" affordance).
            case expandHosts
        }

        public let id: String
        public let section: Section
        public let title: String
        public let subtitle: String?
        public let systemImage: String
        public let action: Action
        /// What the fuzzy scorer sees — the provider's `matchText`, so a query
        /// that finds a row in the palette finds the same row here.
        public let matchText: String
    }

    // MARK: Sources (unfiltered, captured once per refresh)

    private let provider: OpenTargetProvider
    private var allSessions: [OpenTarget] = []
    private var allRecents: [OpenTarget] = []
    private var allHosts: [OpenTarget] = []

    // MARK: Published state

    @Published public private(set) var sessions: [Row] = []
    @Published public private(set) var recents: [Row] = []
    /// Hosts that match the query. Rendered as chips while `hostsCollapsed`.
    @Published public private(set) var hosts: [Row] = []
    @Published public private(set) var hostsExpanded = false
    @Published public private(set) var selectedID: String?
    /// Bumped to pull first responder back to the filter field (⌘P).
    @Published public private(set) var focusToken = 0

    public func focusSearch() { focusToken &+= 1 }

    @Published public var query: String = "" {
        didSet { guard query != oldValue else { return }; rebuild() }
    }

    /// How many host chips fit on one line before the count takes over. A
    /// number, not a scroller: the chip row is a reminder that hosts exist, and
    /// the moment you need to hunt through it you should be typing instead.
    public static let hostChipLimit = 8

    /// Recents are capped harder than sessions: the tail of a recents list
    /// decays fast (only the newest few are ever the one you meant), while
    /// every live session is a plausible destination.
    public static let recentLimit = 6
    public static let sessionLimit = 8

    /// nil = the shared provider. Spelled as an optional rather than a default
    /// of `.shared` because a default argument is evaluated in the CALLER's
    /// isolation, and the provider is main-actor state.
    public init(provider: OpenTargetProvider? = nil) {
        self.provider = provider ?? .shared
        refresh()
    }

    /// Re-read the sources (cheap, all local) and rebuild the rows.
    public func refresh() {
        allSessions = provider.sessionTargets()
        allRecents = provider.recentTargets()
        allHosts = provider.sshTargets()
        rebuild()
    }

    /// True when there is genuinely nothing to offer — no sessions, no recents,
    /// no `~/.ssh/config`. Deliberately independent of the query: "your filter
    /// matched nothing" and "this machine has nothing to open" are different
    /// sentences, and only the second one gets the one-line treatment (§5).
    public var isEmpty: Bool {
        allSessions.isEmpty && allRecents.isEmpty && allHosts.isEmpty
    }

    public var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Hosts stay a chip row until you expand them or start typing.
    public var hostsCollapsed: Bool { !hostsExpanded && !isFiltering }

    /// Total host aliases, for the "16 ▸" count (not the filtered count — the
    /// number is the size of the thing you'd be expanding).
    public var hostCount: Int { allHosts.count }

    /// The chips shown while collapsed, and whether more exist behind them.
    public var hostChips: [Row] { Array(hosts.prefix(Self.hostChipLimit)) }
    public var hasHiddenHostChips: Bool { hosts.count > Self.hostChipLimit }

    /// Everything ↑/↓ can reach, top to bottom. The collapsed host section
    /// contributes exactly one focusable row — the expander — so the keyboard
    /// path never has to know about chips.
    public var focusableRows: [Row] {
        var rows = sessions + recents
        if hostsCollapsed {
            if !hosts.isEmpty { rows.append(expanderRow) }
        } else {
            rows += hosts
        }
        return rows
    }

    public var expanderRow: Row {
        Row(id: "hosts:expand", section: .hosts,
            title: hostCount == 1 ? "1 host" : "\(hostCount) hosts",
            subtitle: nil, systemImage: "chevron.right",
            action: .expandHosts, matchText: "hosts")
    }

    public func expandHosts() {
        hostsExpanded = true
        rebuild()
    }

    // MARK: Selection

    public func select(_ id: String) { selectedID = id }

    /// ↑/↓. Wraps, like the palette's — with a handful of rows, stopping at the
    /// end is a dead key press for no benefit.
    public func moveSelection(_ delta: Int) {
        let rows = focusableRows
        guard !rows.isEmpty else { selectedID = nil; return }
        let idx = rows.firstIndex { $0.id == selectedID } ?? 0
        selectedID = rows[(idx + delta + rows.count) % rows.count].id
    }

    public var selectedRow: Row? {
        focusableRows.first { $0.id == selectedID }
    }

    // MARK: Building

    private func rebuild() {
        sessions = rank(allSessions, section: .sessions, limit: Self.sessionLimit)
        recents = rank(allRecents, section: .recents, limit: Self.recentLimit)
        // Hosts are never capped: collapsed they're chips (capped at display
        // time), expanded or filtered you asked for them.
        hosts = rank(allHosts, section: .hosts, limit: Int.max)

        let rows = focusableRows
        if selectedID == nil || !rows.contains(where: { $0.id == selectedID }) {
            selectedID = rows.first?.id
        }
    }

    /// Filter + order one section. Empty query keeps the provider's order (the
    /// same order the Dock menu shows); a query ranks by `PaletteFuzzy` — the
    /// palette's scorer, so "btm" narrows to the same row in both surfaces.
    private func rank(_ targets: [OpenTarget], section: Section, limit: Int) -> [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return targets.prefix(limit).map { row($0, section: section) }
        }
        var scored: [(Int, OpenTarget)] = []
        for target in targets {
            guard let s = PaletteFuzzy.score(query: trimmed, target: target.matchText)
            else { continue }
            scored.append((s, target))
        }
        scored.sort {
            if $0.0 != $1.0 { return $0.0 > $1.0 }
            return $0.1.title < $1.1.title
        }
        return scored.prefix(limit).map { row($0.1, section: section) }
    }

    private func row(_ target: OpenTarget, section: Section) -> Row {
        Row(id: target.id, section: section, title: target.title,
            subtitle: target.subtitle, systemImage: target.systemImage,
            action: .open(target), matchText: target.matchText)
    }

    // MARK: Structure dump (verification)

    /// A flat, readable description of what the page currently shows — section
    /// titles, row titles, order, what each row would do, and where the
    /// selection is.
    ///
    /// This exists because the launcher cannot be checked the way a terminal
    /// pane can: it has no scrollback to grep and no tmux state to query, and
    /// the machines this is developed on have neither Screen Recording nor
    /// Accessibility permission, so nothing can screenshot it or click it. A
    /// text rendering of the structure is the part that can be asserted
    /// mechanically; only the LOOK then needs eyes.
    public func structureDump() -> String {
        var out = ["launcher: query=\(query.isEmpty ? "<empty>" : query) "
                   + "empty=\(isEmpty) hostsCollapsed=\(hostsCollapsed) "
                   + "selected=\(selectedID ?? "<none>")"]
        if isEmpty {
            out.append("  <truly empty> one line + one action (New Session)")
            return out.joined(separator: "\n")
        }
        func dump(_ title: String, _ rows: [Row]) {
            guard !rows.isEmpty else { return }
            out.append("  [\(title)]")
            for r in rows {
                let sub = r.subtitle.map { " — \($0)" } ?? ""
                out.append("    \(r.title)\(sub)  ->  \(describe(r.action))")
            }
        }
        dump(Section.sessions.title, sessions)
        dump(Section.recents.title, recents)
        if hostsCollapsed {
            let chips = hostChips.map(\.title).joined(separator: " ")
            if !hosts.isEmpty {
                out.append("  [\(Section.hosts.title)] chips: \(chips)"
                           + (hasHiddenHostChips ? " …" : "")
                           + "  expander: \(expanderRow.title)")
            }
        } else {
            dump(Section.hosts.title, hosts)
            for r in hosts { out.append("    \(r.title) actions: [ssh] [tmux]") }
        }
        out.append("  [footer] New Session (⌘⇧T) · New Agent Session…")
        return out.joined(separator: "\n")
    }

    private func describe(_ action: Row.Action) -> String {
        switch action {
        case .expandHosts: return "expand hosts"
        case .open(let t):
            switch t.kind {
            case .tmuxSession(let name): return "attach local session \(name) in place"
            case .sshHost(let alias):    return "ssh \(alias) in place"
            case .recentLaunch(let r):
                let cmd = r.command.isEmpty ? "shell" : r.command
                return "new session in \(tildeAbbreviated(r.dir)) running \(cmd), in place"
            }
        }
    }
}
#endif
