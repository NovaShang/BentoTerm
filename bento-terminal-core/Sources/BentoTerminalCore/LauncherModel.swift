#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Foundation

/// The launcher's content: what a window with no session yet offers to open.
///
/// This is the **level-0 palette, rendered as a page** (docs/launcher-design.md
/// §2). It is deliberately not a new screen with its own idea of what exists —
/// it reads `OpenTargetProvider`, exactly like the ⌘P palette and the Dock
/// menu. What differs is *weight*, not vocabulary and not membership.
///
/// **Order is by intent frequency, and the verbs come first** (§5). The
/// original layout put the three lists up top and hid the creation actions in a
/// footer, which read as "pick something that already exists, or, if you must,
/// make one". Actual use inverted that: the commonest reason to be looking at
/// this page is wanting a shell to run one command in, and that was the row
/// furthest from the eye and three sections down. So:
///
/// 1. **New Terminal without tmux** — the throwaway shell, on its own, first.
/// 2. **New Agent Session / New Empty Session** — the two tmux creations.
/// 3. **Sessions** — what is already running.
/// 4. **Recent Launches** — a few, expandable.
/// 5. **SSH Hosts** — chips plus a count.
///
/// The weighting inside the lists is unchanged and still earns its keep:
/// sessions and recents are "continue" — few, high intent — so they get full
/// rows, while hosts are "go somewhere new" and a `~/.ssh/config` can hold
/// dozens of aliases of which a handful are ever opened by hand, so they
/// collapse to one line of chips. Recents now collapse the same way for the
/// same reason: the tail of that list decays fast, so three are shown and the
/// rest are one click away.
///
/// **Nothing here touches the network.** Every source is a local read: the
/// session list is the poll's cached array, `~/.ssh/config` is one small file,
/// the recents are `UserDefaults`. Enumerating sessions on a host is a round
/// trip and belongs to the step stack (§3 level 1), which is not built yet.
@MainActor
public final class LauncherModel: ObservableObject {
    /// The four kinds, in the order they render. Named for the tmux/ssh nouns
    /// the rest of the app uses — a launcher that invents its own words is the
    /// first place the vocabulary splits.
    public enum Section: String, CaseIterable, Sendable {
        case actions, sessions, recents, hosts

