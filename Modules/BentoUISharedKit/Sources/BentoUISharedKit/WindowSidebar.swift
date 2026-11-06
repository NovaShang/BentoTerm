import SwiftUI
import BentoTmuxKit
import BentoAgentKit
import BentoSessionKit
import BentoFoundationKit
import BentoFilePreviewKit

/// List mode's window switcher for the big screens — ONE implementation
/// shared by macOS (hosted in an `NSHostingView`) and iPad. Native sidebar
/// styling; each row is a window with its live display name and aggregate
/// state dot. The phone uses the bottom tab bar instead.
///
/// Per-row: rename (which turns tmux automatic-rename off for that window),
/// creation offers exactly the two seeds (duplicate current / specify
/// path+command), and closing confirms because processes die.
@MainActor
public struct WindowSidebar: View {
    @ObservedObject var viewModel: TerminalViewModel
    /// iPad: lets "Path & Command…" browse the pane's remote tree.
    let pathContextProvider: (() -> PathPreviewContext?)?
    @State private var hoveredWindow: TmuxWindowID?
    @StateObject private var actions = WindowActionsState()

    public init(viewModel: TerminalViewModel,
                pathContextProvider: (() -> PathPreviewContext?)? = nil) {
        self.viewModel = viewModel
        self.pathContextProvider = pathContextProvider
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Native selection (accent pill) owns the row background untouched.
            // State lives entirely INSIDE the row content — the window name is
            // tinted by state and a trailing semantic glyph flags working /
            // awaiting — so it can never collide with or overflow the pill.
            List(selection: selectionBinding) {
                ForEach(viewModel.windows) { window in
                    row(window)
                        .tag(window.id)
                }
                .onMove(perform: moveRows)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)   // let the vibrancy chrome show

            newWindowButton
        }
        .windowActionDialogs(viewModel: viewModel, state: actions,
                             pathContextProvider: pathContextProvider)
    }

    /// Drag a row to rearrange the session's windows — the order here IS tmux's
    /// window order, so the drop runs `move-window` (see `reorderWindow`).
    /// `List` gives the platform gesture for free on both hosts: press-and-drag
    /// with the pointer on macOS, long-press-then-drag on iPad.
    ///
    /// SwiftUI's `offset` counts positions in the PRE-removal array, so a
    /// downward drag overshoots by one; `reorderWindow` wants the final resting
    /// position. Read the id out here rather than inside the Task — by the time
    /// that runs, a refresh may have reshuffled `windows` under the index.
    private func moveRows(_ source: IndexSet, _ offset: Int) {
        guard let from = source.first, viewModel.windows.indices.contains(from) else { return }
        let id = viewModel.windows[from].id
        let destination = offset > from ? offset - 1 : offset
        Task { await viewModel.reorderWindow(id, toIndex: destination) }
    }

    /// Selection mirrors the session's current window; picking a row is
    /// select-window. (List drives the native highlight from this binding.)
    private var selectionBinding: Binding<TmuxWindowID?> {
        Binding(
            get: { viewModel.activeWindowID },
            set: { id in if let id, id != viewModel.activeWindowID { viewModel.selectWindow(id) } }
        )
    }

    private func row(_ window: TmuxWindow) -> some View {
        let status = viewModel.windowStatus(window.id)
        return HStack(spacing: 6) {
            // Leading shortcut hint: ⌘N selects this window (the `index:name`
            // the toolbar labels and tmux's own `prefix <n>`). Varies in width
            // — indices are sparse — but the fixed state slot below keeps
            // names aligned regardless.
            shortcutHint(window)
            // Leading state glyph in a fixed-width slot so names stay aligned.
            // Shown on every row including the selected one — state reads the
            // same whether or not the row is current.
            stateIcon(status)
                .frame(width: 14)
            name(window.id, status: status)
                .lineLimit(1)
            Spacer(minLength: 6)
            closeButton(window.id)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredWindow = window.id }
            else if hoveredWindow == window.id { hoveredWindow = nil }
        }
        .contextMenu {
            WindowContextMenu(viewModel: viewModel, state: actions,
                              window: window.id, axis: .vertical)
        }
    }

    /// The window name, tinted by status (idle = default color). Applied on every
    /// row including the selected one, so state color is consistent throughout.
    @ViewBuilder
    private func name(_ id: TmuxWindowID, status: WindowDisplayStatus) -> some View {
        let label = Text(rowName(id))
        if let hex = statusHex(status) {
            label.foregroundStyle(Color(hex: hex))
        } else {
            label
        }
    }

    /// macOS rows already lead with the ⌘N hint, so the tmux `index:` prefix
    /// would be doubled — show the body name there. iPad has no hint, so it
    /// keeps the index-prefixed display name (the index is the only address
    /// that row carries).
    private func rowName(_ id: TmuxWindowID) -> String {
        #if canImport(AppKit)
        viewModel.windowBodyName(id)
        #else
        viewModel.windowDisplayName(id)
        #endif
    }

    /// The canonical palette hex for a status, or nil for idle (default color).
    private func statusHex(_ status: WindowDisplayStatus) -> UInt32? {
        status.chrome.accentHex
    }

    /// The ⌘N shortcut hint for a row — macOS only, since ⌘0..⌘9 maps to the
    /// tmux index here and that binding doesn't exist on iPad. Quiet secondary
    /// color so it never competes with the state glyph's semantic colors.
    @ViewBuilder
    private func shortcutHint(_ window: TmuxWindow) -> some View {
        #if canImport(AppKit)
        if let index = window.index {
            HStack(spacing: 2) {
                Image(systemName: "command")
                Text("\(index)")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .help("⌘\(index) switches to this window")
        }
        #else
        EmptyView()
        #endif
    }

    /// Leading state glyph — literally the Tiled pane title's language, from the
    /// shared table: working = blue play, awaiting = amber question, done =
    /// green check, idle = a quiet hollow gray ring (same `.circle` family, but
    /// empty = at rest).
    private func stateIcon(_ status: WindowDisplayStatus) -> some View {
        let s = status.chrome
        return glyph(s.symbol, s.glyphHex)
    }

    private func glyph(_ systemName: String, _ hex: UInt32) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12))
            .foregroundStyle(Color(hex: hex))
    }

    /// Trailing per-row close affordance. Faint at rest, full on hover (pointer
    /// devices); the always-visible faint state keeps it reachable on touch.
    /// Routes through the same confirm dialog as the context menu.
    private func closeButton(_ id: TmuxWindowID) -> some View {
        Button {
            actions.pendingClose = id
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close Window")
        .accessibilityLabel("Close Window")
        .opacity(hoveredWindow == id ? 1 : 0.35)
    }

    /// Bottom-edge creation affordance, styled like Mail/Notes' "New …"
    /// footer: borderless, secondary, leading-aligned. Two seeds inside.
    private func pathAndCommand() {
        #if canImport(AppKit)
        // macOS: the pane runs a local shell, so the dialog itself IS a
        // native directory chooser (with a command popup baked in) — no
        // intermediate form.
        Task {
            let cwd = await viewModel.activePaneWorkingDirectory()
            presentNewPaneDirectoryPanel(
                title: "New Window", prompt: "Create", initialDirectory: cwd
            ) { path, command in
                Task { await viewModel.newListWindow(.custom(path: path, command: command)) }
            }
        }
        #else
        // iPad: the path lives on the remote host — browse it (or type it)
        // in the shared form.
        actions.showsNewWindowForm = true
        #endif
    }

    private var newWindowButton: some View {
        NewWindowSeedMenu(viewModel: viewModel, onPathAndCommand: pathAndCommand) {
            Label("New Window", systemImage: "plus.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// "Move to Session" submenu for a window row/tab context menu — ONE
/// implementation shared by the sidebar (macOS/iPad) and the phone's bottom
/// tabs. Lists the OTHER sessions from the cached list (a refresh kicks off
/// when the menu opens, warming the next open — menus don't update while
/// displayed) plus "New Session…". The CONTAINER owns both follow-ups a
/// pick can need (an alert can't anchor inside the transient menu): the
/// new-session name prompt, and the landing prompt when `moveWindow`
/// returns `.needsLandingChoice`. Always actionable: moving the session's
/// last window makes the client follow it (see `moveWindow`).
@MainActor
public struct WindowMoveToSessionMenu: View {
    @ObservedObject var viewModel: TerminalViewModel
    let onPick: (String) -> Void
    let onNewSession: () -> Void

    public init(viewModel: TerminalViewModel,
                onPick: @escaping (String) -> Void,
                onNewSession: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onPick = onPick
        self.onNewSession = onNewSession
    }

    public var body: some View {
        Menu {
            let others = viewModel.availableTmuxSessions
                .filter { $0 != viewModel.activeTmuxSessionName }
            ForEach(others, id: \.self) { name in
                Button(name) { onPick(name) }
            }
            if !others.isEmpty { Divider() }
            Button {
                onNewSession()
            } label: {
                Label("New Session…", systemImage: "plus")
            }
        } label: {
            Label("Move to Session", systemImage: "rectangle.portrait.and.arrow.right")
        }
        .onAppear {
            Task { await viewModel.refreshTmuxSessions() }
        }
    }
}
