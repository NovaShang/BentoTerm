import BentoTmuxKit
import BentoGhosttyKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoSessionKit
import BentoUISharedKit

extension GhosttyTiledPaneHost {
    // MARK: - Layout

    public override func layout() {
        super.layout()
        recomputeClientSize()
        layoutCells()
    }

    private var currentScale: CGFloat { window?.backingScaleFactor ?? 2.0 }

    // The cached cell size is in device pixels, which change when the window
    // moves between displays of different backing scale (2× ↔ 1×). Drop the
    // cache so the next surface report re-learns it at the new scale and the
    // tmux client grid stays correct.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sizer.reset()
        layoutCells()
    }

    /// One visible pane (single or zoomed) fills the window, so its surface's
    /// reported grid is authoritative and drives tmux directly — see
    /// `pushAuthoritativeClientSize`. Only the multi-pane TILED case needs the
    /// window-bounds estimate below.
    var isSingleOrZoom: Bool {
        viewModel.zoomedPaneID != nil || viewModel.paneViewModels.count <= 1
    }

    /// Whether `paneID` is the currently visible pane (zoomed one, or the sole pane).
    func isVisiblePane(_ paneID: TmuxPaneID) -> Bool {
        if let z = viewModel.zoomedPaneID { return z == paneID }
        return true   // single pane
    }

    /// Push ghostty's authoritative reported grid as the tmux client size
    /// (deduped + debounced). Exact match → no wrap/redraw artifacts.
    func pushAuthoritativeClientSize(cols: Int, rows: Int) {
        // Held until the live drag ends (flushed in viewDidEndLiveResize);
        // ghostty still renders at the live size.
        sizer.request(.init(cols: cols, rows: rows),
                      holding: window?.inLiveResize == true) { [weak self] in
            guard let self else { return }
            // One-shot after the first (attach) resize: the pty/tmux started at
            // a default size, drew the prompt, then we resized to the window's
            // real grid — leaving a stale pre-resize prompt + blank gap. A single
            // Ctrl-L makes zsh repaint the prompt cleanly at the top (scrollback
            // preserved; in a TUI it's a harmless redraw).
            if !self.didInitialScreenClean {
                self.didInitialScreenClean = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                    self?.viewModel.sendData(Data([0x0C]))
                }
            }
        }
    }

    /// The window's grid in tmux client cols×rows for the multi-pane tiled
    /// layout — the shared `PaneTiling.clientGrid` (the iOS container asks the
    /// same question of its viewport).
    private func windowGrid(cellPx: CGSize) -> (cols: Int, rows: Int) {
        PaneTiling.clientGrid(viewport: bounds.size, cellPixels: cellPx, scale: currentScale)
    }

    /// Convert the window size → tmux client cols×rows and push it (debounced).
    /// Native layout maps each tmux cell 1:1 to a character cell, with ONE title
    /// bar of extra height for the top pane (the rest reuse divider rows), so the
    /// grid is `⌊width / cellW⌋ × ⌊(height − titleBar) / cellH⌋`. Only the
    /// multi-pane tiled case uses this; single/zoomed panes drive tmux from the
    /// authoritative surface grid instead.
    func recomputeClientSize() {
        guard !isSingleOrZoom else { return }
        guard let cellPx = sizer.cellPx, bounds.width > 0, bounds.height > 0 else { return }
        let (cols, rows) = windowGrid(cellPx: cellPx)
        sizer.request(.init(cols: cols, rows: rows), holding: window?.inLiveResize == true)
    }

    /// Apply the resize deferred during a live window drag — one SIGWINCH on
    /// mouse-up instead of reflowing the TUI throughout the drag.
    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        layoutCells()
        sizer.flush()
    }

    /// The bounding box of all panes in tmux cell units (used as the tiling grid).
    var paneGridSize: (cols: CGFloat, rows: CGFloat) {
        PaneTiling.gridSize(panes: viewModel.paneViewModels.map(\.pane))
    }

    /// Points per tmux cell (font cell size ÷ backing scale), or nil until the
    /// cell size has been learned from a surface.
    private var pointsPerCell: CGSize? { sizer.pointsPerCell(scale: currentScale) }

    /// Tile panes proportionally to fill the host, using the bounding box of all
    /// panes as the cell grid. When a pane is zoomed, it alone fills the host and
    /// the rest are hidden (iTerm2 zoom).
    ///
    /// The *container* is positioned proportionally (so panes always fill the
    /// window), but each terminal *surface* is sized to its EXACT tmux cell
    /// dimensions (cols×rows × cell px). That guarantees ghostty's own grid
    /// equals the grid tmux assigned the pane — otherwise a TUI sized by tmux to
    /// N columns would be rendered into a surface ghostty thinks is N±1 wide, and
    /// the layout tears. Sizing from tmux geometry (not window proportions) also
    /// removes the resize-timing races: the surface only changes when tmux's pane
    /// size actually changes.
    func layoutCells() {
        let panes = viewModel.paneViewModels
        guard !panes.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        // One lookup table instead of a linear scan per cell (×2 loops below).
        let vmByID = Dictionary(panes.map { ($0.paneID, $0) }, uniquingKeysWith: { a, _ in a })
        let ppc = pointsPerCell
        // Title bar = one character cell tall, so it sits exactly in tmux's divider
        // row between stacked panes (t + g_y = h_c, g_y = 0). The top pane's bar is
        // the only extra height; all the others reuse divider rows.
        // Focus mode: the sidebar already carries the name + state — a title
        // bar on the single pane would be the same chrome twice, so the
        // terminal owns the full area. Likewise a session that is ONE pane in
        // total (`SessionChrome`): there is nothing to tell apart, so it looks
        // like a plain terminal; its status stays on the pane's wash.
        // Either way the one visible pane drives tmux from its own surface grid
        // (`isSingleOrZoom`), so dropping the row reaches tmux as a resize.
        let showsTitles = viewModel.sessionMode != .list && !viewModel.isSinglePaneSession
        let titleBar = showsTitles ? (ppc?.height ?? Self.fallbackTitleBarHeight) : 0

        // Push each pane's tmux mouse-reporting mode + the title-bar height onto its
        // surface/cell. (tmux -CC never streams the mouse-enable, so the flag is the
        // only signal that a program wants the mouse.)
        for (id, cell) in cells {
            cell.container.titleBarHeight = titleBar
            if let pv = vmByID[id] {
                cell.surface.mouseReporting = .init(any: pv.pane.mouseAny, sgr: pv.pane.mouseSGR)
                cell.surface.tmuxInMode = pv.pane.inMode
                refreshModeBadge(cell)
            }
        }

        // Zoomed / single pane: one surface fills the window (title bar + surface),
        // and it drives tmux from its own authoritative reported grid.
        if let zoomed = viewModel.zoomedPaneID, cells[zoomed] != nil {
            for (id, cell) in cells {
                let isZoom = (id == zoomed)
                cell.container.isHidden = !isZoom
                if isZoom {
                    cell.container.surfaceInsetX = 0
                    cell.container.frame = bounds
                }
            }
            dividerOverlay.refresh()
            return
        }

        // Cell-exact tiling (shared with the iOS host — see PaneTiling). A lone
        // pane, or one laid out before any surface has reported its cell size,
        // just fills the window instead.
        let tiles: [TmuxPaneID: PaneTile] = (panes.count == 1 || ppc == nil)
            ? [:]
            : Dictionary(PaneTiling.cellExactTiles(panes: panes.map(\.pane),
                                                   pointsPerCell: ppc!,
                                                   titleBarHeight: titleBar).map { ($0.id, $0) },
                         uniquingKeysWith: { a, _ in a })

        for (id, cell) in cells {
            guard let paneVM = vmByID[id] else { continue }
            cell.container.isHidden = false
            cell.container.title = PaneChrome.title(for: paneVM.pane)

            if let tile = tiles[id] {
                cell.container.surfaceInsetX = tile.surfaceInsetX
                cell.container.frame = tile.frame
            } else {
                cell.container.surfaceInsetX = 0
                cell.container.frame = bounds
            }
        }
        dividerOverlay.refresh()
    }

    func updateActiveBorders() {
        let active = viewModel.activePaneID
        let suppress = isSingleOrZoom   // one visible pane → nothing to disambiguate
        for (id, cell) in cells {
            cell.container.focusSuppressed = suppress
            cell.container.isActivePane = (id == active)
            // A find bar belongs to its pane: moving to another pane ends it,
            // rather than leaving a stale search highlighted where you can't see
            // the field.
            if id != active, cell.surface.isSearchOpen {
                cell.surface.endSearchUI()
            }
            // Only steal first responder when it actually needs to change. An
            // unconditional makeFirstResponder re-activates the surface's
            // NSTextInputContext every call, which churns the macOS text-input
            // stack (utTryToSetupInputMethodMenu + per-activation IMK/TSM XPC
            // connections). Profiling showed that churn stalling keystrokes and
            // the XPC connections accumulating over a session ("slower over time").
            //
            // `searchFieldHasFocus` is the other exception: while the find bar
            // holds the keyboard, this method still runs (layout, pane polls) and
            // would otherwise yank the caret out of the field mid-word.
            if id == active, window?.firstResponder !== cell.surface,
               !cell.surface.searchFieldHasFocus {
                window?.makeFirstResponder(cell.surface)
            }
        }
    }

    // MARK: - Pane geometry queries (used by the divider overlay)

    /// All current cell frames keyed by pane id.
    var cellFrames: [PaneFrame] {
        cells.compactMap { id, cell in
            cell.container.isHidden ? nil : PaneFrame(id: id, frame: cell.container.frame)
        }
    }

    /// Resize the boundary owned by `paneID` along an axis by a signed cell delta.
    func resizeBoundary(paneID: TmuxPaneID, vertical: Bool, deltaCells: Int) {
        viewModel.resizeBoundary(paneID, vertical: vertical, deltaCells: deltaCells)
    }

    /// Recompute a pane's trailing mode glyph. copy-mode wins over suppressed
    /// mouse reporting: it changes what the KEYBOARD does, which is the more
    /// surprising of the two.
    func refreshModeBadge(_ cell: PaneCell) {
        if cell.surface.tmuxInMode {
            cell.container.modeBadge = .copyMode
        } else if cell.surface.mouseReportingSuppressed {
            cell.container.modeBadge = .mouseReportingOff
        } else {
            cell.container.modeBadge = .none
        }
    }
}
#endif
