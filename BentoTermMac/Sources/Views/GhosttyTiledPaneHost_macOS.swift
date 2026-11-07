import BentoTmuxKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoVoiceKit   // VoiceCompassView.Metrics / .Placement for the overlay's anchor
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftUI
import BentoSessionKit
import BentoUISharedKit

/// iTerm2-style TILED multi-pane host for macOS. Every tmux pane is shown at
/// once, laid out by its tmux cell geometry (x/y/width/height), each in its own
/// GhosttyTerminalSurface fed by its PaneViewModel. The window's pixel size is
/// converted (via the font cell size) to a tmux client cols×rows; tmux owns the
/// split layout and we mirror it.
///
/// iTerm2-parity features:
///   - per-pane title bar (command + title), accent-highlighted when active
///   - click a pane to focus it; active pane gets an accent border
///   - zoom (⌘⇧Return): the zoomed pane fills the window, others hidden
///   - drag the divider between adjacent panes to resize (sends `resize-pane`)
///   - drag a pane's title bar onto another pane to swap with it or dock
///     beside it (VS Code-style drop zones)
///   - menu / keyboard split, close, and next/prev-pane navigation
///
/// This file holds the stored state, init/teardown and the pane lifecycle.
/// The rest lives in extensions by concern: `+Layout` (cell-exact tiling, the
/// tmux client size), `+Wiring` (per-pane callbacks), `+PaneDrag`, `+Voice`,
/// `+PaneMenu`, `+Actions` (responder-chain actions + `BentoPaneAction`). The
/// pane chrome is `PaneCellView` / `PaneTitleBar`; resize is `DividerOverlay`.
@MainActor
public final class GhosttyTiledPaneHost: NSView, NSMenuDelegate {
    let viewModel: TerminalViewModel
    private var theme: TerminalTheme
    private(set) var cells: [TmuxPaneID: PaneCell] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// Per-pane Combine subscriptions, keyed by pane so they are cancelled when
    /// the pane's cell is torn down (storing them in the host-wide `cancellables`
    /// let them accumulate over a session of pane churn).
    var cellBags: [TmuxPaneID: Set<AnyCancellable>] = [:]
    /// Block-observer tokens for the theme/font notifications. `removeObserver(self)`
    /// does NOT remove block observers, so the tokens must be stored and removed
    /// explicitly (mirrors the surface's `renderObservers`).
    nonisolated(unsafe) private var themeObservers: [NSObjectProtocol] = []
    /// Cell size, last pushed client grid, debounce, and the grid held during
    /// a live window drag (sent once on mouse-up, so the TUI gets one SIGWINCH
    /// rather than a burst).
    private(set) lazy var sizer = TiledClientSizer { [weak self] grid in
        self?.viewModel.resizeTmuxClient(cols: grid.cols, rows: grid.rows)
    }
    let dividerOverlay = DividerOverlay()

    /// Hold-to-talk voice (right-click-and-hold a pane). One controller per
    /// window; the overlay is shown on top of the panes while recording.
    let voiceController = MacVoiceController()
    var voiceOverlay: MacVoiceOverlay?
    /// Centered, interactive overlay card for the right-swipe "AI correct" preview
    /// (vs `voiceOverlay`, which is the passive recording compass).
    var voicePreview: NSView?

    /// The live "Move to Session" submenu, populated lazily via `menuNeedsUpdate`
    /// so the session list reflects the refresh kicked when the menu opened —
    /// otherwise the first open captures a still-cold cache and shows empty.
    weak var moveToSessionMenu: NSMenu?

    /// Which machine these panes' `localhost` means. Set by the owning tab;
    /// local until told otherwise, which is what a local tmux server is.
    var linkHost: LinkHost = .local(label: "This Mac")

    /// Ports already offered, so a restart does not re-offer the same server.
    var devServerOffers = DevServerOffers()

    // Drag-to-dock state (see GhosttyTiledPaneHost+PaneDrag).
    var dragSourceID: TmuxPaneID?
    /// The translucent landing preview; created on the first hover of a drag,
    /// torn down when the drag ends (so theme/accent changes never go stale).
    var dropOverlay: PaneDropZoneOverlay?

    var didInitialScreenClean = false

    /// Tear down every pane's ghostty surface (display link + surface free) on
    /// the main thread before the window/view hierarchy is released — see
    /// GhosttyTerminalSurface.teardown(). Call from windowWillClose.
    public func teardown() {
        cancellables.removeAll()
        cellBags.removeAll()
        themeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        themeObservers.removeAll()
        for (_, cell) in cells { cell.surface.teardown() }
    }

    /// Title-strip height used only before the real cell size is known (the strip
    /// is normally one character cell tall — see layoutCells).
    static let fallbackTitleBarHeight: CGFloat = 20

