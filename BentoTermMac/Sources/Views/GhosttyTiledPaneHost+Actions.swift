import BentoTmuxKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoSessionKit
import BentoUISharedKit

extension GhosttyTiledPaneHost {
    // MARK: - Menu / keyboard actions (reached via the responder chain)

    private var activePaneID: TmuxPaneID? { viewModel.activePaneID }

    /// Panes ordered top-to-bottom, left-to-right for stable navigation.
    private var orderedPaneIDs: [TmuxPaneID] {
        viewModel.paneViewModels
            .sorted { ($0.pane.y, $0.pane.x) < ($1.pane.y, $1.pane.x) }
            .map(\.paneID)
    }

    /// Splits only exist in Tiled mode — List keeps one pane per window, so
    /// ⌘D/⌘⇧D (and the pane-menu split items, hidden there) are no-ops.
    var splitsAllowed: Bool { viewModel.sessionMode != .list }

    @objc public func splitPaneVertically(_ sender: Any?) {
        guard splitsAllowed else { return }
        // iTerm2 "Split Vertically" = side-by-side panes (a vertical divider).
        viewModel.splitPane(horizontal: true)
    }

    @objc public func splitPaneHorizontally(_ sender: Any?) {
        guard splitsAllowed else { return }
        // iTerm2 "Split Horizontally" = stacked panes (a horizontal divider).
        viewModel.splitPane(horizontal: false)
    }

    /// Split seeded like List's "Duplicate Current": same working directory and
    /// start command as the active pane (which the menu just selected).
    @objc func splitDuplicateCurrent(_ sender: Any?) {
        guard splitsAllowed else { return }
        Task { [viewModel] in await viewModel.splitPane(horizontal: true, seed: .duplicateCurrent) }
    }

