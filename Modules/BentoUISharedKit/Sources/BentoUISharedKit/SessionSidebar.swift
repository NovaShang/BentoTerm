import SwiftUI
import BentoTmuxKit
import BentoSessionKit
import BentoFoundationKit

// MARK: - The tree

/// One row's identity in the session sidebar. A pane is keyed by tmux's
/// `pane_id`, which it keeps whether it shares a window with the others
/// (split) or has one to itself (alone) — so a row is the same row in both.
public enum SidebarItemID: Hashable, Sendable {
    case session(String)
    case pane(session: String, pane: String)
}

/// A pane — one program, an agent usually — as a sidebar row.
public struct SidebarPaneRow: Identifiable, Equatable, Sendable {
    public let sessionKey: String
    /// tmux's `pane_id` (`%12`).
    public let paneID: String
    /// The index of the window it is in — ⌘0…⌘9, and where to land in a
    /// session this app window doesn't have open.
    public let windowIndex: Int?
    /// For the session this app window shows, when the pane has its window to
    /// itself: that window (the row's menu is then the window's).
    public let soleWindow: TmuxWindowID?
    public let name: String
    /// What a hover says: what runs in it and where.
    public let detail: String
    public let status: PaneChrome.Status

    public init(sessionKey: String, paneID: String, windowIndex: Int?, soleWindow: TmuxWindowID?,
                name: String, detail: String, status: PaneChrome.Status) {
        self.sessionKey = sessionKey
        self.paneID = paneID
        self.windowIndex = windowIndex
        self.soleWindow = soleWindow
        self.name = name
        self.detail = detail
        self.status = status
    }

    public var id: SidebarItemID { .pane(session: sessionKey, pane: paneID) }
}

/// A tmux session: a group that opens to its panes. Picking it shows them
/// split side by side; picking one of its panes shows that pane alone.
public struct SidebarSessionRow: Identifiable, Equatable, Sendable {
    /// `TmuxSessionID.key`.
    public let key: String
    public let name: String
    public let subtitle: String
    /// Panes anywhere in the session waiting on the user.
    public let waiting: Int
    public let panes: [SidebarPaneRow]
    /// The session this app window shows.
    public let isCurrent: Bool
    /// On this Mac's server — rename and kill can reach it from here.
    public let isLocal: Bool
    /// Open in another app window (picking it brings that window forward).
    public let isOpenElsewhere: Bool

    public init(key: String, name: String, subtitle: String, waiting: Int,
                panes: [SidebarPaneRow], isCurrent: Bool, isLocal: Bool,
                isOpenElsewhere: Bool) {
        self.key = key
        self.name = name
        self.subtitle = subtitle
        self.waiting = waiting
        self.panes = panes
        self.isCurrent = isCurrent
        self.isLocal = isLocal
        self.isOpenElsewhere = isOpenElsewhere
    }

    public var id: String { key }
}

/// One tmux server: this Mac, or an ssh host.
public struct SidebarSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let sessions: [SidebarSessionRow]

    public init(id: String, title: String, sessions: [SidebarSessionRow]) {
        self.id = id
        self.title = title
        self.sessions = sessions
    }
}

/// What the sidebar shows and what its rows ask for. The window that hosts it
/// fills `sections` (from its own session live, the rest from the poll) and
/// answers the callbacks; the view holds no tmux knowledge of its own.
@MainActor
public final class SessionSidebarModel: ObservableObject {
    @Published public var sections: [SidebarSection] = [] {
        didSet { expandCurrent() }
    }
    /// What this app window shows, as the host last reported it: the session
    /// row while split, the pane row when one is shown alone.
    @Published public var selection: SidebarItemID?
    @Published public var expanded: Set<String> = []

    public var onSelectSession: ((SidebarSessionRow) -> Void)?
    public var onSelectPane: ((SidebarPaneRow) -> Void)?
    public var onOpenInNewWindow: ((SidebarSessionRow) -> Void)?
    public var onRenameSession: ((SidebarSessionRow) -> Void)?
    public var onKillSession: ((SidebarSessionRow) -> Void)?
    /// The session this app window shows: close the window, keep it running.
    public var onDetachSession: (() -> Void)?
    /// Hand the session's size back to tmux (only offered while something
    /// has fixed it — `canReleaseSize`).
    public var onReleaseSize: (() -> Void)?
    @Published public var canReleaseSize = false

    private var lastCurrentKey: String?

    public init() {}

    /// The session you are in is open; switching to another opens that one.
    /// Others stay as the user left them.
    private func expandCurrent() {
        let current = sections.lazy.flatMap(\.sessions).first(where: \.isCurrent)?.key
        guard let current, current != lastCurrentKey else { return }
        lastCurrentKey = current
        expanded.insert(current)
    }

