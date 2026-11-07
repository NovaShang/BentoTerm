import BentoTmuxKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import BentoSessionKit
import BentoUISharedKit

// MARK: - Pane wiring (surface / container / published state → one pane cell)

extension GhosttyTiledPaneHost {
    /// Output from `paneID` might have announced a dev server. Called from
    /// whatever thread produced the bytes — the cheap byte prefilter runs
    /// there and the main hop only happens on an actual hit, so the output
    /// path pays a scan and nothing else.
    nonisolated private func noticeDevServer(in data: Data, paneID: TmuxPaneID) {
        guard DevServerDetector.mightAnnounce(data) else { return }
        guard let text = String(data: data, encoding: .utf8),
              let found = DevServerDetector.detect(in: text) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.devServerOffers.shouldOffer(port: found.port, inPane: "\(paneID)") else { return }
            let host = self.linkHost
            self.cells[paneID]?.container.offerDevServer(port: found.port) {
                BentoTerminalWindow.openWeb(
                    url: found.url,
                    origin: LinkOrigin(paneID: "\(paneID)", host: host))
            }
        }
    }

    /// Surface ↔ view-model wiring: output/input, selection, voice, split, size.
    /// Extracted from `makeCell`.
    func wireSurfaceCallbacks(_ surface: GhosttyTerminalSurface,
                              paneVM: PaneViewModel,
                              paneID: TmuxPaneID) {
        paneVM.onDataReceived = { [weak surface, weak self] data in
            // Watch for `Local: http://localhost:5173/` going past. Byte-level
            // prefilter first: this is the output path and it is not allowed
            // to cost anything.
            self?.noticeDevServer(in: data, paneID: paneID)
            // Called synchronously by `feedData`, which now runs on the tmux
            // parse queue for the common case — so this must NOT assume the main
            // actor (`assumeIsolated` would trap). `feed` is nonisolated and
            // hands straight off to the surface's ioQueue, so calling it inline
            // from whatever thread produced the bytes is both safe and the whole
            // point: output never waits on the main thread.
            surface?.feed(data)
        }
        surface.onInput = { [weak paneVM] data in paneVM?.sendInput(data) }
        surface.onOpenPreview = { [weak self] path, line, context in
            guard let self else { return }
            BentoTerminalWindow.openPreview(path: path, line: line, context: context)
        }
        surface.onSelect = { [weak self] in self?.viewModel.selectPane(paneID) }
        // Which machine THIS pane means by `localhost` — a link clicked in a
        // pane of a remote tmux session points at that box, not at this one.
        surface.linkOriginProvider = { [weak self] in
            guard let self else { return nil }
            return LinkOrigin(paneID: "\(paneID)", host: self.linkHost)
        }
        // Wheel in a pane tmux has in copy-mode → tmux's own scroll, not ours.
        surface.onCopyModeScroll = { [weak self] rows in
            self?.viewModel.scrollCopyMode(paneID, rows: rows)
        }
        surface.onExitCopyMode = { [weak self] in self?.viewModel.exitCopyMode(paneID) }
        // Right-click gets the same pane actions as the title bar's ⌄ button.
        // Selecting first is load-bearing, not cosmetic: these items dispatch
        // through the responder chain to whichever pane is ACTIVE, so without
        // it a right-click on an inactive pane would split, swap or close a
        // different one than the one under the cursor.
        surface.contextMenuPaneItems = { [weak self] in
            guard let self else { return [] }
            self.viewModel.selectPane(paneID)
            return self.paneMenuItems(for: paneID)
        }
        // The sticky mouse-reporting override is per-surface state, so the title
        // bar's glyph has to follow it rather than the pane list.
        surface.onMouseReportingSuppressedChanged = { [weak self] _ in
            guard let self, let cell = self.cells[paneID] else { return }
            self.refreshModeBadge(cell)
        }
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
            // Learned on every change (see `TiledClientSizer.learn`): a
            // backing-scale move or a font change re-tiles at once.
            if self.sizer.learn(cellWidthPx: size.cellWidthPx, cellHeightPx: size.cellHeightPx) {
                self.recomputeClientSize()
                self.layoutCells()
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

        // Path preview (⌘hover / ⌘click): files come straight off this Mac's
        // disk, which is only right for a local session (see remoteBlock). cwd = the pane's live tmux
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
            // Files come off the LOCAL disk; when this tab's tmux runs on an
            // ssh host, or this pane is an ssh/mosh session, the real files are
            // on another machine — refuse honestly rather than resolve a remote
            // cwd against this Mac's disk (a path that happens to exist here
            // too would preview the wrong file).
            remoteBlock: { [weak self, weak paneVM] in
                let host = self?.linkHost
                return PathPreviewContext.localSourceBlock(
                    sessionHost: host?.isLocal == false ? host?.label : nil,
                    foregroundCommand: paneVM?.pane.currentCommand)
            })
    }

    /// Container (title bar / chrome) action wiring. Extracted from `makeCell`.
    func wireContainerActions(_ container: PaneCellView,
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
        // The mode glyph is also the way OUT of the mode it reports — a badge you
        // can't act on just tells you you're stuck.
        container.onModeBadge = { [weak self] in
            guard let self, let cell = self.cells[paneID] else { return }
            if cell.surface.tmuxInMode {
                self.viewModel.exitCopyMode(paneID)
            } else if cell.surface.mouseReportingSuppressed {
                cell.surface.mouseReportingSuppressed = false
            }
        }
    }

    /// Published-state → chrome bindings. The sinks live in `cellBags[paneID]`
    /// so removing the pane's cell cancels them (see `syncPanes`). Extracted
    /// from `makeCell`.
    func wireStateBindings(paneVM: PaneViewModel,
                           container: PaneCellView,
                           paneID: TmuxPaneID) {
        var bag = Set<AnyCancellable>()

        // Drive the title-bar status dot from the pane's state (what its
        // `@bento_state` option reports, via PaneViewModel.paneState).
        container.paneState = paneVM.paneState
        paneVM.$paneState
            .receive(on: RunLoop.main)
            .sink { [weak container] state in container?.paneState = state }
            .store(in: &bag)

        // "Done, unseen" badge (the pane finished while you weren't looking).
        container.doneUnseen = paneVM.doneUnseen
        paneVM.$doneUnseen
            .receive(on: RunLoop.main)
            .sink { [weak container] v in container?.doneUnseen = v }
            .store(in: &bag)

        cellBags[paneID] = bag
    }
}
#endif