    /// Split seeded with an explicit directory and command — the dialog itself
    /// is a native directory chooser (with a command field baked in), seeded at
    /// the active pane's cwd. Same picker as List's New Window.
    @objc func splitWithPathCommand(_ sender: Any?) {
        guard splitsAllowed else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cwd = await self.viewModel.activePaneWorkingDirectory()
            presentNewPaneDirectoryPanel(
                title: "Split", prompt: "Split", initialDirectory: cwd
            ) { [viewModel = self.viewModel] path, command in
                Task { await viewModel.splitPane(horizontal: true, seed: .custom(path: path, command: command)) }
            }
        }
    }

    /// The focused pane's file context — the dock's tree roots itself here.
    var activePathPreviewContext: PathPreviewContext? {
        activePaneID.flatMap { cells[$0]?.surface.pathPreviewContext }
    }

    /// Pane menu → Move to Session → <name>. The menu already selected the
    /// pane, so activePaneID is the one to move (same convention as the other
    /// pane actions). The pane keeps running; where it lands follows the
    /// target's mode (Parallel → its current window, Focus → a new window),
    /// and an unsettled target asks where to land.
    @objc func movePaneToNamedSession(_ sender: Any?) {
        guard let active = activePaneID,
              let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        moveActivePane(active, to: name)
    }

    private func moveActivePane(_ pane: TmuxPaneID, to name: String) {
        Task { [weak self] in
            guard let vm = self?.viewModel else { return }
            await vm.movePane(pane, toSession: name) { [weak self] session in
                await self?.window?.askMoveLanding(session: session)
            }
        }
    }

    /// Pane menu → Move to Session → New Session…: prompt for a name, then
    /// the same move path (movePane creates the session when it's missing).
    @objc func movePaneToNewSession(_ sender: Any?) {
        guard let window, let active = activePaneID else { return }
        Task { [weak self] in
            guard let name = await window.askName(SessionPromptCopy.movePaneToNewSession)
            else { return }
            // Same landing pipeline: a typed name may match an EXISTING
            // session, so the unsettled-target prompt can still follow.
            self?.moveActivePane(active, to: name)
        }
    }

    @objc public func closeCurrentPane(_ sender: Any?) {
        guard let active = activePaneID else { return }
        viewModel.closePane(active)
    }

    @objc public func toggleCurrentPaneZoom(_ sender: Any?) {
        guard let active = activePaneID else { return }
        viewModel.toggleZoom(active)
    }

    /// ⌥⌘↑/↓ = "move what I'm in one step earlier/later", dispatched by mode
    /// like ⌃⌘T: in Parallel that's the pane within the layout (`swap-pane`),
    /// in Focus it's the whole window within the sidebar order
    /// (`move-window`). Focus has exactly one pane, so the Parallel meaning
    /// has nothing to act on there — and reordering stays reachable from the
    /// keyboard, not the drag alone.
    @objc public func swapActivePaneUp(_ sender: Any?) {
        moveActiveEarlier(true)
    }

    @objc public func swapActivePaneDown(_ sender: Any?) {
        moveActiveEarlier(false)
    }

    private func moveActiveEarlier(_ earlier: Bool) {
        if viewModel.sessionMode == .list {
            guard let window = viewModel.activeWindowID else { return }
            Task { [viewModel] in await viewModel.shiftWindow(window, earlier: earlier) }
        } else {
            guard let active = activePaneID else { return }
            viewModel.swapPane(active, up: earlier)
        }
    }

    // MARK: - Find in pane (⌘F)
    //
    // Pane-scoped on purpose: the toolbar's omnibox is app-scoped (commands /
    // files / sessions / windows / panes), this searches one pane's scrollback.
    // Different scope, different home.

    /// Which machine the FOCUSED pane means by `localhost` — what a URL typed
    /// into the browser's address bar resolves against, so "localhost:3000"
    /// means the same thing there as it does in the terminal you are looking at.
    var activeLinkOrigin: LinkOrigin? { activeSurface?.linkOrigin }

    /// The surface of the pane the user is actually working in.
    private var activeSurface: GhosttyTerminalSurface? {
        activePaneID.flatMap { cells[$0]?.surface }
    }

    @objc public func findInPane(_ sender: Any?) {
        activeSurface?.beginSearch()
    }

    @objc public func findNextMatch(_ sender: Any?) {
        activeSurface?.findNext()
    }

    @objc public func findPreviousMatch(_ sender: Any?) {
        activeSurface?.findPrevious()
    }

    @objc public func useSelectionForFind(_ sender: Any?) {
        activeSurface?.useSelectionForFind()
    }

    @objc public func selectNextPane(_ sender: Any?) {
        cyclePane(by: 1)
    }

    @objc public func selectPreviousPane(_ sender: Any?) {
        cyclePane(by: -1)
    }

    /// Switch to the window with tmux's `#{window_index}` == n (⌘0..⌘9).
    ///
    /// This targets the INDEX, not the nth position, so ⌘3 goes where
    /// `select-window -t 3` and tmux's own `prefix 3` go — and to the window the
    /// toolbar labels `3:…`. Indices are sparse once windows are closed (1, 3,
    /// 7…), so some digits do nothing; that is tmux's behavior, and it beats a
    /// key that silently lands somewhere other than the label says.
    private func selectWindow(index n: Int) {
        guard let window = viewModel.windows.first(where: { $0.index == n }) else { return }
        viewModel.selectWindow(window.id)
    }

    @objc public func selectWindow0(_ sender: Any?) { selectWindow(index: 0) }
    @objc public func selectWindow1(_ sender: Any?) { selectWindow(index: 1) }
    @objc public func selectWindow2(_ sender: Any?) { selectWindow(index: 2) }
    @objc public func selectWindow3(_ sender: Any?) { selectWindow(index: 3) }
    @objc public func selectWindow4(_ sender: Any?) { selectWindow(index: 4) }
    @objc public func selectWindow5(_ sender: Any?) { selectWindow(index: 5) }
    @objc public func selectWindow6(_ sender: Any?) { selectWindow(index: 6) }
    @objc public func selectWindow7(_ sender: Any?) { selectWindow(index: 7) }
    @objc public func selectWindow8(_ sender: Any?) { selectWindow(index: 8) }
    @objc public func selectWindow9(_ sender: Any?) { selectWindow(index: 9) }

    /// New tmux window (⌃⌘T), dispatched by mode: in List it's THE creation
    /// action — a new window seeded from the current pane (same as the
    /// sidebar's "Duplicate Current"); in Tiled it keeps the raw new-window
    /// behavior (compat — window management is de-emphasized there).
    @objc public func newTmuxWindow(_ sender: Any?) {
        if viewModel.sessionMode == .list {
            Task { [viewModel] in await viewModel.newListWindow(.duplicateCurrent) }
        } else {
            viewModel.newWindow()
        }
    }

    private func cyclePane(by step: Int) {
        let ids = orderedPaneIDs
        guard !ids.isEmpty else { return }
        let current = activePaneID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = ((current + step) % ids.count + ids.count) % ids.count
        viewModel.selectPane(ids[next])
    }
}

