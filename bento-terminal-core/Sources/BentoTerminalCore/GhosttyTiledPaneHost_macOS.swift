#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftUI
import SwiftTmux

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
@MainActor
public final class GhosttyTiledPaneHost: NSView, NSMenuDelegate {
    let viewModel: TerminalViewModel
    private var theme: TerminalTheme
    private var cells: [TmuxPaneID: PaneCell] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// Per-pane Combine subscriptions, keyed by pane so they are cancelled when
    /// the pane's cell is torn down (storing them in the host-wide `cancellables`
    /// let them accumulate over a session of pane churn).
    private var cellBags: [TmuxPaneID: Set<AnyCancellable>] = [:]
    /// Block-observer tokens for the theme/font notifications. `removeObserver(self)`
    /// does NOT remove block observers, so the tokens must be stored and removed
    /// explicitly (mirrors the surface's `renderObservers`).
    private var themeObservers: [NSObjectProtocol] = []
    /// Cell size in pixels (constant for the font); learned from the first surface.
    private var cellPx: CGSize?
    private var resizeDebounce: DispatchWorkItem?
    private var lastClient: (cols: Int, rows: Int)?
    /// The tmux client size computed during a live window-resize drag, applied
    /// once the drag ends (so the TUI gets one SIGWINCH on mouse-up, not a burst
    /// throughout the drag). nil when not mid-drag.
    private var pendingClient: (cols: Int, rows: Int)?
    private let dividerOverlay = DividerOverlay()

    /// Hold-to-talk voice (right-click-and-hold a pane). One controller per
    /// window; the overlay is shown on top of the panes while recording.
    private let voiceController = MacVoiceController()
    private var voiceOverlay: MacVoiceOverlay?
    /// Centered, interactive overlay card for the right-swipe "AI correct" preview
    /// (vs `voiceOverlay`, which is the passive recording compass).
    private var voicePreview: NSView?

    /// The live "Move to Session" submenu, populated lazily via `menuNeedsUpdate`
    /// so the session list reflects the refresh kicked when the menu opened —
    /// otherwise the first open captures a still-cold cache and shows empty.
    private weak var moveToSessionMenu: NSMenu?

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