    func row(for id: SidebarItemID) -> (SidebarSessionRow, SidebarPaneRow?)? {
        for section in sections {
            for session in section.sessions {
                switch id {
                case .session(let key) where key == session.key:
                    return (session, nil)
                case .pane(let key, _) where key == session.key:
                    if let p = session.panes.first(where: { $0.id == id }) { return (session, p) }
                default:
                    continue
                }
            }
        }
        return nil
    }
}

// MARK: - The view

/// The window's navigator: every tmux session on this server (and the ssh
/// hosts open in Bento), each opening to its panes. It is also how you choose
/// what you see: a session row shows its panes split side by side, a pane row
/// shows that pane alone (the old Parallel / Focus, without a switch).
///
/// Rows follow the system sidebar: one line, the picture (a grid for a
/// session, the status glyph for a pane), the name, and on the right only
/// what waits on you. The state colours stay
/// in the glyphs; nothing else in the list is coloured, so the one amber
/// count is what the eye lands on.
@MainActor
public struct SessionSidebar: View {
    @ObservedObject var model: SessionSidebarModel
    /// The session this app window shows — its rows' menus act on it.
    @ObservedObject var viewModel: TerminalViewModel
    @StateObject private var actions = WindowActionsState()

    public init(model: SessionSidebarModel, viewModel: TerminalViewModel) {
        self.model = model
        self.viewModel = viewModel
    }

    public var body: some View {
        List(selection: selection) {
            ForEach(model.sections) { section in
                if model.sections.count > 1 {
                    Section(section.title) { content(of: section) }
                } else {
                    content(of: section)
                }
            }
        }
        .listStyle(.sidebar)
        .windowActionDialogs(viewModel: viewModel, state: actions)
        .animation(.snappy, value: model.sections)
    }

    @ViewBuilder
    private func content(of section: SidebarSection) -> some View {
        ForEach(section.sessions) { session in
            sessionGroup(session)
        }
    }

    @ViewBuilder
    private func sessionGroup(_ session: SidebarSessionRow) -> some View {
        if session.panes.isEmpty {
            // Another host's session we only know the name of: nothing to open.
            sessionLabel(session)
                .tag(SidebarItemID.session(session.key))
        } else {
            DisclosureGroup(isExpanded: expandedBinding(session.key)) {
                ForEach(session.panes) { pane in
                    paneRow(pane, in: session)
                        .tag(pane.id)
                }
                // Reordering moves windows, so only while each pane has its own.
                .onMove(perform: session.isCurrent && session.panes.allSatisfy { $0.soleWindow != nil }
                        ? { source, offset in moveWindows(source, offset, in: session) } : nil)
            } label: {
                sessionLabel(session)
            }
            .tag(SidebarItemID.session(session.key))
        }
    }

    private func sessionLabel(_ session: SidebarSessionRow) -> some View {
        SidebarRow {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        } title: {
            Text(session.name)
        } trailing: {
            WaitingCount(count: session.waiting)
        }
        .help(session.subtitle)
        .contextMenu { sessionMenu(session) }
    }

    private func paneRow(_ pane: SidebarPaneRow, in session: SidebarSessionRow) -> some View {
        SidebarRow {
            Image(systemName: pane.status.symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: pane.status.glyphHex))
        } title: {
            Text(pane.name)
        } trailing: {
            EmptyView()
        }
        .help(pane.detail)
        .contextMenu {
            if session.isCurrent, let window = pane.soleWindow {
                WindowContextMenu(viewModel: viewModel, state: actions,
                                  window: window, axis: .vertical)
            } else {
                Button("Show Alone") { model.onSelectPane?(pane) }
                if !session.isCurrent, !session.isOpenElsewhere {
                    Button("Open in New Window") { model.onOpenInNewWindow?(session) }
                }
            }
        }
    }

    @ViewBuilder
    private func sessionMenu(_ session: SidebarSessionRow) -> some View {
        if !session.isCurrent {
            Button(session.isOpenElsewhere ? "Show Its Window" : "Show Split") {
                model.onSelectSession?(session)
            }
            if !session.isOpenElsewhere {
                Button("Open in New Window") { model.onOpenInNewWindow?(session) }
            }
            Divider()
        }
        if session.isCurrent || session.isLocal {
            Button("Rename Session…") { model.onRenameSession?(session) }
            if session.isCurrent, model.canReleaseSize, let release = model.onReleaseSize {
                Button("Release Size", action: release)
            }
            Divider()
            if session.isCurrent, let detach = model.onDetachSession {
                Button("Detach (keep running)", action: detach)
                Divider()
            }
            Button("Kill Session…", role: .destructive) { model.onKillSession?(session) }
        }
    }

    // MARK: Bindings

    /// Picking a row goes there; the host then reports what is on screen
    /// (the session row while split, the pane shown alone otherwise), which
    /// is what the selection settles on.
    private var selection: Binding<SidebarItemID?> {
        Binding(
            get: { model.selection },
            set: { id in
                guard let id, id != model.selection, let (session, pane) = model.row(for: id) else { return }
                model.selection = id
                if let pane {
                    model.onSelectPane?(pane)
                } else {
                    model.onSelectSession?(session)
                }
            })
    }

    private func expandedBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { model.expanded.contains(key) },
                set: { if $0 { model.expanded.insert(key) } else { model.expanded.remove(key) } })
    }

    /// The order here IS tmux's window order, so a drop runs `move-window`.
    /// SwiftUI counts `offset` in the pre-removal array; `reorderWindow` wants
    /// the final position.
    private func moveWindows(_ source: IndexSet, _ offset: Int, in session: SidebarSessionRow) {
        guard let from = source.first, session.panes.indices.contains(from),
              let id = session.panes[from].soleWindow else { return }
        let destination = offset > from ? offset - 1 : offset
        Task { await viewModel.reorderWindow(id, toIndex: destination) }
    }
}

