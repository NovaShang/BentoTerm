import SwiftUI
import BentoTmuxKit
import Combine
import BentoVoiceKit
import BentoAgentKit
import BentoSessionKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

// MARK: - Layout & page sizing

extension PaneContainerVC {
    func layoutPanes() {
        // No draggable dividers unless we lay out cell-exact tiles below.
        dividerOverlay.dividers = []
        if let single = singlePaneVC {
            let page = pageSizeForFocus(cols: nil)
            setContentFrame(page)
            single.tiled = false
            single.fixedTerminalCellSize = nil
            // Focus immersion: the pane fills the screen, so the title strip
            // (icon + label) is pure chrome over the user's terminal — drop it
            // entirely (zero height), and the surface grows into its space
            // (tmux gets one or two extra rows — that's the point).
            single.titleBar.isHidden = true
            single.titleBarHeight = 0
            single.surfaceInsetX = 0
            single.view.frame = CGRect(origin: .zero, size: page)
            return
        }
        guard let viewModel, !paneControllers.isEmpty else { return }

        if isFocusLayout, let focusID = effectiveFocusID {
            layoutFocus(focusID)
        } else {
            layoutTiles(viewModel.paneViewModels)
        }
        syncBackgroundToActivePane()
    }

    /// Single pane fills the page; the rest are hidden. In Tracking the page is
    /// the viewport (device-fit, drives tmux); in Pinned the page is the pane's
    /// natural cell size (may exceed the viewport → two-finger pan).
    private func layoutFocus(_ focusID: TmuxPaneID) {
        let pane = viewModel?.paneViewModels.first(where: { $0.paneID == focusID })?.pane
        let page = pageSizeForFocus(cols: pane.map { ($0.width, $0.height) })
        setContentFrame(page)
        for (id, vc) in paneControllers {
            let isFocus = (id == focusID)
            vc.view.isHidden = !isFocus
            if isFocus {
                vc.tiled = false
                vc.fixedTerminalCellSize = nil
                // Same immersion as the single-pane case: no title strip in
                // focus — zero height, and the surface grows into the space.
                vc.titleBar.isHidden = true
                vc.titleBarHeight = 0
                vc.surfaceInsetX = 0
                vc.view.frame = CGRect(origin: .zero, size: page)
                vc.titleBar.isActivePane = true
                if let pvm = viewModel?.paneViewModels.first(where: { $0.paneID == focusID }) {
                    vc.updatePaneState(pvm.paneState, doneUnseen: pvm.agentFinishedUnseen,
                                       active: true)
                }
            }
        }
    }

    /// The per-pane assignments shared by layoutTiles' bootstrap and cell-exact
    /// branches; the branch-specific geometry comes in as parameters.
    private func applyTileAssignments(_ vc: TerminalContainerVC, pvm: PaneViewModel,
                                      activeID: TmuxPaneID?, titleBarHeight: CGFloat,
                                      surfaceInsetX: CGFloat, fixedCellSize: CGSize?,
                                      frame: CGRect) {
        vc.view.isHidden = false
        vc.tiled = true
        // Tiled layout always restores the strip the focus layout hid.
        vc.titleBar.isHidden = false
        vc.titleBarHeight = titleBarHeight
        vc.surfaceInsetX = surfaceInsetX
        vc.fixedTerminalCellSize = fixedCellSize
        vc.view.frame = frame
        vc.updatePaneState(pvm.paneState, doneUnseen: pvm.agentFinishedUnseen,
                           active: pvm.paneID == activeID)
    }

    /// Tile all panes by tmux cell geometry inside the content view. In Tracking
    /// the page == viewport (proportional fit, container pushes one client size);
    /// in Pinned the page is the window's natural cell size (pannable, no push).
    private func layoutTiles(_ panes: [PaneViewModel]) {
        let (totalCols, totalRows) = PaneTiling.gridSize(panes: panes.map(\.pane))
        let activeID = viewModel?.activePaneID

        guard let ppc = pointsPerCell else {
            // Cell size not learned yet: proportional bootstrap so the surfaces
            // lay out and report their metrics (which teaches the sizer the cell size). The next
            // layout pass re-runs cell-exact once a surface has reported.
            let page = pageRect.size
            setContentFrame(page)
            let tiles = PaneTiling.proportionalTiles(
                panes: panes.map(\.pane), page: page,
                titleBarHeight: TerminalContainerVC.defaultTitleBarHeight)
            for tile in tiles {
                guard let vc = paneControllers[tile.id],
                      let pvm = panes.first(where: { $0.paneID == tile.id }) else { continue }
                applyTileAssignments(vc, pvm: pvm, activeID: activeID,
                                     titleBarHeight: tile.titleBarHeight,
                                     surfaceInsetX: tile.surfaceInsetX,
                                     fixedCellSize: nil,
                                     frame: tile.frame)
            }
            return
        }

        // Cell-exact: map tmux cell geometry 1:1 to points, exactly as the macOS
        // host does. Each pane = a title bar (one cell tall, occupying tmux's
        // divider row) + a surface of exactly its cols×rows. The title bar height
        // equals one cell so stacked panes reuse divider rows and irregular
        // splits stay aligned (only the top bar adds height). Side-by-side panes
        // share the divider column: the container grows half a cell into it on
        // each side so neighbours meet, while surfaceInsetX keeps the surface at
        // its true cell size and position (ghostty's grid still == tmux's).
        let page = pageSizeForTiles(totalCols: totalCols, totalRows: totalRows)
        setContentFrame(page)

        for tile in PaneTiling.cellExactTiles(panes: panes.map(\.pane), pointsPerCell: ppc) {
            guard let vc = paneControllers[tile.id],
                  let pvm = panes.first(where: { $0.paneID == tile.id }) else { continue }
            let p = pvm.pane
            // The surface is one cell larger than the pane so ghostty's grid >=
            // tmux (point rounding never drops a column/row); overflow is clipped.
            applyTileAssignments(vc, pvm: pvm, activeID: activeID,
                                 titleBarHeight: tile.titleBarHeight,
                                 surfaceInsetX: tile.surfaceInsetX,
                                 fixedCellSize: CGSize(width: CGFloat(p.width + 1) * ppc.width,
                                                       height: CGFloat(p.height + 1) * ppc.height),
                                 frame: tile.frame)
        }
        recomputeTilesClientSize()
        // Refresh the drag-to-resize divider hot zones for the new geometry.
        dividerOverlay.frame = CGRect(origin: .zero, size: page)
        dividerOverlay.pointsPerCell = CGPoint(x: ppc.width, y: ppc.height)
        dividerOverlay.dividers = computeTileDividers(page: page, ppc: ppc)
        contentView.bringSubviewToFront(dividerOverlay)
    }

