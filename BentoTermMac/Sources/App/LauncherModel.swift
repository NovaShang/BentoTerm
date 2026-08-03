#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Foundation
import BentoSessionKit
import BentoFoundationKit
import BentoUISharedKit

/// The launcher's content: what a window with no session yet offers to open.
///
/// It reads `OpenTargetProvider`, exactly like the ⌘P palette and the Dock
/// menu, so the three surfaces cannot disagree about what exists or what it is
/// called. What differs is *weight* and *shape*, not vocabulary and not
/// membership.
///
/// **It is a page, not a search result.** This model used to carry a query, a
/// fuzzy ranking and a selection cursor, because the launcher was described as
/// "the level-0 palette rendered as a page" and the toolbar's search slot held
/// a filter over these very rows. That conflated two things. The toolbar's
/// search field is the app's search — the command palette — and it means the
/// same thing in every window, launcher or session. So the palette does the
/// searching (its own level-0 content comes from the same provider, hosts
/// included), and this page went back to being a page: a fixed, short list of
/// what you can make and what you can go back to.
///
/// **Two columns, and the verbs come first.** A window is usually far bigger
/// than this page's content, so a single left-aligned list stranded a dozen
/// short rows in one corner of a mostly empty screen. The content is now one
/// centred block of two columns:
///
/// ```
/// left                              right
///   ▣  BentoTerm                      Sessions
///   New Terminal without tmux         Recent Launches
///   New Agent Session…
///   New Empty Session
///   SSH ▸
/// ```
///
/// The left column is "what you can make" — brand, the three creation verbs,
/// and one row that opens the `~/.ssh/config` menu. The right is "what you can
/// go back to" — what is running, then what you ran recently. The verbs lead
/// because the commonest reason to be looking at this page is wanting a shell
/// to run one command in, which the original layout buried in a footer.
///
/// The weighting inside the lists is unchanged and still earns its keep:
/// sessions and recents are "continue" — few, high intent — so they get full
/// rows, while hosts are "go somewhere new" and a `~/.ssh/config` can hold
/// dozens of aliases of which a handful are ever opened by hand. What changed
/// is the shape of that compression: hosts used to be a wrapping chip line plus
/// a "16 ▸" expander, and they are now a single row that opens the same menu
/// the toolbar's `New ⌄` offers. Recents still show three with the rest one
/// click away.
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
            // No header over the action rows: the brand lockup is directly
            // above them, and "Create" over three rows that all begin with
            // "New" is a label that repeats its own content.
            case .actions:  return ""
            case .sessions: return "Sessions"
            case .recents:  return "Recent Launches"
            case .hosts:    return "SSH Hosts"
            }
        }

        /// Which side of the block this section draws on when the page is wide
        /// enough for two. Narrow, the right column falls in underneath the
        /// left one in exactly this order, so reading order is the same in
        /// both forms and neither is a special case.
        public var column: Column {
            switch self {
            // Hosts are a left-column row here because what the row does is
            // open a menu, and opening a menu is a verb. The section title
            // exists for the palette's Hosts group, not for this page.
            case .actions, .hosts:  return .left
            case .sessions, .recents: return .right
            }
        }
    }

    public enum Column: String, Sendable { case left, right }

    /// One row. `action` is data, not a closure, so a test (and the structure
    /// dump) can assert what a row would DO without doing it.
    public struct Row: Identifiable, Equatable {
        public enum Action: Equatable {
            /// Open this target, in the launcher's own window.
            case open(OpenTarget)
            /// Make something new (the three verbs).
            case create(LaunchAction)
            /// Open the `~/.ssh/config` menu — the toolbar's own, item for item.
            case sshMenu
            /// Reveal the rest of the recent launches.
            case expandRecents
        }

        public let id: String
        public let section: Section
        public let title: String
        public let subtitle: String?
        public let systemImage: String
        public let action: Action

        public var column: Column { section.column }
    }

    // MARK: Sources (unfiltered, captured once per refresh)

    private let provider: OpenTargetProvider
    private var allSessions: [OpenTarget] = []
    private var allRecents: [OpenTarget] = []
    private var allHosts: [OpenTarget] = []

    // MARK: Published state

    /// The three creation verbs. Always all three, always first.
    @Published public private(set) var actions: [Row] = []
    @Published public private(set) var sessions: [Row] = []
    /// Only the rows currently shown: three until expanded.
    @Published public private(set) var recents: [Row] = []
    @Published public private(set) var recentsExpanded = false

    /// Recents are capped harder than sessions: the tail of a recents list
    /// decays fast (only the newest few are ever the one you meant), while
    /// every live session is a plausible destination.
    public static let recentLimit = 6
    public static let sessionLimit = 8

    /// How many recent launches show before the expander.
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
    /// `~/.ssh/config`. The page is never blank (the three creation rows are
    /// unconditional), so this does not mean "show a different screen"; it
    /// means the lists have nothing in them and the page should say so in one
    /// sentence rather than leave section headers standing over nothing.
    public var isEmpty: Bool {
        allSessions.isEmpty && allRecents.isEmpty && allHosts.isEmpty
    }

    /// Total host aliases, for the `SSH` row's subtitle.
    public var hostCount: Int { allHosts.count }
    public var hasHosts: Bool { !allHosts.isEmpty }
    public var hosts: [OpenTarget] { allHosts }
    public var recentCount: Int { min(allRecents.count, Self.recentLimit) }
    public var hasHiddenRecents: Bool { !recentsExpanded && recentCount > recents.count }

    /// Whether the page draws a right column at all.
    ///
    /// A machine with hosts but nothing running has nothing to put there, and
    /// half an empty block beside a centred left column reads as a layout that
    /// failed to load. That page collapses to the one-column form instead.
    public var hasRightColumn: Bool { !allSessions.isEmpty || !allRecents.isEmpty }

    /// The left column's rows: the three verbs, then the host menu when there
    /// is a `~/.ssh/config` to open.
    public var leftRows: [Row] { hasHosts ? actions + [sshMenuRow] : actions }

    /// The right column's rows, top to bottom.
    public var rightRows: [Row] {
        var rows = sessions + recents
        if hasHiddenRecents { rows.append(recentsExpanderRow) }
        return rows
    }

    /// The one row that stands for every ssh host. Its subtitle is the count,
    /// so the size of the menu is known before it opens.
    public var sshMenuRow: Row {
        Row(id: "hosts:menu", section: .hosts, title: "SSH",
            subtitle: hostCount == 1
                ? "1 host in ~/.ssh/config" : "\(hostCount) hosts in ~/.ssh/config",
            systemImage: "network", action: .sshMenu)
    }

    public var recentsExpanderRow: Row {
        Row(id: "recents:expand", section: .recents,
            title: "\(recentCount - recents.count) more",
            subtitle: nil, systemImage: "chevron.down",
            action: .expandRecents)
    }

    public func expandRecents() {
        recentsExpanded = true
        rebuild()
    }

    // MARK: Building

    private func rebuild() {
        actions = LaunchAction.displayOrder.map { action in
            Row(id: action.id, section: .actions, title: action.title,
                subtitle: action.detail, systemImage: action.systemImage,
                action: .create(action))
        }
        sessions = allSessions.prefix(Self.sessionLimit).map { row($0, section: .sessions) }
        recents = allRecents
            .prefix(recentsExpanded ? Self.recentLimit : Self.recentPreviewLimit)
            .map { row($0, section: .recents) }
    }

    private func row(_ target: OpenTarget, section: Section) -> Row {
        Row(id: target.id, section: section, title: target.title,
            subtitle: target.subtitle, systemImage: target.systemImage,
            action: .open(target))
    }

    // MARK: Structure dump (verification)

    /// A flat, readable description of what the page currently shows — which
    /// column each section is in, section titles, row titles, order, and what
    /// each row would do.
    ///
    /// This exists because the launcher cannot be checked the way a terminal
    /// pane can: it has no scrollback to grep and no tmux state to query, and
    /// the machines this is developed on have neither Screen Recording nor
    /// Accessibility permission, so nothing can screenshot it or click it. A
    /// text rendering of the structure is the part that can be asserted
    /// mechanically; only the LOOK then needs eyes.
    public func structureDump() -> String {
        var out = ["launcher: empty=\(isEmpty) hosts=\(hostCount) "
                   + "rightColumn=\(hasRightColumn) recentsExpanded=\(recentsExpanded)"]
        out.append("  [left] brand: logo + \(LauncherBrand.wordmark)")
        func dump(_ rows: [Row], indent: String) {
            for r in rows {
                let sub = r.subtitle.map { " — \($0)" } ?? ""
                out.append("\(indent)\(r.title)\(sub)  ->  \(describe(r.action))")
            }
        }
        dump(leftRows, indent: "    ")
        if isEmpty {
            out.append("  <nothing to open> one line: "
                       + "no sessions, no recent launches, no ~/.ssh/config")
            return out.joined(separator: "\n")
        }
        guard hasRightColumn else {
            out.append("  [right] <not drawn>")
            return out.joined(separator: "\n")
        }
        out.append("  [right]")
        if !sessions.isEmpty {
            out.append("    (\(Section.sessions.title))")
            dump(sessions, indent: "      ")
        }
        if !recents.isEmpty {
            out.append("    (\(Section.recents.title))")
            dump(recents, indent: "      ")
            if hasHiddenRecents {
                out.append("      \(recentsExpanderRow.title)  ->  expand recents")
            }
        }
        return out.joined(separator: "\n")
    }

    private func describe(_ action: Row.Action) -> String {
        switch action {
        case .sshMenu:
            return "menu: \(SSHHostMenu.connectTitle) ▸ / \(SSHHostMenu.remoteTmuxTitle) ▸"
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