    public init(viewModel: TerminalViewModel, theme: TerminalTheme) {
        self.viewModel = viewModel
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        // Paint the host in the terminal background color (not black) so the
        // one-cell divider column between side-by-side panes reads as the pane
        // background bleeding through, not an empty gap. Geometry is unchanged.
        layer?.backgroundColor = NSColor(hex: theme.background).cgColor

        dividerOverlay.host = self
        dividerOverlay.autoresizingMask = [.width, .height]
        addSubview(dividerOverlay)

        viewModel.$paneViewModels
            .receive(on: RunLoop.main)
            .sink { [weak self] panes in self?.syncPanes(panes) }
            .store(in: &cancellables)
        // Synchronous re-tile when %layout-change applies new pane geometry, so
        // surfaces resize before the program's repaint output is fed to ghostty.
        viewModel.onGeometryApplied = { [weak self] in self?.layoutCells() }
        viewModel.$activePaneID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateActiveBorders() }
            .store(in: &cancellables)
        // A second pane or window brings the title bars back; closing down to
        // one takes them away. The pane list alone can't say that — Focus has
        // one pane per window — so re-tile when the session's shape changes.
        viewModel.$sessionPanes.map(\.count)
            .combineLatest(viewModel.$windows.map(\.count))
            .map { SessionChrome.isSinglePane(paneCount: $0, windowCount: $1) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.needsLayout = true }
            .store(in: &cancellables)
        viewModel.$zoomedPaneID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.layoutCells()
                self?.updateActiveBorders()   // zoom in/out → refresh focus-border suppression
            }
            .store(in: &cancellables)

        // Voice: route the finished utterance to the active pane, and drive the
        // overlay from the controller's published state. Visibility follows
        // `showOverlay` (not `isRecording`) so an error leaves the compass up
        // with its message for the shared ~1.2s — same as iOS. `startVoice`
        // positions + shows the overlay before `begin`, so the true branch here
        // is a no-op for the normal path.
        voiceController.onResult = { [weak self] result in
            self?.viewModel.handleVoiceResult(result)
        }
        voiceController.$showOverlay
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                if show { self?.voiceOverlay?.isHidden = false }
                else { self?.hideVoiceOverlay() }
            }
            .store(in: &cancellables)
        // transcript / direction / fingerOffset are NOT mirrored: the overlay's
        // root view observes the controller directly, so the SwiftUI animations
        // survive (mirroring meant rebuilding the root view, which killed them).
        voiceController.$showPreview
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                if show { self?.presentVoicePreview() } else { self?.dismissVoicePreview() }
            }
            .store(in: &cancellables)

        // Re-apply theme/font to live surfaces when the user changes them in
        // Settings. (Colors are app-wide via GhosttyRuntime's config; this picks
        // up the font size — applyTheme recreates the surface on a size change —
        // and the surrounding background.)
        for name in [Notification.Name.terminalThemeChanged, .terminalFontChanged] {
            themeObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reapplyTheme() }
            })
        }
    }

    deinit {
        // Backstop for a host that never got teardown(): block observers are only
        // removed by token (removeObserver(self) doesn't touch them).
        themeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        NotificationCenter.default.removeObserver(self)
    }

    /// Re-read the shared ThemeStore and push the theme (font size + background)
    /// to every live surface.
    private func reapplyTheme() {
        theme = ThemeStore.shared.makeTerminalTheme()
        layer?.backgroundColor = NSColor(hex: theme.background).cgColor
        // A font change (size OR family) changes the pixel size of one cell, so
        // the cached cell metrics and last-pushed tmux client size are now stale.
        // Drop them: the next surface size report re-learns the cell size and
        // re-pushes the client size, then we re-tile against the new grid.
        // Without this the surfaces stay sized to the old font's cells and the
        // layout tears.
        sizer.reset()
        for (_, cell) in cells {
            cell.surface.applyTheme(theme)
            // CGColor chrome (border + title-bar band/ink) is a static snapshot —
            // re-derive it so a light/dark flip repaints the panes, not just the
            // terminal body.
            cell.container.recolorChrome()
        }
        dividerOverlay.needsDisplay = true
        layoutCells()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// tmux pane y=0 is the TOP row, so flip to match.
    public override var isFlipped: Bool { true }

    // MARK: - Pane lifecycle

    private func syncPanes(_ panes: [PaneViewModel]) {
        let newIDs = Set(panes.map(\.paneID))
        let torn = Set(cells.keys).subtracting(newIDs)
        let added = newIDs.subtracting(cells.keys)
        if !torn.isEmpty || !added.isEmpty {
            DIAG("[DUP] syncPanes set=[\(panes.map { "\($0.paneID)" }.joined(separator: ","))]\(torn.isEmpty ? "" : " TEARDOWN=[\(torn.map { "\($0)" }.joined(separator: ","))]")\(added.isEmpty ? "" : " ADD=[\(added.map { "\($0)" }.joined(separator: ","))]")")
        }
        for (id, cell) in cells where !newIDs.contains(id) {
            // Tear down the surface explicitly — free the libghostty surface, its
            // renderer/io threads, render queue and GPU resources NOW. Without
            // this a closed pane leaks all of that (deinit alone is unreliable /
            // late), so a session of pane churn accumulates dozens of surfaces.
            cell.surface.teardown()
            cell.container.removeFromSuperview()
            cells[id] = nil
            // Cancel the cell's per-pane sinks with it (pure resource cleanup —
            // they all capture weak).
            cellBags.removeValue(forKey: id)
        }
        for paneVM in panes where cells[paneVM.paneID] == nil {
            cells[paneVM.paneID] = makeCell(for: paneVM)
        }
        layoutCells()
        updateActiveBorders()
    }

    private func makeCell(for paneVM: PaneViewModel) -> PaneCell {
        let surface = GhosttyTerminalSurface(theme: theme)
        let paneID = paneVM.paneID
        surface.debugLabel = paneID.description
        DIAG("makeCell \(paneID)")

        wireSurfaceCallbacks(surface, paneVM: paneVM, paneID: paneID)

        let container = PaneCellView()
        wireContainerActions(container, paneID: paneID)
        container.embed(surface)
        // Insert BELOW the divider overlay so dividers stay hit-testable on top.
        addSubview(container, positioned: .below, relativeTo: dividerOverlay)

        wireStateBindings(paneVM: paneVM, container: container, paneID: paneID)

        return PaneCell(container: container, surface: surface)
    }
}

struct PaneCell {
    let container: PaneCellView
    let surface: GhosttyTerminalSurface
}
#endif