// MARK: - Rows

/// Every row of the sidebar: one line at the system's sidebar row height —
/// the picture, the name, and on the right only what waits on you. What a
/// second line would say (window count, what the pane is doing) is in the
/// row's tooltip.
private struct SidebarRow<Icon: View, Title: View, Trailing: View>: View {
    @ViewBuilder var icon: Icon
    @ViewBuilder var title: Title
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            icon.frame(width: 18)
            title
                .lineLimit(1)
            Spacer(minLength: 4)
            trailing
        }
        .accessibilityElement(children: .combine)
    }
}

/// How many panes wait on you: the one coloured thing in the list.
private struct WaitingCount: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color(hex: PaneState.awaitingHex)))
                .accessibilityLabel("\(count) waiting")
        }
    }
}

// MARK: - Building rows

public extension PaneChrome.Status {
    /// Which status a group shows when its members differ:
    /// awaiting → working → done → idle.
    var rank: Int {
        switch self {
        case .awaitingInput: return 3
        case .working: return 2
        case .doneUnseen: return 1
        case .idle: return 0
        }
    }
}

public enum SidebarText {
    /// A pane's one line. In order: the title its program set (Claude Code
    /// names the task there), a name the user gave its window, what runs in
    /// it, where it is.
    ///
    /// tmux titles every pane with the host name until a program says
    /// otherwise, and names a window after its command until the user renames
    /// it — neither says anything the next fallback doesn't.
    public static func paneName(title: String?, command: String?, path: String?,
                                windowName: String?, home: String, remoteHost: String?) -> String {
        let command = command?.trimmingCharacters(in: .whitespaces) ?? ""
        if let title = title?.trimmingCharacters(in: .whitespaces), isMeaningfulTitle(title, command: command) {
            return title
        }
        if let name = windowName?.trimmingCharacters(in: .whitespaces), !name.isEmpty, name != command,
           !PaneStatusOption.isInteractiveShell(name), !isHostName(name) {
            return name
        }
        if !command.isEmpty, !PaneStatusOption.isInteractiveShell(command) { return command }
        if let path, !path.isEmpty { return remoteHost == nil ? abbreviate(path, home: home) : path }
        return command.isEmpty ? "shell" : command
    }

    /// The hover line: what runs and where.
    public static func paneDetail(command: String?, path: String?, home: String,
                                  remoteHost: String?) -> String {
        let command = command?.trimmingCharacters(in: .whitespaces) ?? ""
        let place = path.flatMap { $0.isEmpty ? nil : (remoteHost == nil ? abbreviate($0, home: home) : $0) }
        return [command.isEmpty ? nil : command, place].compactMap { $0 }.joined(separator: " · ")
    }

    static func isMeaningfulTitle(_ title: String, command: String) -> Bool {
        guard !title.isEmpty, title != command, !isHostName(title) else { return false }
        // A host name is one ASCII word; a title a program sets rarely is.
        return title.contains(" ") || title.unicodeScalars.contains { !$0.isASCII }
    }

    static func isHostName(_ s: String) -> Bool {
        s.caseInsensitiveCompare(shortHostName) == .orderedSame
            || s.caseInsensitiveCompare(ProcessInfo.processInfo.hostName) == .orderedSame
    }

    private static let shortHostName: String = {
        ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? ""
    }()

    public static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// "3 panes" — tmux's noun.
    public static func paneCount(_ n: Int) -> String {
        n == 1 ? "1 pane" : "\(n) panes"
    }
}