    /// Page size for a focused/single pane. We drive the size → viewport;
    /// someone else does → the pane's natural cell size (+ title bar), which may
    /// exceed the viewport.
    private func pageSizeForFocus(cols: (Int, Int)?) -> CGSize {
        let rect = pageRect
        guard windowSizeIsForeign, let ppc = pointsPerCell, let (c, r) = cols else {
            return rect.size
        }
        // No title strip in focus anymore — the page is exactly the grid.
        return CGSize(width: CGFloat(c) * ppc.width,
                      height: CGFloat(r) * ppc.height)
    }

    /// Page size for Tiles. We drive the size → viewport; someone else does →
    /// the window's natural size.
    /// Cell-exact: width maps cells 1:1; height is the grid plus exactly ONE
    /// title bar (one cell) — stacked panes' title bars reuse tmux's divider
    /// rows, so only the top bar adds height (see `layoutTiles`).
    private func pageSizeForTiles(totalCols: CGFloat, totalRows: CGFloat) -> CGSize {
        let rect = pageRect
        guard windowSizeIsForeign, let ppc = pointsPerCell else { return rect.size }
        return PaneTiling.pageSize(gridCols: totalCols, gridRows: totalRows, pointsPerCell: ppc)
    }

    /// Place the content view at the clamped pan offset. Page ≤ viewport → pinned
    /// top-left, no scroll (PRD §2.2); page > viewport → pannable.
    private func setContentFrame(_ page: CGSize) {
        let rect = pageRect
        // Bottom chrome (keyboard + compose bar) shrinks the usable viewport
        // height (not the page). Clamp against that reduced height so the
        // content can pan up far enough to lift the active pane's input above
        // it; with nothing covering, bottomOcclusion is 0 and this is the plain
        // page-rect clamp.
        let usableH = rect.height - bottomOcclusion
        let minX = min(0, rect.width - page.width)
        let minY = min(0, usableH - page.height)
        let clampedX = max(minX, min(0, contentOffset.x))
        let clampedY = max(minY, min(0, contentOffset.y))
        contentOffset = CGPoint(x: clampedX, y: clampedY)
        contentView.frame = CGRect(x: rect.minX + clampedX, y: rect.minY + clampedY,
                                   width: page.width, height: page.height)
        dlog("[contentFrame] page=\(page) offset=\(contentOffset) frame=\(contentView.frame) occ=\(bottomOcclusion)")
    }

    func applyContentFrame() {
        // Re-clamp using the current content size after a pan.
        setContentFrame(contentView.bounds.size)
        positionFloatingToolbar()
        positionFindBar()
    }

    /// One tmux client size for the whole viewport (Tiles). Cell-exact tiling
    /// reserves exactly ONE cell of height for the top title bar (stacked panes
    /// reuse divider rows), so the usable terminal grid is the viewport minus a
    /// single cell row. Always measured, even when the policy forbids declaring
    /// it — see `pushClientSize`.
    private func recomputeTilesClientSize() {
        guard let fit = deviceFitGrid(reserveTitleRow: true) else { return }
        pushClientSize(cols: fit.cols, rows: fit.rows)
    }
}

// MARK: - Divider hit-testing

extension PaneContainerVC {
    /// The pane containers currently on screen — the input to divider and drop
    /// hit-testing (both shared with the macOS host).
    var paneFrames: [PaneFrame] {
        paneControllers.compactMap { id, vc in
            vc.view.isHidden ? nil : PaneFrame(id: id, frame: vc.view.frame)
        }
    }

    /// Divider hot zones for the current tiling — the same computation the macOS
    /// host runs, with touch-sized grab areas instead of pointer-sized ones.
    private func computeTileDividers(page: CGSize, ppc: CGSize) -> [PaneDivider] {
        PaneTiling.dividers(frames: paneFrames, bounds: page,
                            pointsPerCell: CGPoint(x: ppc.width, y: ppc.height),
                            hotZone: TileDividerOverlay.hotZone)
    }
}