/// Selectors for the pane actions above, so SwiftUI `.commands` (or any menu)
/// can dispatch them through the responder chain to the focused host. The
/// terminal windows are plain AppKit `NSWindow`s with no `NSWindowController`
/// and no SwiftUI scene behind them, so a command has no view hierarchy to
/// target directly — the responder chain is how it finds whichever pane host is
/// focused, including inside a background tab's window.
public enum BentoPaneAction {
    public static let splitVertically = #selector(GhosttyTiledPaneHost.splitPaneVertically(_:))
    public static let splitHorizontally = #selector(GhosttyTiledPaneHost.splitPaneHorizontally(_:))
    public static let closePane = #selector(GhosttyTiledPaneHost.closeCurrentPane(_:))
    public static let toggleZoom = #selector(GhosttyTiledPaneHost.toggleCurrentPaneZoom(_:))
    public static let swapPaneUp = #selector(GhosttyTiledPaneHost.swapActivePaneUp(_:))
    public static let swapPaneDown = #selector(GhosttyTiledPaneHost.swapActivePaneDown(_:))
    public static let nextPane = #selector(GhosttyTiledPaneHost.selectNextPane(_:))
    public static let previousPane = #selector(GhosttyTiledPaneHost.selectPreviousPane(_:))
    public static let newTmuxWindow = #selector(GhosttyTiledPaneHost.newTmuxWindow(_:))
    public static let splitDuplicate = #selector(GhosttyTiledPaneHost.splitDuplicateCurrent(_:))
    public static let splitPathCommand = #selector(GhosttyTiledPaneHost.splitWithPathCommand(_:))
    public static let findInPane = #selector(GhosttyTiledPaneHost.findInPane(_:))
    public static let findNext = #selector(GhosttyTiledPaneHost.findNextMatch(_:))
    public static let findPrevious = #selector(GhosttyTiledPaneHost.findPreviousMatch(_:))
    public static let useSelectionForFind = #selector(GhosttyTiledPaneHost.useSelectionForFind(_:))

    /// ⌘0..⌘9 → switch to the window whose tmux index is that digit, so the
    /// key matches the `index:name` the toolbar shows. Array slot N = ⌘N.
    public static let selectWindow: [Selector] = [
        #selector(GhosttyTiledPaneHost.selectWindow0(_:)),
        #selector(GhosttyTiledPaneHost.selectWindow1(_:)),
        #selector(GhosttyTiledPaneHost.selectWindow2(_:)),
        #selector(GhosttyTiledPaneHost.selectWindow3(_:)),
        #selector(GhosttyTiledPaneHost.selectWindow4(_:)),
        #selector(GhosttyTiledPaneHost.selectWindow5(_:)),
        #selector(GhosttyTiledPaneHost.selectWindow6(_:)),
        #selector(GhosttyTiledPaneHost.selectWindow7(_:)),
        #selector(GhosttyTiledPaneHost.selectWindow8(_:)),
        #selector(GhosttyTiledPaneHost.selectWindow9(_:)),
    ]

    /// Dispatch an action through the responder chain (nil target → focused host).
    @MainActor public static func dispatch(_ selector: Selector, from sender: Any? = nil) {
        NSApp.sendAction(selector, to: nil, from: sender)
    }
}
#endif