        public var title: String {
            switch self {
            // No header over the action rows: they are the first thing on the
            // page, there is nothing above them to be told apart from, and
            // "Create" over three rows that all begin with "New" is a label
            // that repeats its own content.
            case .actions:  return ""
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
            /// Make something new (the top three rows).
            case create(LaunchAction)
            /// Reveal the hosts as full rows (the "16 ▸" affordance).
            case expandHosts
            /// Reveal the rest of the recent launches.
            case expandRecents
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

    /// The three creation verbs. Always all three, always first — see
    /// `rank(actions:)` for why a query does not filter them.
    @Published public private(set) var actions: [Row] = []
    @Published public private(set) var sessions: [Row] = []
    /// Only the rows currently shown: three while collapsed, the rest behind
    /// the expander.
    @Published public private(set) var recents: [Row] = []
    /// Hosts that match the query. Rendered as chips while `hostsCollapsed`.
    @Published public private(set) var hosts: [Row] = []
    @Published public private(set) var hostsExpanded = false
    @Published public private(set) var recentsExpanded = false
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

    /// How many recent launches show before the expander. Three, because the
    /// section now sits BELOW the actions and the running sessions: six rows of
    /// history there would push the ssh hosts off a 520pt page, and the fourth-
    /// newest launch is already a rare pick. Expanding shows up to
    /// `recentLimit`.
    public static let recentPreviewLimit = 3

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

    /// True when there is nothing to OPEN — no sessions, no recents, no
    /// `~/.ssh/config`. The page is never empty now (the three creation rows
    /// are unconditional), so this no longer means "show a different screen";
    /// it means the lists below the actions have nothing in them and the page
    /// should say so in one sentence rather than leave three bare headers.
    ///
    /// Deliberately independent of the query: "your filter matched nothing" and
    /// "this machine has nothing to open" are different sentences (§5).
    public var isEmpty: Bool {
        allSessions.isEmpty && allRecents.isEmpty && allHosts.isEmpty
    }

    public var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Hosts stay a chip row until you expand them or start typing.
    public var hostsCollapsed: Bool { !hostsExpanded && !isFiltering }

    /// Recents show three until you expand them or start typing. Typing opens
    /// both collapsed sections for the same reason: a query means you know what
    /// you are looking for, and hiding a match behind a "show more" would be
    /// the search lying about what it found.
    public var recentsCollapsed: Bool { !recentsExpanded && !isFiltering }

    /// Total host aliases, for the "16 ▸" count (not the filtered count — the
    /// number is the size of the thing you'd be expanding).
    public var hostCount: Int { allHosts.count }
    public var recentCount: Int { min(allRecents.count, Self.recentLimit) }
    public var hasHiddenRecents: Bool { recentsCollapsed && recentCount > recents.count }

    /// The chips shown while collapsed, and whether more exist behind them.
    public var hostChips: [Row] { Array(hosts.prefix(Self.hostChipLimit)) }
    public var hasHiddenHostChips: Bool { hosts.count > Self.hostChipLimit }

    /// Everything ↑/↓ can reach, top to bottom. Each collapsed section
    /// contributes exactly one extra focusable row — its expander — so the
    /// keyboard path never has to know about chips or hidden tails.
    public var focusableRows: [Row] {
        var rows = actions + sessions + recents
        if hasHiddenRecents { rows.append(recentsExpanderRow) }
        if hostsCollapsed {
            if !hosts.isEmpty { rows.append(hostsExpanderRow) }
        } else {
            rows += hosts
        }
        return rows
    }

    public var hostsExpanderRow: Row {
        Row(id: "hosts:expand", section: .hosts,
            title: hostCount == 1 ? "1 host" : "\(hostCount) hosts",
            subtitle: nil, systemImage: "chevron.right",
            action: .expandHosts, matchText: "hosts")
    }

    public var recentsExpanderRow: Row {
        Row(id: "recents:expand", section: .recents,
            title: "\(recentCount - recents.count) more",
            subtitle: nil, systemImage: "chevron.down",
            action: .expandRecents, matchText: "recent launches")
    }

    public func expandHosts() {
        hostsExpanded = true
        rebuild()
    }

    public func expandRecents() {
        recentsExpanded = true
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
        actions = LaunchAction.displayOrder.map { action in
            Row(id: action.id, section: .actions, title: action.title,
                subtitle: action.detail, systemImage: action.systemImage,
                action: .create(action), matchText: action.matchText)
        }
        sessions = rank(allSessions, section: .sessions, limit: Self.sessionLimit)
        recents = rank(allRecents, section: .recents,
                       limit: recentsCollapsed ? Self.recentPreviewLimit : Self.recentLimit)
        // Hosts are never capped: collapsed they're chips (capped at display
        // time), expanded or filtered you asked for them.
        hosts = rank(allHosts, section: .hosts, limit: Int.max)

        let rows = focusableRows
        // Pinned rows never disappear, so "is it still there?" is no longer
        // enough to keep the selection honest: with the create rows always
        // present, a resting selection on the first of them would survive every
        // keystroke and ⏎ after typing "bento" would open a shell instead of
        // `bento`. So a selection parked on a create row is also re-derived
        // while filtering — typing is searching, and the search's own first
        // result is what ⏎ must mean.
        let parked = isFiltering && actions.contains { $0.id == selectedID }
        if selectedID == nil || parked || !rows.contains(where: { $0.id == selectedID }) {
            selectedID = defaultSelectionID
        }
    }

    /// Where ⏎ points when the selection has to be reset.
    ///
    /// With no query: the first action, i.e. "New Terminal without tmux". That
    /// is the whole point of the reordering — the commonest intent should cost
    /// one keystroke, and ⌘N ⏎ is now a throwaway shell.
    ///
    /// With a query: the first row that MATCHED, which is never an action,
    /// because the actions are pinned rather than filtered (`rank(actions:)`).
    /// Typing "bento" and pressing ⏎ has to attach `bento`; leaving the
    /// selection parked on a create row would turn a search into a creation,
    /// which is the one mistake this page must not make. Only when the query
    /// matches nothing openable does it fall back — to the best-matching action
    /// if the query looks like one of them ("agent", "empty"), else to the
    /// first action, unchanged from the resting state.
    private var defaultSelectionID: String? {
        guard isFiltering else { return actions.first?.id }
        var content = sessions + recents
        if hasHiddenRecents { content.append(recentsExpanderRow) }
        content += hostsCollapsed ? [] : hosts
        if let first = content.first { return first.id }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let best = LaunchAction.displayOrder
            .compactMap { a in PaletteFuzzy.score(query: trimmed, target: a.matchText).map { ($0, a) } }
            .max { $0.0 < $1.0 }?.1
        return best?.id ?? actions.first?.id
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
                   + "recentsCollapsed=\(recentsCollapsed) "
                   + "selected=\(selectedID ?? "<none>")"]
        func dump(_ title: String, _ rows: [Row]) {
            guard !rows.isEmpty else { return }
            out.append("  [\(title.isEmpty ? "create" : title)]")
            for r in rows {
                let sub = r.subtitle.map { " — \($0)" } ?? ""
                out.append("    \(r.title)\(sub)  ->  \(describe(r.action))")
            }
        }
        dump(Section.actions.title, actions)
        if isEmpty {
            out.append("  <nothing to open> one line: "
                       + "no sessions, no recent launches, no ~/.ssh/config")
            return out.joined(separator: "\n")
        }
        dump(Section.sessions.title, sessions)
        dump(Section.recents.title, recents)
        if hasHiddenRecents {
            out.append("    \(recentsExpanderRow.title)  ->  expand recents")
        }
        if hostsCollapsed {
            let chips = hostChips.map(\.title).joined(separator: " ")
            if !hosts.isEmpty {
                out.append("  [\(Section.hosts.title)] chips: \(chips)"
                           + (hasHiddenHostChips ? " …" : "")
                           + "  expander: \(hostsExpanderRow.title)")
            }
        } else {
            dump(Section.hosts.title, hosts)
            for r in hosts { out.append("    \(r.title) actions: [ssh] [tmux]") }
        }
        return out.joined(separator: "\n")
    }

    private func describe(_ action: Row.Action) -> String {
        switch action {
        case .expandHosts: return "expand hosts"
        case .expandRecents: return "expand recents"
        case .create(let a):
            switch a {
            case .plainTerminal: return "plain local shell, no tmux, in place"
            case .agentSession:  return "open the agent wizard (launcher stays)"
            case .emptySession:  return "new empty tmux session, in place"
            }
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
