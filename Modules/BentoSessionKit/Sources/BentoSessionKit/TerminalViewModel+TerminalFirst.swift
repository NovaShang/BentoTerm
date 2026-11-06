import Foundation
import BentoTmuxKit
import BentoFoundationKit

/// What a session's chrome shows, decided by its shape alone.
///
/// A session with exactly ONE pane in total (one window, one pane) is a plain
/// terminal as far as the user can tell, so it should look like one: no
/// Parallel/Focus switch (there is nothing to arrange) and no pane title bar
/// (there is nothing to tell apart). Agent state still shows — through the
/// pane's background wash, which never depended on the title bar.
///
/// "In total" is the point. Focus mode puts one pane in each of several
/// windows; that session has plenty to arrange and switch between, so it keeps
/// its chrome even though the window on screen holds a single pane.
public enum SessionChrome {
    /// One pane, one window — or nothing listed yet, which is what a session
    /// looks like for the instant before its first `list-panes` lands, and it
    /// is a single pane in every case Bento creates.
    public static func isSinglePane(paneCount: Int, windowCount: Int) -> Bool {
        paneCount <= 1 && windowCount <= 1
    }

    /// The Parallel/Focus switch appears as soon as there is a second pane or
    /// a second window.
    public static func showsModeSwitch(paneCount: Int, windowCount: Int) -> Bool {
        !isSinglePane(paneCount: paneCount, windowCount: windowCount)
    }
}

/// Which way "one more pane" splits: along the active pane's longer side.
///
/// Measured in tmux cells, not points — the grid is what both platforms agree
/// on, and it is what a split actually divides. A cell is about twice as tall
/// as it is wide, so a pane is "wide" when it has more than two columns per
/// row; comparing columns to rows directly would call an ordinary 80×24
/// terminal three times wider than it looks and never stack anything.
public enum NewPaneSplit {
    /// true → side by side (`split-window -h`), false → stacked (`-v`).
    public static func sideBySide(cols: Int, rows: Int) -> Bool {
        cols >= rows * 2
    }
}

@MainActor
public extension TerminalViewModel {
    /// See `SessionChrome`.
    var isSinglePaneSession: Bool {
        SessionChrome.isSinglePane(paneCount: sessionPanes.count, windowCount: windows.count)
    }

    /// ⌘N: one more of whatever this session is made of. Parallel splits the
    /// active pane along its longer side; Focus opens a window seeded from the
    /// current pane — the same thing ⌘T does there.
    func newPaneOrWindow() {
        guard usingTmux else { return }
        if sessionMode == .list {
            Task { await newListWindow(.duplicateCurrent) }
            return
        }
        let active = paneViewModels.first { $0.paneID == activePaneID }?.pane
            ?? paneViewModels.first?.pane
        let horizontal = active.map { NewPaneSplit.sideBySide(cols: $0.width, rows: $0.height) } ?? true
        splitPane(horizontal: horizontal)
    }

    /// Point this control client at `name` — creating it first if the server
    /// doesn't have it — and report whether it worked.
    ///
    /// `switch-client` makes tmux emit `%session-changed`, which is where the
    /// view model re-adopts everything that belongs to a session (name,
    /// windows, panes, mode, sizing); the refresh here is the backstop for a
    /// notification that raced something else.
    func switchOrCreateSession(_ name: String) async -> Bool {
        guard usingTmux, !name.isEmpty else { return false }
        guard name != activeTmuxSessionName else { return true }
        if case .failed = await ensureSessionExists(name) { return false }
        let resp = await tmuxService.send(.switchClient(session: name))
        guard !resp.isError else {
            dlog("switch-client \(name) failed: \(resp.output)")
            return false
        }
        await refreshWindows()
        await refreshPanes()
        return true
    }
}