    /// NSColor from a 0xRRGGBB terminal color.
    static func bgColor(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    public init(viewModel: TerminalViewModel, theme: TerminalTheme) {
        self.viewModel = viewModel
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        // Paint the host in the terminal background color (not black) so the
        // one-cell divider column between side-by-side panes reads as the pane
        // background bleeding through, not an empty gap. Geometry is unchanged.
        layer?.backgroundColor = Self.bgColor(theme.background).cgColor

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
        viewModel.$zoomedPaneID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.layoutCells()
                self?.updateActiveBorders()   // zoom in/out → refresh focus-border suppression
            }
            .store(in: &cancellables)

        // Voice: route the finished utterance to the active pane, and drive the
        // overlay from the controller's published state.
        voiceController.onResult = { [weak self] result in
            self?.viewModel.handleVoiceResult(result)
        }
        voiceController.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] recording in
                if recording { self?.voiceOverlay?.isHidden = false }
                else { self?.hideVoiceOverlay() }
            }
            .store(in: &cancellables)
        voiceController.$transcript
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.voiceOverlay?.transcript = t }
            .store(in: &cancellables)
        voiceController.$activeDirection
            .receive(on: RunLoop.main)
            .sink { [weak self] d in self?.voiceOverlay?.direction = d }
            .store(in: &cancellables)
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
        layer?.backgroundColor = Self.bgColor(theme.background).cgColor
        // A font change (size OR family) changes the pixel size of one cell, so
        // the cached cell metrics and last-pushed tmux client size are now stale.
        // Drop them: the next surface size report re-learns cellPx (the `cellPx
        // == nil` branch in onSizeChanged) and re-pushes the client size, then we
        // re-tile against the new grid. Without this the surfaces stay sized to
        // the old font's cells and the layout tears.
        cellPx = nil
        lastClient = nil
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
        wireContainerActions(container, paneVM: paneVM, paneID: paneID)
        container.embed(surface)
        // Insert BELOW the divider overlay so dividers stay hit-testable on top.
        addSubview(container, positioned: .below, relativeTo: dividerOverlay)

        wireStateBindings(paneVM: paneVM, container: container, paneID: paneID)

        return PaneCell(container: container, surface: surface)
    }

    /// Surface ↔ view-model wiring: output/input, selection, voice, split, size,
    /// and the scroll-bookmark hooks. Extracted from `makeCell`.
    private func wireSurfaceCallbacks(_ surface: GhosttyTerminalSurface,
                                      paneVM: PaneViewModel,
                                      paneID: TmuxPaneID) {
        paneVM.onDataReceived = { [weak surface] data in
            // `PaneViewModel.feedData` is @MainActor and invokes this synchronously,
            // so we're already on main — feed inline instead of bouncing through
            // another runloop turn. That extra `DispatchQueue.main.async` added a
            // whole frame of latency to every echoed chunk (incl. IME "上屏"); feed
            // itself just hands off to the surface's ioQueue, so it's cheap here.
            MainActor.assumeIsolated { surface?.feed(data) }
        }
        surface.onInput = { [weak paneVM] data in paneVM?.sendInput(data) }
        surface.onSelect = { [weak self] in self?.viewModel.selectPane(paneID) }
        surface.onVoicePrewarm = { [weak self] in self?.voiceController.prewarm() }
        surface.onVoiceStart = { [weak self] screenPt in self?.startVoice(forPane: paneID, atScreen: screenPt) }
        surface.onVoiceDrag = { [weak self] screenPt in self?.voiceController.update(toScreen: screenPt) }
        surface.onVoiceEnd = { [weak self] in self?.voiceController.end() }
        surface.onSplit = { [weak self] horizontal in
            guard let self, self.splitsAllowed else { return }
            self.viewModel.selectPane(paneID)
            self.viewModel.splitPane(horizontal: horizontal)
        }
        surface.onSizeChanged = { [weak self] size in
            guard let self else { return }
            // Track the cell pixel size whenever it CHANGES, not just when nil.
            // cellPx is in device pixels, so it changes when the window moves to a
            // display with a different backing scale (e.g. unplug an external
            // monitor: 2× ↔ 1×) or when the font changes. Learning it only-once
            // (`== nil`) raced the backing-change handler that nils it: if the
            // surface re-reported before the nil landed, the new cell size was
            // dropped and the grid stayed stuck on the old scale (huge/tiny text)
            // until relaunch.
            if size.cellWidthPx > 0, size.cellHeightPx > 0 {
                let newCell = CGSize(width: size.cellWidthPx, height: size.cellHeightPx)
                if self.cellPx != newCell {
                    self.cellPx = newCell
                    self.recomputeClientSize()
                    self.layoutCells()
                }
            }
            // Single / zoomed pane: this surface fills the window, so ghostty's
            // reported grid IS exactly what's rendered — drive the tmux client
            // size from it (authoritative). Using the host's bounds math instead
            // drifts by ~1 cell vs ghostty's internal padding, which made the
            // shell wrap/redraw at the wrong width (double-echoed commands, prompt
            // pinned to the bottom, big vertical gaps).
            if self.isSingleOrZoom, self.isVisiblePane(paneID) {
                self.pushAuthoritativeClientSize(cols: size.columns, rows: size.rows)
            }
        }

        // Scroll-bookmark nav: push scrollback geometry into the VM; let the VM
        // drive history scrolling.
        surface.onScrollbar = { [weak paneVM] total, offset, len in
            paneVM?.noteScrollbar(total: total, offset: offset, len: len)
        }
        paneVM.onReviewScroll = { [weak surface] rows in surface?.scrollRows(rows) }
        paneVM.onScrollToLive = { [weak surface] in surface?.scrollToLive() }
        paneVM.onReadScrollback = { [weak surface] in surface?.readScrollback() }
        // Path preview (⌘hover / ⌘click): macOS panes run against the local
        // machine, so files come straight off disk. cwd = the pane's live tmux
        // path (never stale), falling back to the surface's OSC 7 report.
        surface.pathWrapCols = { [weak paneVM] in paneVM?.pane.width }
        surface.pathPreviewContext = PathPreviewContext(
            source: LocalFileSource(),
            cwd: { [weak paneVM, weak surface] in
                if paneVM == nil {
                    pathPreviewLog.log("cwd: paneVM gone, OSC7=⟨\(surface?.reportedPwd ?? "<nil>", privacy: .public)⟩")
                }
                if let path = await paneVM?.currentWorkingDirectory() { return path }
                return surface?.reportedPwd
            },
            hostLabel: "This Mac",
            isLocal: true,
            // Files come off the LOCAL disk; when this pane is an ssh/mosh
            // session the real files are on another host — refuse honestly
            // rather than list this Mac's files.
            remoteBlock: { [weak paneVM] in
                PathPreviewContext.isRemoteShellCommand(paneVM?.pane.currentCommand)
                    ? "This pane is a remote (SSH) session — its files aren’t browsable here yet."
                    : nil
            })
    }

    /// Container (title bar / chrome) action wiring. Extracted from `makeCell`.
    private func wireContainerActions(_ container: PaneCellView,
                                      paneVM: PaneViewModel,
                                      paneID: TmuxPaneID) {
        container.onClick = { [weak self] in self?.viewModel.selectPane(paneID) }
        container.onZoom = { [weak self] in
            self?.viewModel.selectPane(paneID)
            self?.viewModel.toggleZoom(paneID)
        }
        container.onMenu = { [weak self, weak container] in
            guard let self, let container else { return }
            self.viewModel.selectPane(paneID)
            self.showPaneMenu(for: paneID, from: container.menuButtonAnchor)
        }
        container.onPaneDrag = { [weak self] phase in
            self?.handlePaneDrag(source: paneID, phase: phase)
        }
        // Title-bar chevrons for the scroll-bookmark nav.
        container.onJumpUp = { [weak self, weak paneVM] in
            self?.viewModel.selectPane(paneID); paneVM?.jumpToOlderMark()
        }
        container.onJumpDown = { [weak self, weak paneVM] in
            self?.viewModel.selectPane(paneID); paneVM?.jumpToNewerMark()
        }
    }

    /// Published-state → chrome bindings. The sinks live in `cellBags[paneID]`
    /// so removing the pane's cell cancels them (see `syncPanes`). Extracted
    /// from `makeCell`.
    private func wireStateBindings(paneVM: PaneViewModel,
                                   container: PaneCellView,
                                   paneID: TmuxPaneID) {
        var bag = Set<AnyCancellable>()

        // Drive the title-bar status dot from the pane's detected state (reuses
        // the shared StateDetectionService via PaneViewModel.paneState).
        container.paneState = paneVM.paneState
        paneVM.$paneState
            .receive(on: RunLoop.main)
            .sink { [weak container] state in container?.paneState = state }
            .store(in: &bag)

        // "Done, unseen" badge (agent finished while you weren't looking).
        container.agentFinishedUnseen = paneVM.agentFinishedUnseen
        paneVM.$agentFinishedUnseen
            .receive(on: RunLoop.main)
            .sink { [weak container] v in container?.agentFinishedUnseen = v }
            .store(in: &bag)

        // Show/hide the title-bar chevrons by jump availability.
        container.canJumpUp = paneVM.canJumpUp
        container.canJumpDown = paneVM.canJumpDown
        paneVM.$canJumpUp
            .receive(on: RunLoop.main)
            .sink { [weak container] v in container?.canJumpUp = v }
            .store(in: &bag)
        paneVM.$canJumpDown
            .receive(on: RunLoop.main)
            .sink { [weak container] v in container?.canJumpDown = v }
            .store(in: &bag)

        cellBags[paneID] = bag
    }

    // MARK: - Drag-to-dock (drag a pane's title bar onto another pane)
    //
    // VS Code-style drop zones: hovering a target pane previews the landing —
    // its middle 50%×50% highlights the WHOLE pane (drop = swap the two
    // panes), the four edge bands highlight that HALF (drop = re-split the
    // target along that axis and dock the dragged pane on that side).

    private var dragSourceID: TmuxPaneID?
    /// The translucent landing preview; created on the first hover of a drag,
    /// torn down when the drag ends (so theme/accent changes never go stale).
    private var dropOverlay: PaneDropZoneOverlay?

    /// The pane + drop zone under a window-coordinate point, excluding the
    /// dragged pane. nil = not over any other pane (dropping does nothing).
    private func dropTarget(at windowPoint: NSPoint, excluding source: TmuxPaneID)
        -> (pane: TmuxPaneID, zone: PaneDropZone)? {
        let local = convert(windowPoint, from: nil)
        guard let (id, cell) = cells.first(where: { id, cell in
            id != source && !cell.container.isHidden && cell.container.frame.contains(local)
        }) else { return nil }
        return (id, PaneDropZone.zone(at: local, in: cell.container.frame))
    }

    private func handlePaneDrag(source paneID: TmuxPaneID, phase: PaneDragPhase) {
        switch phase {
        case .moved(let windowPoint):
            if dragSourceID == nil {
                dragSourceID = paneID
                cells[paneID]?.container.alphaValue = 0.6
                NSCursor.closedHand.push()
            }
            updateDropOverlay(dropTarget(at: windowPoint, excluding: paneID))

        case .ended(let windowPoint):
            let drop = dropTarget(at: windowPoint, excluding: paneID)
            dropOverlay?.removeFromSuperview()
            dropOverlay = nil
            cells[paneID]?.container.alphaValue = 1.0
            if dragSourceID != nil {
                dragSourceID = nil
                NSCursor.pop()
            }
            guard let (target, zone) = drop else { return }
            if let dock = zone.dock {
                viewModel.movePane(paneID, splitting: target,
                                   horizontal: dock.horizontal, before: dock.before)
            } else {
                viewModel.swapPanes(paneID, with: target)
            }
        }
    }

    /// Show/move/hide the landing preview. The frame animates between zones
    /// and across panes while visible; appearing from hidden snaps into place
    /// so the preview never slides in from a stale spot.
    private func updateDropOverlay(_ drop: (pane: TmuxPaneID, zone: PaneDropZone)?) {
        guard let drop, let cellFrame = cells[drop.pane]?.container.frame else {
            dropOverlay?.isHidden = true
            return
        }
        let overlay: PaneDropZoneOverlay
        let appearing: Bool
        if let existing = dropOverlay {
            overlay = existing
            appearing = overlay.isHidden
        } else {
            overlay = PaneDropZoneOverlay()
            addSubview(overlay)   // above the cells and the divider overlay
            dropOverlay = overlay
            appearing = true      // a fresh overlay's frame is .zero — snap, don't slide in from the corner
        }
        let target = drop.zone.highlightRect(in: cellFrame)
        overlay.isHidden = false
        overlay.zone = drop.zone
        if appearing {
            overlay.frame = target
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                overlay.animator().frame = target
            }
        }
    }

    // MARK: - Voice (right-click-and-hold)

    /// Right-click-hold passed the threshold on `paneID`: select it, show the
    /// compass overlay at the press point, and start hold-to-talk recording.
    private func startVoice(forPane paneID: TmuxPaneID, atScreen screenPt: NSPoint) {
        viewModel.selectPane(paneID)
        showVoiceOverlay(atScreen: screenPt)
        // Feed the recording pane's on-screen text to the Qwen engine for context
        // biasing (read lazily at session start, only if the engine wants it).
        voiceController.readScreenText = { [weak self] in self?.cells[paneID]?.surface.readScrollback() }
        voiceController.begin(originScreen: screenPt)
    }

    private func showVoiceOverlay(atScreen screenPt: NSPoint) {
        let overlay: MacVoiceOverlay
        if let existing = voiceOverlay {
            overlay = existing
        } else {
            overlay = MacVoiceOverlay(frame: NSRect(origin: .zero, size: MacVoiceOverlay.preferredSize))
            addSubview(overlay)   // on top of the panes + divider overlay
            voiceOverlay = overlay
        }
        overlay.transcript = ""
        overlay.direction = .none

        // Center the overlay at the press point (screen → host coords), clamped.
        let size = MacVoiceOverlay.preferredSize
        var local = NSPoint(x: bounds.midX, y: bounds.midY)
        if let window {
            local = convert(window.convertPoint(fromScreen: screenPt), from: nil)
        }
        let x = min(max(local.x - size.width / 2, 0), max(bounds.width - size.width, 0))
        let y = min(max(local.y - size.height / 2, 0), max(bounds.height - size.height, 0))
        overlay.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        overlay.isHidden = false
        overlay.needsLayout = true
    }

    private func hideVoiceOverlay() {
        voiceOverlay?.isHidden = true
    }

    /// Show the right-swipe preview as a centered, interactive overlay card over a
    /// dimmed backdrop. (A sheet would need a contentViewController; this window
    /// sets `contentView` directly, so we host the card ourselves — same approach
    /// as the recording compass.)
    private func presentVoicePreview() {
        guard voicePreview == nil else { return }
        let backdrop = NSView(frame: bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        let card = NSHostingView(rootView: MacVoicePreviewView(controller: voiceController))
        let size = NSSize(width: 480, height: 260)
        card.frame = NSRect(x: (bounds.width - size.width) / 2,
                            y: (bounds.height - size.height) / 2,
                            width: size.width, height: size.height)
        card.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        backdrop.addSubview(card)
        addSubview(backdrop)
        voicePreview = backdrop
        window?.makeFirstResponder(card)
    }

    private func dismissVoicePreview() {
        voicePreview?.removeFromSuperview()
        voicePreview = nil
    }

    /// Pop up a per-pane context menu (split / zoom / close) anchored to the
    /// title-bar menu button. The pane is already selected, so the existing
    /// responder-chain actions operate on it.
    private func showPaneMenu(for paneID: TmuxPaneID, from anchor: NSView) {
        let menu = NSMenu()
        menu.addItem(item("Command Palette…", #selector(openCommandPalette(_:)), symbol: "command"))
        menu.addItem(.separator())
        let zoomed = (viewModel.zoomedPaneID == paneID)
        // Splits are Tiled mode's creation path — List mode (one pane per
        // window) creates via the sidebar's New Window instead, so no split
        // entries there (the ⌘D actions below no-op the same way).
        if viewModel.sessionMode != .list {
            // Icons make the split direction legible (the words "vertical/horizontal"
            // are ambiguous): side-by-side panes vs stacked panes. The symbol mirrors
            // the resulting layout — splitVertically → two columns, splitHorizontally
            // → two rows (matches splitPane(horizontal:) below).
            menu.addItem(item("Split Right (-h)", BentoPaneAction.splitVertically, symbol: "rectangle.split.2x1"))
            menu.addItem(item("Split Down (-v)", BentoPaneAction.splitHorizontally, symbol: "rectangle.split.1x2"))
            menu.addItem(.separator())
            // Seeded splits — creation parity with List's New Window menu (the
            // same two seeds; both split to the right).
            menu.addItem(item("Split — Duplicate Current", #selector(splitDuplicateCurrent(_:)),
                              symbol: "plus.square.on.square"))
            menu.addItem(item("Split — Path & Command…", #selector(splitWithPathCommand(_:)),
                              symbol: "terminal"))
            menu.addItem(.separator())
            menu.addItem(layoutMenuItem())
            menu.addItem(.separator())
        }
        menu.addItem(item(zoomed ? "Unzoom" : "Zoom", BentoPaneAction.toggleZoom,
                          symbol: zoomed ? "arrow.down.right.and.arrow.up.left"
                                         : "arrow.up.left.and.arrow.down.right"))
        menu.addItem(.separator())
        // tmux swap-pane -U/-D (the `{`/`}` bindings). Panes can also be
        // rearranged by dragging a title bar onto another pane.
        menu.addItem(item("Swap Up", BentoPaneAction.swapPaneUp, symbol: "arrow.up.square"))
        menu.addItem(item("Swap Down", BentoPaneAction.swapPaneDown, symbol: "arrow.down.square"))
        menu.addItem(.separator())
        menu.addItem(makeMoveToSessionItem())
        menu.addItem(.separator())
        menu.addItem(item("Close Pane", BentoPaneAction.closePane, symbol: "xmark"))
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: anchor.bounds.maxY),
                   in: anchor)
    }

    private func item(_ title: String, _ action: Selector, symbol: String? = nil) -> NSMenuItem {
        // target = self so the menu validates/dispatches directly to the host.
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        if let symbol {
            it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
        return it
    }

    /// "Move to Session" submenu: other sessions on the server + "New
    /// Session…". The list is populated LAZILY via `menuNeedsUpdate` (this view
    /// is the submenu's delegate) instead of once up-front, because the fetch
    /// that warms `availableTmuxSessions` is async: building the items eagerly
    /// captured a still-cold cache, so the first open showed empty and only the
    /// second open (after the fetch landed) had sessions. Kicking the refresh
    /// when the parent menu opens + re-reading the cache when the submenu is
    /// about to display means the now-warm list appears on THIS open. Always
    /// actionable: moving the session's last pane makes the client follow the
    /// pane (see `movePane`), so no case needs disabling.
    private func makeMoveToSessionItem() -> NSMenuItem {
        Task { [viewModel] in await viewModel.refreshTmuxSessions() }
        let sub = NSMenu()
        sub.delegate = self
        moveToSessionMenu = sub
        populateMoveToSession(sub)   // initial fill; menuNeedsUpdate refreshes it
        let root = NSMenuItem(title: "Move to Session", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right",
                             accessibilityDescription: "Move to Session")
        root.submenu = sub
        return root
    }

    /// (Re)build the "Move to Session" submenu items from the current session
    /// cache. Called on initial construction and again from `menuNeedsUpdate`.
    private func populateMoveToSession(_ sub: NSMenu) {
        sub.removeAllItems()
        let others = viewModel.availableTmuxSessions
            .filter { $0 != viewModel.activeTmuxSessionName }
        for name in others {
            let it = item(name, #selector(movePaneToNamedSession(_:)))
            it.representedObject = name
            sub.addItem(it)
        }
        if !others.isEmpty { sub.addItem(.separator()) }
        sub.addItem(item("New Session…", #selector(movePaneToNewSession(_:)), symbol: "plus"))
    }

    /// NSMenuDelegate: rebuild the "Move to Session" list right before it shows.
    /// By now the refresh kicked when the pane menu opened has (almost always)
    /// landed — its main-actor continuation runs in the tracking runloop's
    /// common modes during the human hover delay — so the freshly warmed cache
    /// is reflected on this open. Kick another refresh to keep it current for a
    /// re-open (`refreshTmuxSessions` de-dupes while one is in flight).
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === moveToSessionMenu else { return }
        Task { [viewModel] in await viewModel.refreshTmuxSessions() }
        populateMoveToSession(menu)
    }

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
        cellPx = nil
        lastClient = nil
        layoutCells()
    }

    /// One visible pane (single or zoomed) fills the window, so its surface's
    /// reported grid is authoritative and drives tmux directly — see
    /// `pushAuthoritativeClientSize`. Only the multi-pane TILED case needs the
    /// window-bounds estimate below.
    private var isSingleOrZoom: Bool {
        viewModel.zoomedPaneID != nil || viewModel.paneViewModels.count <= 1
    }

    /// Whether `paneID` is the currently visible pane (zoomed one, or the sole pane).
    private func isVisiblePane(_ paneID: TmuxPaneID) -> Bool {
        if let z = viewModel.zoomedPaneID { return z == paneID }
        return true   // single pane
    }

    private var didInitialScreenClean = false

    /// Push ghostty's authoritative reported grid as the tmux client size
    /// (deduped + debounced). Exact match → no wrap/redraw artifacts.
    private func pushAuthoritativeClientSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        // Defer the tmux resize until the live drag ends (applied in
        // viewDidEndLiveResize). ghostty still renders at the live size.
        if window?.inLiveResize == true { pendingClient = (cols, rows); return }
        guard lastClient?.cols != cols || lastClient?.rows != rows else { return }
        lastClient = (cols, rows)
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.viewModel.resizeTmuxClient(cols: cols, rows: rows)
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
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// Convert the window size → tmux client cols×rows and push it (debounced).
    /// Native layout maps each tmux cell 1:1 to a character cell, with ONE title
    /// bar of extra height for the top pane (the rest reuse divider rows), so the
    /// grid is `⌊width / cellW⌋ × ⌊(height − titleBar) / cellH⌋`. Only the
    /// multi-pane tiled case uses this; single/zoomed panes drive tmux from the
    /// authoritative surface grid instead.
    /// The window's grid in tmux client cols×rows for the multi-pane tiled
    /// layout: `⌊width / cellW⌋ × ⌊(height − titleBar) / cellH⌋`, title bar =
    /// one cell (only the top pane adds height; the rest reuse divider rows).
    /// Shared by `recomputeClientSize` and `refitSessionToWindow`.
    private func windowGrid(cellPx: CGSize) -> (cols: Int, rows: Int) {
        let scale = currentScale
        // Title bar height = one cell (in points); subtract one for the top pane.
        let titleBarPx = cellPx.height
        let cols = max(Int((bounds.width * scale) / cellPx.width), 2)
        let rows = max(Int((bounds.height * scale - titleBarPx) / cellPx.height), 1)
        return (cols, rows)
    }

    private func recomputeClientSize() {
        guard !isSingleOrZoom else { return }
        guard let cellPx, bounds.width > 0, bounds.height > 0 else { return }
        let (cols, rows) = windowGrid(cellPx: cellPx)
        if window?.inLiveResize == true { pendingClient = (cols, rows); return }
        guard lastClient?.cols != cols || lastClient?.rows != rows else { return }
        lastClient = (cols, rows)
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.viewModel.resizeTmuxClient(cols: cols, rows: rows)
        }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// User-triggered "fit the session to THIS window": push the window's grid
    /// as the tmux client size even when it hasn't changed. The automatic
    /// pushes dedup against `lastClient`, so after ANOTHER client (an iPad)
    /// shrank the shared session, this window's unchanged size is never
    /// re-asserted on its own — this is the manual override for that case.
    public func refitSessionToWindow() {
        if !isSingleOrZoom, let cellPx, bounds.width > 0, bounds.height > 0 {
            let (cols, rows) = windowGrid(cellPx: cellPx)
            lastClient = (cols, rows)
            viewModel.resizeTmuxClient(cols: cols, rows: rows)
        } else if let last = lastClient {
            // Single/zoomed pane: the surface grid last pushed is authoritative.
            viewModel.resizeTmuxClient(cols: last.cols, rows: last.rows)
        }
    }

    /// Apply the resize deferred during a live window drag — one SIGWINCH on
    /// mouse-up instead of reflowing the TUI throughout the drag.
    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        layoutCells()
        guard let p = pendingClient else { return }
        pendingClient = nil
        guard lastClient?.cols != p.cols || lastClient?.rows != p.rows else { return }
        lastClient = (p.cols, p.rows)
        viewModel.resizeTmuxClient(cols: p.cols, rows: p.rows)
    }

    /// The bounding box of all panes in tmux cell units (used as the tiling grid).
    var paneGridSize: (cols: CGFloat, rows: CGFloat) {
        let panes = viewModel.paneViewModels
        let cols = CGFloat(max(panes.map { $0.pane.x + $0.pane.width }.max() ?? 1, 1))
        let rows = CGFloat(max(panes.map { $0.pane.y + $0.pane.height }.max() ?? 1, 1))
        return (cols, rows)
    }

    /// Points per tmux cell (font cell size ÷ backing scale), or nil until the
    /// cell size has been learned from a surface.
    private var pointsPerCell: CGSize? {
        guard let cellPx else { return nil }
        let scale = currentScale
        return CGSize(width: cellPx.width / scale, height: cellPx.height / scale)
    }

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
    private func layoutCells() {
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
        // terminal owns the full area.
        let focusMode = viewModel.sessionMode == .list
        let titleBar = focusMode ? 0 : (ppc?.height ?? Self.fallbackTitleBarHeight)

        // Push each pane's tmux mouse-reporting mode + the title-bar height onto its
        // surface/cell. (tmux -CC never streams the mouse-enable, so the flag is the
        // only signal that a program wants the mouse.)
        for (id, cell) in cells {
            cell.container.titleBarHeight = titleBar
            if let pv = vmByID[id] {
                cell.surface.mouseReporting = .init(any: pv.pane.mouseAny, sgr: pv.pane.mouseSGR)
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

        for (id, cell) in cells {
            guard let paneVM = vmByID[id] else { continue }
            let p = paneVM.pane
            cell.container.isHidden = false
            cell.container.title = paneTitle(for: paneVM)

            if panes.count == 1 || ppc == nil {
                // Single pane (or cell size not learned yet): fill the window.
                cell.container.surfaceInsetX = 0
                cell.container.frame = bounds
            } else if let ppc {
                // Native cell layout: map tmux cell geometry 1:1 to points. Each
                // pane = a title bar (one cell tall, occupying tmux's divider row)
                // + a surface of EXACTLY its tmux cols×rows. Stacked panes abut
                // through the title bar; side-by-side panes share the divider
                // column — so the container is grown half a cell into that column
                // on each side, making neighbors meet (borders + highlight land)
                // on the divider centerline with no visible gap. The surface keeps
                // its exact size via surfaceInsetX, so ghostty's grid still equals
                // tmux's pane grid (no tearing).
                let halfGap = ppc.width / 2
                cell.container.surfaceInsetX = halfGap
                cell.container.frame = NSRect(
                    x: CGFloat(p.x) * ppc.width - halfGap,
                    y: CGFloat(p.y) * ppc.height,
                    width: CGFloat(p.width) * ppc.width + 2 * halfGap,
                    height: titleBar + CGFloat(p.height) * ppc.height)
            }
        }
        dividerOverlay.refresh()
    }

    private func paneTitle(for paneVM: PaneViewModel) -> String {
        let p = paneVM.pane
        let cmd = p.currentCommand?.trimmingCharacters(in: .whitespaces) ?? ""
        let title = p.title?.trimmingCharacters(in: .whitespaces) ?? ""
        if !title.isEmpty, title != cmd { return cmd.isEmpty ? title : "\(cmd) — \(title)" }
        return cmd.isEmpty ? "shell" : cmd
    }

    private func updateActiveBorders() {
        let active = viewModel.activePaneID
        let suppress = isSingleOrZoom   // one visible pane → nothing to disambiguate
        for (id, cell) in cells {
            cell.container.focusSuppressed = suppress
            cell.container.isActivePane = (id == active)
            // Only steal first responder when it actually needs to change. An
            // unconditional makeFirstResponder re-activates the surface's
            // NSTextInputContext every call, which churns the macOS text-input
            // stack (utTryToSetupInputMethodMenu + per-activation IMK/TSM XPC
            // connections). Profiling showed that churn stalling keystrokes and
            // the XPC connections accumulating over a session ("slower over time").
            if id == active, window?.firstResponder !== cell.surface {
                window?.makeFirstResponder(cell.surface)
            }
        }
    }

    // MARK: - Pane geometry queries (used by the divider overlay)

    /// All current cell frames keyed by pane id.
    var cellFrames: [(id: TmuxPaneID, frame: NSRect)] {
        cells.compactMap { id, cell in
            cell.container.isHidden ? nil : (id, cell.container.frame)
        }
    }

    /// Resize the boundary owned by `paneID` along an axis by a signed cell delta.
    /// Vertical divider → grow/shrink to the Right/Left; horizontal → Down/Up.
    func resizeBoundary(paneID: TmuxPaneID, vertical: Bool, deltaCells: Int) {
        guard deltaCells != 0 else { return }
        let dir: String
        if vertical {
            dir = deltaCells > 0 ? "R" : "L"
        } else {
            dir = deltaCells > 0 ? "D" : "U"
        }
        viewModel.resizePaneBy(paneID, direction: dir, amount: abs(deltaCells))
    }

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
    private var splitsAllowed: Bool { viewModel.sessionMode != .list }

    /// tmux's five named layouts. The MENU says what you will see; the tmux
    /// name rides along in the tooltip.
    ///
    /// This is the one place the "use tmux's own words" rule is deliberately
    /// relaxed, because tmux's words are actively misleading here:
    /// `even-horizontal` produces side-by-side COLUMNS (it splits along the
    /// horizontal axis), which reads backwards to almost everyone — and the
    /// same trap already bit the Split labels. A label that describes the
    /// result is honest; the tooltip keeps the name you'd type at a command
    /// line, so nothing is hidden.
    static let tmuxLayouts: [(slug: String, label: String, symbol: String)] = [
        ("even-horizontal", "Even Columns", "rectangle.split.3x1"),
        ("even-vertical", "Even Rows", "rectangle.split.1x2"),
        ("main-horizontal", "Main Pane on Top", "rectangle.tophalf.inset.filled"),
        ("main-vertical", "Main Pane on Left", "rectangle.leadinghalf.inset.filled"),
        ("tiled", "Grid", "square.grid.2x2"),
    ]

    private func layoutMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "square.grid.2x2",
                             accessibilityDescription: "Layout")
        let sub = NSMenu()
        for layout in Self.tmuxLayouts {
            let it = NSMenuItem(title: layout.label, action: #selector(applyLayout(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = layout.slug
            it.toolTip = "tmux: select-layout \(layout.slug)"
            it.image = NSImage(systemSymbolName: layout.symbol, accessibilityDescription: layout.label)
            sub.addItem(it)
        }
        root.submenu = sub
        return root
    }

    @objc private func applyLayout(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let window = viewModel.activeWindowID else { return }
        Task { [viewModel] in
            _ = await viewModel.applyWindowLayout(window, layout: name)
        }
    }

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
    /// is a native directory chooser (with a command popup baked in), seeded at
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

    // MARK: - Command palette (⌘P)

    /// Open the command palette over this window's focused pane: its file
    /// context (source + cwd) drives the File section; the Command / New Pane /
    /// Recent sections are wired to this host.
    func presentCommandPalette() {
        let ctx = activePaneID.flatMap { cells[$0]?.surface.pathPreviewContext }
        CommandPaletteController.shared.present(
            fileContext: ctx,
            hostLabel: ctx?.hostLabel ?? "This Mac",
            staticSpecs: buildPaletteSpecs())
    }

    @objc private func openCommandPalette(_ sender: Any?) { presentCommandPalette() }

    /// The focused pane's file context — the dock's tree roots itself here.
    var activePathPreviewContext: PathPreviewContext? {
        activePaneID.flatMap { cells[$0]?.surface.pathPreviewContext }
    }

    private func buildPaletteSpecs() -> [PaletteSectionSpec] {
        var specs: [PaletteSectionSpec] = []

        // Recent files — empty-state suggestions (once you type, the live File
        // section covers them).
        let recentFiles = PaletteRecents.shared.files.map { entry in
            PaletteItem(id: "recent:" + entry.path,
                        title: (entry.path as NSString).lastPathComponent,
                        subtitle: paletteAbbrev(entry.path),
                        systemImage: "clock",
                        matchText: (entry.path as NSString).lastPathComponent,
                        action: .preview(path: entry.path, line: nil))
        }
        if !recentFiles.isEmpty {
            specs.append(PaletteSectionSpec(id: "recentFiles", title: "Recent Files",
                                            items: recentFiles, emptyStateOnly: true, limit: 5))
        }

        // New pane: recent (directory + command) launches → spawn a pane there.
        let launches = PaletteRecents.shared.launches.map { l -> PaletteItem in
            let name = l.command.isEmpty ? "shell" : l.command
            return PaletteItem(id: "launch:\(l.dir)::\(l.command)",
                               title: "\(name)  ·  \(paletteAbbrev(l.dir))",
                               systemImage: "plus.rectangle.on.rectangle",
                               matchText: "\(name) \(l.dir)",
                               action: .run { [weak self] in self?.launchPane(dir: l.dir, command: l.command) })
        }
        if !launches.isEmpty {
            specs.append(PaletteSectionSpec(id: "launches", title: "New Pane", items: launches, limit: 6))
        }

        specs.append(PaletteSectionSpec(id: "commands", title: "Commands",
                                        items: paletteCommands(), limit: 10))
        return specs
    }

    private func paletteCommands() -> [PaletteItem] {
        func cmd(_ id: String, _ title: String, _ image: String,
                 _ run: @escaping @MainActor () -> Void) -> PaletteItem {
            PaletteItem(id: "cmd:" + id, title: title, systemImage: image,
                        matchText: title, action: .run(run))
        }
        // Layouts are searchable by BOTH the readable label and the tmux slug,
        // so "grid" and "tiled" both find the same entry.
        let layouts = Self.tmuxLayouts.map { layout in
            PaletteItem(id: "cmd:layout-" + layout.slug,
                        title: "Layout: \(layout.label)",
                        systemImage: layout.symbol,
                        matchText: "layout \(layout.label) \(layout.slug)",
                        action: .run { [weak self] in
                            guard let self, let window = self.viewModel.activeWindowID else { return }
                            Task { [viewModel = self.viewModel] in
                                _ = await viewModel.applyWindowLayout(window, layout: layout.slug)
                            }
                        })
        }
        return layouts + [
            cmd("splitRight", "Split Right (-h)", "rectangle.split.2x1") { [weak self] in self?.splitPaneVertically(nil) },
            cmd("splitDown", "Split Down (-v)", "rectangle.split.1x2") { [weak self] in self?.splitPaneHorizontally(nil) },
            cmd("duplicate", "Duplicate Pane (dir + command)", "plus.square.on.square") { [weak self] in
                guard let self else { return }
                Task { await self.viewModel.splitPane(horizontal: true, seed: .duplicateCurrent) }
            },
            cmd("closePane", "Close Pane", "xmark.square") { [weak self] in self?.closeCurrentPane(nil) },
            cmd("zoom", "Toggle Zoom", "arrow.up.left.and.arrow.down.right") { [weak self] in self?.toggleCurrentPaneZoom(nil) },
            cmd("nextPane", "Select Next Pane", "arrow.right.square") { [weak self] in self?.selectNextPane(nil) },
            cmd("prevPane", "Select Previous Pane", "arrow.left.square") { [weak self] in self?.selectPreviousPane(nil) },
            cmd("newTmuxWindow", "New tmux Window", "plus.rectangle.on.folder") { [weak self] in self?.newTmuxWindow(nil) },
            cmd("newWindow", "New Terminal Window", "macwindow.badge.plus") { BentoTerminalWindow.newWindow() },
            cmd("fit", "Track Session Size to This Window", "arrow.up.left.and.down.right.magnifyingglass") { BentoTerminalWindow.trackActiveSessionSize() },
            cmd("toggleDock", "Toggle Preview Panel", "sidebar.trailing") { BentoTerminalWindow.togglePreviewDock() },
        ]
    }

    /// Spawn a pane in `dir` running `command` (empty = plain shell), over the
    /// already-attached control channel (no pty typed-ahead race), and remember
    /// it for the palette's New Pane suggestions.
    private func launchPane(dir: String, command: String) {
        let cmd = command.isEmpty ? nil : command
        Task { [viewModel] in
            await viewModel.splitPane(horizontal: true, seed: .custom(path: dir, command: cmd))
        }
        PaletteRecents.shared.recordLaunch(dir: dir, command: command)
    }

    private func paletteAbbrev(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Pane menu → Move to Session → <name>. The menu already selected the
    /// pane, so activePaneID is the one to move (same convention as the other
    /// pane actions). The pane keeps running; where it lands follows the
    /// target's mode (Parallel → its current window, Focus → a new window),
    /// and an unsettled target asks via `promptMoveLanding`.
    @objc func movePaneToNamedSession(_ sender: Any?) {
        guard let active = activePaneID,
              let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        moveActivePane(active, to: name)
    }

    private func moveActivePane(_ pane: TmuxPaneID, to name: String,
                                landing: MoveLanding = .auto) {
        Task { [weak self] in
            guard let self else { return }
            if await self.viewModel.movePane(pane, toSession: name, landing: landing)
                == .needsLandingChoice {
                self.promptMoveLanding(for: name) { [weak self] choice in
                    self?.moveActivePane(pane, to: name, landing: choice)
                }
            }
        }
    }

    /// The target is neither clearly Parallel nor Focus (fresh 1×1 with no
    /// remembered mode, or a mixed external structure) — ask where to land.
    private func promptMoveLanding(for name: String,
                                   _ proceed: @escaping (MoveLanding) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Move to “\(name)”"
        alert.informativeText = "“\(name)” isn't settled into Parallel or Focus yet. Where should this land?"
        alert.addButton(withTitle: "Into Current Window (Parallel)")
        alert.addButton(withTitle: "As New Window (Focus)")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: proceed(.joinCurrentWindow)
            case .alertSecondButtonReturn: proceed(.newWindow)
            default: break
            }
        }
    }

    /// Pane menu → Move to Session → New Session…: prompt for a name, then
    /// the same move path (movePane creates the session when it's missing).
    @objc func movePaneToNewSession(_ sender: Any?) {
        guard let window, let active = activePaneID else { return }
        let alert = NSAlert()
        alert.messageText = "Move Pane to New Session"
        alert.informativeText = "The pane keeps running — it becomes a window of the new session."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Session name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            // Same landing pipeline: a typed name may match an EXISTING
            // session, so the unsettled-target prompt can still follow.
            self.moveActivePane(active, to: field.stringValue)
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

    @objc public func swapActivePaneUp(_ sender: Any?) {
        guard let active = activePaneID else { return }
        viewModel.swapPane(active, up: true)
    }

    @objc public func swapActivePaneDown(_ sender: Any?) {
        guard let active = activePaneID else { return }
        viewModel.swapPane(active, up: false)
    }

    @objc public func selectNextPane(_ sender: Any?) {
        cyclePane(by: 1)
    }

    @objc public func selectPreviousPane(_ sender: Any?) {
        cyclePane(by: -1)
    }

    @objc public func newTerminalWindow(_ sender: Any?) {
        BentoTerminalWindow.newWindow()
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

    /// New window seeded from the current pane — same two seeds a split offers,
    /// so "another window" and "another pane" are created the same way and only
    /// differ in where the thing lands.
    @objc func newWindowDuplicate(_ sender: Any?) {
        Task { [viewModel] in await viewModel.newListWindow(.duplicateCurrent) }
    }

    @objc func newWindowPathCommand(_ sender: Any?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cwd = await self.viewModel.activePaneWorkingDirectory()
            presentNewPaneDirectoryPanel(
                title: "New Window", prompt: "Create", initialDirectory: cwd
            ) { [viewModel = self.viewModel] path, command in
                Task { await viewModel.newListWindow(.custom(path: path, command: command)) }
            }
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
/// can dispatch them through the responder chain to the focused host. SwiftUI
/// owns `NSApp.mainMenu` in a `MenuBarExtra` app, so we declare the menu with
/// `.commands` and route each command here rather than installing an NSMenu.
public enum BentoPaneAction {
    public static let splitVertically = #selector(GhosttyTiledPaneHost.splitPaneVertically(_:))
    public static let splitHorizontally = #selector(GhosttyTiledPaneHost.splitPaneHorizontally(_:))
    public static let closePane = #selector(GhosttyTiledPaneHost.closeCurrentPane(_:))
    public static let toggleZoom = #selector(GhosttyTiledPaneHost.toggleCurrentPaneZoom(_:))
    public static let swapPaneUp = #selector(GhosttyTiledPaneHost.swapActivePaneUp(_:))
    public static let swapPaneDown = #selector(GhosttyTiledPaneHost.swapActivePaneDown(_:))
    public static let nextPane = #selector(GhosttyTiledPaneHost.selectNextPane(_:))
    public static let previousPane = #selector(GhosttyTiledPaneHost.selectPreviousPane(_:))
    public static let newWindow = #selector(GhosttyTiledPaneHost.newTerminalWindow(_:))
    public static let newTmuxWindow = #selector(GhosttyTiledPaneHost.newTmuxWindow(_:))
    public static let splitDuplicate = #selector(GhosttyTiledPaneHost.splitDuplicateCurrent(_:))
    public static let splitPathCommand = #selector(GhosttyTiledPaneHost.splitWithPathCommand(_:))
    public static let newWindowDuplicate = #selector(GhosttyTiledPaneHost.newWindowDuplicate(_:))
    public static let newWindowPathCommand = #selector(GhosttyTiledPaneHost.newWindowPathCommand(_:))

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
    @MainActor public static func dispatch(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}

// MARK: - Pane container (title bar + terminal surface)

/// Phase of a title-bar drag used for drag-to-dock. Points are in window
/// coordinates; the host converts and hit-tests against its cells.
enum PaneDragPhase {
    case moved(NSPoint)
    case ended(NSPoint)
}

/// The translucent landing preview shown while a pane drag hovers a target:
/// the whole pane for a center/swap drop (with a ⇄ badge — the one zone whose
/// meaning isn't its own shape), the docked half for an edge drop. Hit-test
/// transparent; the title-bar drag owns the mouse anyway.
@MainActor
final class PaneDropZoneOverlay: NSView {
    private let icon = NSImageView()

    var zone: PaneDropZone = .center {
        didSet {
            guard oldValue != zone else { return }
            icon.isHidden = (zone != .center)
        }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let accent = GhosttyPaneColors.focusAccent()
        layer?.backgroundColor = accent.withAlphaComponent(0.22).cgColor
        layer?.borderColor = accent.cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 6
        icon.image = NSImage(systemSymbolName: "rectangle.2.swap",
                             accessibilityDescription: "Swap panes")?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .medium))
        icon.contentTintColor = accent
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        icon.sizeToFit()
        icon.frame.origin = NSPoint(x: (bounds.width - icon.frame.width) / 2,
                                    y: (bounds.height - icon.frame.height) / 2)
    }
}

/// A passive color wash over the terminal surface that signals pane state
/// (working / awaiting / done). Hit-test transparent so it never steals mouse
/// events from the surface — selection, link clicks, and title-bar drag-to-swap
/// all keep working underneath it.
@MainActor
final class PaneStateTintView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class PaneCellView: NSView {
    var onClick: (() -> Void)?
    /// Fired while the title bar is dragged beyond the click slop — the
    /// drag-to-dock gesture. Clicks under the threshold stay clicks.
    var onPaneDrag: ((PaneDragPhase) -> Void)?
    var onZoom: (() -> Void)? {
        didSet { titleBar.onZoom = onZoom }
    }
    var onMenu: (() -> Void)? {
        didSet { titleBar.onMenu = onMenu }
    }
    var onJumpUp: (() -> Void)? {
        didSet { titleBar.onJumpUp = onJumpUp }
    }
    var onJumpDown: (() -> Void)? {
        didSet { titleBar.onJumpDown = onJumpDown }
    }
    var canJumpUp = false {
        didSet { titleBar.canJumpUp = canJumpUp }
    }
    var canJumpDown = false {
        didSet { titleBar.canJumpDown = canJumpDown }
    }
    private let titleBar = PaneTitleBar()
    private let stateTint = PaneStateTintView()
    private weak var surface: NSView?

    /// Title-strip height (points). Set to one character cell so the strip fits
    /// exactly in tmux's divider row between stacked panes (see the host's native
    /// layout). The host updates it as the font/cell size changes.
    var titleBarHeight: CGFloat = 20 {
        didSet { needsLayout = true }
    }

    /// Horizontal inset (points) of the surface inside the container. The host
    /// grows each container half a cell into the divider column on each side so
    /// adjacent panes meet (and their borders/highlight land) on the divider
    /// centerline — no visible gap. The surface stays at its exact cell size,
    /// inset by this much so its content keeps its true position.
    var surfaceInsetX: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    /// The button the per-pane menu should anchor to.
    var menuButtonAnchor: NSView { titleBar.menuButton }

    var title: String = "" {
        didSet { titleBar.text = title }
    }

    var paneState: PaneState = .idle {
        didSet { titleBar.paneState = paneState; updateStateTint(); applyBorder() }
    }

    var agentFinishedUnseen: Bool = false {
        didSet { titleBar.agentFinishedUnseen = agentFinishedUnseen; updateStateTint(); applyBorder() }
    }

    /// Translucent wash over the surface that mirrors the title-bar dot:
    /// done-unseen → blue, otherwise the per-state color (nil = idle = no wash).
    private func stateTintColor() -> NSColor? {
        if agentFinishedUnseen {
            return PaneTitleBar.doneColor.withAlphaComponent(0.10)
        }
        return paneState.tintNSColor
    }

    private func updateStateTint() {
        let cg = stateTintColor()?.cgColor
        // Cross-fade so state changes don't pop. AppKit disables implicit
        // animations on layer-backed views, so add the transition explicitly;
        // with no fromValue it animates from the current presentation color.
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.duration = 0.25
        stateTint.layer?.add(anim, forKey: "tint")
        stateTint.layer?.backgroundColor = cg
    }

    var isActivePane: Bool = false {
        didSet {
            applyBorder()
            titleBar.isActive = isActivePane
        }
    }

    /// When only one pane is on screen (a single pane, or a zoomed pane), there's
    /// nothing to disambiguate — hide the focus border so it isn't just noise.
    var focusSuppressed: Bool = false {
        didSet {
            guard oldValue != focusSuppressed else { return }
            applyBorder()
        }
    }

    private func applyBorder() {
        // The border is purely the FOCUS cue: the window highlight color on the
        // pane you're interacting with, a near-invisible hairline on the rest.
        // Suppressed when there's only one pane visible (nothing to focus).
        // Agent state stays on the title bar + status dot + body wash, so the
        // focus ring never competes with green/amber/blue. (Drop targets are
        // previewed by the host's PaneDropZoneOverlay, not the border.)
        let showFocus = isActivePane && !focusSuppressed
        layer?.borderWidth = showFocus ? 2.0 : 0.5
        let color = GhosttyPaneColors.focusBorder(active: showFocus)
        // Resolve the dynamic accent against this view's light/dark appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = color.cgColor
        }
    }

    /// Re-derive every appearance-dependent CGColor (border + title-bar band/ink).
    /// CGColors are static snapshots, so this must run on a light/dark flip.
    func recolorChrome() {
        applyBorder()
        titleBar.recolorChrome()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Clip to the container in case the surface rounds a fraction of a pixel
        // past the edge.
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = GhosttyPaneColors.neutralHairline().cgColor
        addSubview(titleBar)

        // State wash sits above the terminal surface (added in `embed`) but below
        // the title bar, so the dot + label stay crisp while the terminal body
        // takes the tint. Hit-test transparent (see PaneStateTintView).
        stateTint.wantsLayer = true
        addSubview(stateTint, positioned: .below, relativeTo: titleBar)
        updateStateTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func embed(_ view: NSView) {
        surface = view
        // Keep the surface beneath the state wash so the tint overlays the
        // terminal content (not the other way around).
        addSubview(view, positioned: .below, relativeTo: stateTint)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = titleBarHeight
        titleBar.isHidden = (h <= 0)   // Focus mode: no pane chrome at all
        titleBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        // The surface keeps its exact cell size (= bounds minus the half-cell the
        // host added on each side, and minus the title bar), inset by surfaceInsetX
        // so its content stays put while the container reaches the divider midline.
        let surfaceRect = NSRect(x: surfaceInsetX, y: h,
                                 width: max(bounds.width - 2 * surfaceInsetX, 0),
                                 height: max(bounds.height - h, 0))
        surface?.frame = surfaceRect
        stateTint.frame = surfaceRect
    }

    // MARK: Title-bar drag (drag-to-swap)
    //
    // Mouse events only reach this view from the title bar (minus its buttons)
    // and the thin border slivers — the surface subview consumes everything
    // else — so a drag here is unambiguously "drag the pane", never text
    // selection or divider resize.
    private var dragPending = false
    private var dragActive = false
    private var dragStart: NSPoint = .zero
    private static let dragSlop: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        onClick?()
        dragPending = true
        dragActive = false
        dragStart = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragPending else {
            super.mouseDragged(with: event)
            return
        }
        let p = event.locationInWindow
        if !dragActive, hypot(p.x - dragStart.x, p.y - dragStart.y) > Self.dragSlop {
            dragActive = true
        }
        if dragActive {
            onPaneDrag?(.moved(p))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragActive {
            onPaneDrag?(.ended(event.locationInWindow))
        }
        dragPending = false
        dragActive = false
        super.mouseUp(with: event)
    }
}

/// The thin label strip atop each pane, with zoom + menu buttons on the right.
@MainActor
final class PaneTitleBar: NSView {
    private let label = NSTextField(labelWithString: "")
    /// Leading semantic state glyph (the same play/question/check language as the
    /// List sidebar), replacing the old status dot. Empty for idle.
    private let stateIcon = NSImageView()
    let zoomButton = NSButton()
    let menuButton = NSButton()
    /// Scroll-bookmark jump chevrons, left of zoom. Shown only when a jump in that
    /// direction is possible (e.g. no "down" at the live bottom).
    let markUpButton = NSButton()
    let markDownButton = NSButton()
    var onZoom: (() -> Void)?
    var onMenu: (() -> Void)?
    var onJumpUp: (() -> Void)?
    var onJumpDown: (() -> Void)?

    var canJumpUp = false {
        didSet {
            guard oldValue != canJumpUp else { return }
            markUpButton.isHidden = !canJumpUp
            needsLayout = true
        }
    }
    var canJumpDown = false {
        didSet {
            guard oldValue != canJumpDown else { return }
            markDownButton.isHidden = !canJumpDown
            needsLayout = true
        }
    }

    var text: String = "" {
        didSet { label.stringValue = text }
    }

    /// Pane working/idle/awaiting — drives the leading state glyph (play/question)
    /// and the title-bar band color (blue / amber / green).
    var paneState: PaneState = .idle {
        didSet { updateStateIcon(); updateChrome() }
    }

    /// A coding-agent pane that finished but hasn't been looked at → "done"
    /// (green ✓ glyph + green band), distinct from a plain idle/seen pane.
    var agentFinishedUnseen: Bool = false {
        didSet { updateStateIcon(); updateChrome() }
    }

    /// "Done, unseen" green (a finished ✓). Also drives the pane's state wash +
    /// band (see PaneCellView.stateTintColor / chromeAccent). Sourced from the
    /// shared palette so the List sidebar's green check matches.
    static let doneColor = PaneState.nsColor(hex: PaneState.doneUnseenHex)

    /// The leading glyph + tint for the current state. Same mapping as the List
    /// sidebar: working = play, awaiting = question, done-unseen = check, idle =
    /// a quiet hollow gray ring (same `.circle` family, empty = at rest).
    /// Colored from the shared palette.
    private func stateSymbol() -> (name: String, color: NSColor) {
        if agentFinishedUnseen { return ("checkmark.circle.fill", Self.doneColor) }
        switch paneState {
        case .working:       return ("play.circle.fill", paneState.nsColor)
        case .awaitingInput: return ("questionmark.circle.fill", paneState.nsColor)
        case .idle:          return ("circle", PaneState.nsColor(hex: PaneState.idleHex))
        }
    }

    private func updateStateIcon() {
        let (name, color) = stateSymbol()
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        stateIcon.image = img
        stateIcon.contentTintColor = color
    }

    /// Accent for the band/ink: done-unseen wins (blue), otherwise the per-state
    /// color (nil for idle → neutral chrome).
    private func chromeAccent() -> NSColor? {
        agentFinishedUnseen ? Self.doneColor : paneState.chromeAccentNSColor
    }

    /// Recompute the band background + label/button ink from (state, active).
    private func updateChrome() {
        // Agent state wins the band color; otherwise a focused-but-idle pane takes
        // the window highlight color, so focus reads from the title bar too — not
        // just the border (the border alone is too quiet for an idle gray pane).
        let accent = chromeAccent() ?? (isActive ? GhosttyPaneColors.focusAccent() : nil)
        layer?.backgroundColor = GhosttyPaneColors.titleBand(accent: accent, active: isActive).cgColor
        let ink = GhosttyPaneColors.ink(accent: accent, active: isActive)
        label.textColor = ink
        zoomButton.contentTintColor = ink
        menuButton.contentTintColor = ink
        markUpButton.contentTintColor = ink
        markDownButton.contentTintColor = ink
    }

    /// Re-derive the band/ink CGColors on a light/dark flip (see PaneCellView).
    func recolorChrome() { updateChrome() }

    var isActive: Bool = false {
        didSet { updateChrome() }
    }

    /// Square hit target for each title-bar button.
    private static let buttonSize: CGFloat = 14

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = GhosttyPaneColors.titleBand(accent: nil, active: false).cgColor

        stateIcon.imageScaling = .scaleProportionallyUpOrDown
        updateStateIcon()
        addSubview(stateIcon)

        configure(zoomButton, symbol: "arrow.up.left.and.arrow.down.right",
                  fallback: "⤢", action: #selector(zoomTapped))
        configure(menuButton, symbol: "ellipsis", fallback: "⋯", action: #selector(menuTapped))
        configure(markUpButton, symbol: "chevron.up", fallback: "▲", action: #selector(markUpTapped))
        configure(markDownButton, symbol: "chevron.down", fallback: "▼", action: #selector(markDownTapped))
        markUpButton.isHidden = true
        markDownButton.isHidden = true

        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor(white: 0.65, alpha: 1.0)
        label.lineBreakMode = .byTruncatingTail
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.cell?.usesSingleLineMode = true
        addSubview(label)

        updateChrome()
    }

    /// Manual layout (the bar's own frame is set by the parent), so the buttons
    /// sit at a fixed small size flush-right and never depend on intrinsic sizes.
    override func layout() {
        super.layout()
        let s = Self.buttonSize
        let y = ((bounds.height - s) / 2).rounded()
        let menuX = bounds.width - 6 - s
        let zoomX = menuX - 4 - s
        menuButton.frame = NSRect(x: menuX, y: y, width: s, height: s)
        zoomButton.frame = NSRect(x: zoomX, y: y, width: s, height: s)
        // Bookmark chevrons sit left of zoom, right→left (down nearest zoom, then
        // up), and only when visible — a hidden one yields its slot to the label.
        var markX = zoomX
        if canJumpDown { markX -= 4 + s; markDownButton.frame = NSRect(x: markX, y: y, width: s, height: s) }
        if canJumpUp { markX -= 4 + s; markUpButton.frame = NSRect(x: markX, y: y, width: s, height: s) }
        let chromeLeftX = (canJumpUp || canJumpDown) ? markX : zoomX
        // Fixed-width leading slot for the state glyph, so the title never shifts
        // as state changes (idle = empty slot, same x for the label).
        let icon: CGFloat = 13
        stateIcon.frame = NSRect(x: 8, y: ((bounds.height - icon) / 2).rounded(), width: icon, height: icon)
        let labelX = stateIcon.frame.maxX + 5
        let labelRight = chromeLeftX - 6
        // Center the label on its line height (a full-height NSTextField frame
        // top-aligns the glyphs, which looks off in a one-cell-tall strip).
        let font = label.font ?? .systemFont(ofSize: 10, weight: .medium)
        let lineH = ceil(font.ascender - font.descender + font.leading)
        let labelY = ((bounds.height - lineH) / 2).rounded()
        label.frame = NSRect(x: labelX, y: labelY, width: max(labelRight - labelX, 0), height: lineH)
    }

    private func configure(_ button: NSButton, symbol: String, fallback: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = action
        button.contentTintColor = NSColor(white: 0.65, alpha: 1.0)
        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            img.isTemplate = true
            button.image = img
        } else {
            button.imagePosition = .noImage
            button.title = fallback
            button.font = .systemFont(ofSize: 10)
        }
        addSubview(button)
    }

    @objc private func zoomTapped() { onZoom?() }
    @objc private func menuTapped() { onMenu?() }
    @objc private func markUpTapped() { onJumpUp?() }
    @objc private func markDownTapped() { onJumpDown?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // Let the buttons receive clicks, but everything else falls through to the
    // pane container (so clicking the title to focus the pane still works).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        let buttons: [NSView] = [zoomButton, menuButton, markUpButton, markDownButton]
        return buttons.contains(where: { $0 === hit }) ? hit : nil
    }
}

@MainActor
enum GhosttyPaneColors {
    static let accentNSColor = NSColor(srgbRed: 0.30, green: 0.90, blue: 0.62, alpha: 1.0)

    private static let srgbWhite = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let srgbBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    /// The light/dark the chrome should paint for. Read once per recolor pass.
    static var isDark: Bool { ThemeStore.shared.effectiveIsDark }

    /// Title-bar band for a state accent (nil = idle → neutral). Active panes get
    /// a brighter/heavier band so focus reads within one state color. Dark mode =
    /// dark band; light mode = light band, with colored accents tinted to match.
    static func titleBand(accent: NSColor?, active: Bool) -> NSColor {
        guard let a = accent else {
            return isDark ? NSColor(white: active ? 0.16 : 0.12, alpha: 1)
                          : NSColor(white: active ? 0.86 : 0.92, alpha: 1)
        }
        return isDark ? a.darkened(to: active ? 0.30 : 0.17)
                      : a.lightened(to: active ? 0.74 : 0.86)
    }

    /// Label / button ink over the band: muted when inactive, a tint of the accent
    /// when active. Light text on the dark band; dark text on the light band.
    static func ink(accent: NSColor?, active: Bool) -> NSColor {
        if isDark {
            guard active else { return NSColor(white: 0.62, alpha: 1) }
            guard let a = accent else { return NSColor(white: 0.95, alpha: 1) }
            return a.blended(withFraction: 0.45, of: srgbWhite) ?? a
        } else {
            guard active else { return NSColor(white: 0.42, alpha: 1) }
            guard let a = accent else { return NSColor(white: 0.16, alpha: 1) }
            return a.blended(withFraction: 0.55, of: srgbBlack) ?? a
        }
    }

    /// The system/window highlight color (the user's macOS accent) as a concrete
    /// sRGB color — the focus color for the active pane's border + title band.
    static func focusAccent() -> NSColor {
        NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? accentNSColor
    }

    /// Focus outline for the pane border: the window highlight color on the active
    /// pane, a near-invisible hairline otherwise — so the focused tile reads at a
    /// glance regardless of its agent state (which the title bar / dot / wash carry).
    static func focusBorder(active: Bool) -> NSColor {
        if active { return focusAccent() }
        return isDark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.09)
    }

    /// Neutral hairline for the title-bar default before chrome is computed.
    static func neutralHairline() -> NSColor {
        isDark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.14)
    }
}

private extension NSColor {
    /// Multiply RGB toward black by `factor` (0…1), preserving alpha. Works in
    /// sRGB so the result is predictable regardless of the source color space.
    func darkened(to factor: CGFloat) -> NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        return NSColor(srgbRed: c.redComponent * factor,
                       green: c.greenComponent * factor,
                       blue: c.blueComponent * factor,
                       alpha: c.alphaComponent)
    }

    /// Mix RGB toward white by `amount` (0…1), preserving alpha — the light-mode
    /// analog of `darkened(to:)` for tinting a colored band on a light surface.
    func lightened(to amount: CGFloat) -> NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        return NSColor(srgbRed: c.redComponent + (1 - c.redComponent) * amount,
                       green: c.greenComponent + (1 - c.greenComponent) * amount,
                       blue: c.blueComponent + (1 - c.blueComponent) * amount,
                       alpha: c.alphaComponent)
    }
}

// MARK: - Divider overlay (drag to resize)

/// A transparent overlay covering the whole host. It is hit-test-transparent
/// except within a few points of a divider between two adjacent panes, where it
/// claims the mouse to drag-resize (and shows a resize cursor). Everywhere else
/// clicks fall through to the panes.
@MainActor
final class DividerOverlay: NSView {
    weak var host: GhosttyTiledPaneHost?

    /// A draggable boundary: the pane that owns it, orientation, and hot rect.
    private struct Divider {
        let paneID: TmuxPaneID
        let vertical: Bool   // true = vertical line, drags left/right
        let position: CGFloat // x (vertical) or y (horizontal), in points
        let hotRect: NSRect
    }

    private var dividers: [Divider] = []
    private static let hotThickness: CGFloat = 10

    // Active drag state.
    private var dragDivider: Divider?
    private var dragStart: NSPoint = .zero
    private var dragSentCells: Int = 0
    /// Live cursor coordinate (x for vertical, y for horizontal) during a drag.
    private var dragLivePos: CGFloat?

    override var isFlipped: Bool { true }

    /// Recompute divider hot zones from the host's current cell frames.
    func refresh() {
        dividers = computeDividers()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: - Drawing (visual feedback)

    override func draw(_ dirtyRect: NSRect) {
        let lineColor = GhosttyPaneColors.isDark
            ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.18)
        for d in dividers {
            strokeLine(vertical: d.vertical, at: d.position, span: d.hotRect,
                       color: lineColor, width: 1)
        }
        // The line being dragged tracks the cursor live (tmux relayout lags
        // behind), drawn in the accent colour so the drag is clearly visible.
        if let d = dragDivider, let pos = dragLivePos {
            strokeLine(vertical: d.vertical, at: pos, span: d.hotRect,
                       color: GhosttyPaneColors.accentNSColor, width: 2)
        }
    }

    private func strokeLine(vertical: Bool, at pos: CGFloat, span: NSRect,
                            color: NSColor, width: CGFloat) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = width
        if vertical {
            path.move(to: NSPoint(x: pos, y: span.minY))
            path.line(to: NSPoint(x: pos, y: span.maxY))
        } else {
            path.move(to: NSPoint(x: span.minX, y: pos))
            path.line(to: NSPoint(x: span.maxX, y: pos))
        }
        path.stroke()
    }

    private func computeDividers() -> [Divider] {
        guard let host else { return [] }
        let frames = host.cellFrames
        guard frames.count > 1 else { return [] }
        // Proportional tiling leaves a ~1-cell GAP between adjacent panes (the
        // tmux divider column), so neighbours don't share a coincident edge.
        // Match across that gap, and centre the hot zone within it.
        let cell = pointsPerCell() ?? CGPoint(x: 8, y: 8)
        let gapTolX = max(cell.x * 1.8, 6)
        let gapTolY = max(cell.y * 1.8, 6)
        let eps: CGFloat = 2
        var result: [Divider] = []

        for a in frames {
            // Vertical divider: a pane sits just to the right of a's right edge.
            let rightEdge = a.frame.maxX
            if rightEdge < bounds.width - eps {
                let neighbors = frames.filter {
                    $0.frame.minX > rightEdge - eps
                        && $0.frame.minX - rightEdge < gapTolX
                        && yOverlap($0.frame, a.frame) > eps
                }
                if let nearest = neighbors.map(\.frame.minX).min() {
                    let pos = (rightEdge + nearest) / 2
                    let yTop = neighbors.map { max($0.frame.minY, a.frame.minY) }.min() ?? a.frame.minY
                    let yBot = neighbors.map { min($0.frame.maxY, a.frame.maxY) }.max() ?? a.frame.maxY
                    result.append(Divider(
                        paneID: a.id, vertical: true, position: pos,
                        hotRect: NSRect(x: pos - Self.hotThickness / 2, y: yTop,
                                        width: Self.hotThickness, height: yBot - yTop)
                    ))
                }
            }
            // Horizontal divider: a pane sits just below a's bottom edge.
            let bottomEdge = a.frame.maxY
            if bottomEdge < bounds.height - eps {
                let neighbors = frames.filter {
                    $0.frame.minY > bottomEdge - eps
                        && $0.frame.minY - bottomEdge < gapTolY
                        && xOverlap($0.frame, a.frame) > eps
                }
                if let nearest = neighbors.map(\.frame.minY).min() {
                    let pos = (bottomEdge + nearest) / 2
                    let xL = neighbors.map { max($0.frame.minX, a.frame.minX) }.min() ?? a.frame.minX
                    let xR = neighbors.map { min($0.frame.maxX, a.frame.maxX) }.max() ?? a.frame.maxX
                    result.append(Divider(
                        paneID: a.id, vertical: false, position: pos,
                        hotRect: NSRect(x: xL, y: pos - Self.hotThickness / 2,
                                        width: xR - xL, height: Self.hotThickness)
                    ))
                }
            }
        }
        return result
    }

    private func yOverlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        min(a.maxY, b.maxY) - max(a.minY, b.minY)
    }
    private func xOverlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        min(a.maxX, b.maxX) - max(a.minX, b.minX)
    }

    private func divider(at point: NSPoint) -> Divider? {
        dividers.first { $0.hotRect.contains(point) }
    }

    // Transparent except over a divider hot zone.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return divider(at: local) != nil ? self : nil
    }

    override func resetCursorRects() {
        for d in dividers {
            addCursorRect(d.hotRect, cursor: d.vertical ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragDivider = divider(at: p)
        dragStart = p
        dragSentCells = 0
        dragLivePos = dragDivider.map { $0.vertical ? p.x : p.y }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let host, let d = dragDivider, let cellPts = pointsPerCell() else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragLivePos = d.vertical ? p.x : p.y
        needsDisplay = true
        let deltaPts = d.vertical ? (p.x - dragStart.x) : (p.y - dragStart.y)
        let perCell = d.vertical ? cellPts.x : cellPts.y
        guard perCell > 0 else { return }
        let totalCells = Int((deltaPts / perCell).rounded())
        let incremental = totalCells - dragSentCells
        guard incremental != 0 else { return }
        dragSentCells = totalCells
        host.resizeBoundary(paneID: d.paneID, vertical: d.vertical, deltaCells: incremental)
    }

    override func mouseUp(with event: NSEvent) {
        dragDivider = nil
        dragSentCells = 0
        dragLivePos = nil
        needsDisplay = true
    }

    /// Points per tmux cell along each axis (proportional tiling = bounds / grid).
    private func pointsPerCell() -> CGPoint? {
        guard let host, bounds.width > 0, bounds.height > 0 else { return nil }
        let grid = host.paneGridSize
        guard grid.cols > 0, grid.rows > 0 else { return nil }
        return CGPoint(x: bounds.width / grid.cols, y: bounds.height / grid.rows)
    }
}

private struct PaneCell {
    let container: PaneCellView
    let surface: GhosttyTerminalSurface
}
#endif
