#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFilePreviewKit
import BentoFoundationKit
import AppKit
import GhosttyKit

extension GhosttyTerminalSurface {

    // MARK: - Engine cursor & mouse feedback

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: mouseCursor)
    }

    /// Apply the cursor shape ghostty requests as the pointer moves over text /
    /// links / split handles.
    public func handleMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        let c = Self.cursor(for: shape)
        guard c != mouseCursor else { return }
        mouseCursor = c
        c.set()
        window?.invalidateCursorRects(for: self)
    }

    private static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: return .closedHand
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE,
             GHOSTTY_MOUSE_SHAPE_W_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE: return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_N_RESIZE,
             GHOSTTY_MOUSE_SHAPE_S_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE: return .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: return .operationNotAllowed
        default: return .arrow
        }
    }

    /// Hide the pointer while typing; show it on mouse move. Balanced so the
    /// cursor can't get stuck hidden.
    public func handleMouseVisibility(_ visible: Bool) {
        if visible {
            if mouseHidden { NSCursor.unhide(); mouseHidden = false }
        } else if !mouseHidden {
            NSCursor.hide(); mouseHidden = true
        }
    }

    public var linkOrigin: LinkOrigin? { linkOriginProvider?() }

    /// The engine re-reports the hovered link on EVERY mouse-position update
    /// (not just when it changes), so a slow drag across one link fires this
    /// dozens of times a second. Everything below the cell update is gated on
    /// an actual change — an unchanged `toolTip` assignment still churns
    /// AppKit's tooltip machinery, and an unchanged log line is pure noise in
    /// the one stream that has to stay readable while debugging a click.
    public func handleMouseOverLink(_ url: String?) {
        let clean = (url?.isEmpty == false) ? url : nil
        if let clean, let c = lastEngineMouseCell {
            engineLink = (clean, c.col, c.row)
        } else {
            engineLink = nil
        }
        guard clean != lastReportedLinkURL else { return }
        lastReportedLinkURL = clean
        toolTip = clean
        linkLog.log("MOUSE_OVER_LINK url=⟨\(clean ?? "nil", privacy: .public)⟩ cell=\(self.lastEngineMouseCell.map { "\($0.col),\($0.row)" } ?? "?", privacy: .public)")
    }

    /// The URL rendered under `point`, or nil — shared TerminalLinkDetector
    /// over the visual rows read via a transient selection (cleared before
    /// returning). Only called with no live selection (⌘-click guard).
    /// The logical line + tapped cell under `point`, from the same screen
    /// snapshot path detection uses. Not gated on `pathPreviewContext` — links
    /// must open in a pane that has no preview context at all.
    private func logicalLine(at point: NSPoint) -> (line: String, cell: Int)? {
        guard !isTornDown, let cell = cellSizePoints(), let cs = currentSize else { return nil }
        return pathHitEngine.logicalLine(
            point: point, cellSize: cell, viewportRows: cs.rows,
            cols: pathWrapCols?() ?? cs.columns,
            scrollTop: lastScrollTop,
            readText: { [weak self] in self?.readScrollback() })
    }

    /// The URL under `point`, or nil.
    ///
    /// This used to read the screen by driving a transient ghostty SELECTION
    /// across each nearby row and reading it back — which both mutated live
    /// state to answer a question and gave link detection a different picture of
    /// the screen than path detection had. A URL the path scanner read whole
    /// could be invisible here, and then the path scanner would happily
    /// fuzzy-match the URL's last segment to a local directory and open a file
    /// viewer for a link. One snapshot, one answer.
    func linkURL(at point: NSPoint) -> String? {
        // The engine's answer is the last hover, anchored to its cell so a
        // stale hover can't answer for a later click.
        let c = cellCoord(atPoint: point)
        let engine = engineLink.flatMap { $0.col == c.col && $0.row == c.row ? $0.url : nil }
        if engine == nil {
            linkLog.log("link via scrape cell=\(c.col, privacy: .public),\(c.row, privacy: .public) engine=\(self.engineLink.map(\.url) ?? "nil", privacy: .public)")
        }
        return SurfaceLinkResolver.url(engine: engine) { logicalLine(at: point) }
    }

    public func handlePwd(_ pwd: String?) {
        if let pwd, !pwd.isEmpty { reportedPwd = pwd }
    }

    // MARK: - Path preview (⌘hover / ⌘click / context menu)

    func cellSizePoints() -> CGSize? {
        GhosttyCellGeometry.cellSize(currentSize, scale: currentScale)
    }

    /// Path candidate + highlight rects under `point` (surface coords), or nil.
    /// Same-line only — the zero-I/O detector behind hover and context menus.
    func pathHit(at point: NSPoint) -> SurfacePathHitEngine.Hit? {
        guard pathPreviewContext != nil, !isTornDown,
              let cell = cellSizePoints(), let cs = currentSize else { return nil }
        return pathHitEngine.hit(
            point: point, cellSize: cell, viewportRows: cs.rows,
            cols: pathWrapCols?() ?? cs.columns,
            scrollTop: lastScrollTop,
            readText: { [weak self] in self?.readScrollback() })
    }

    /// Ordered tap candidates under `point` (wrap-chain joins first) plus
    /// screen-context root hints. Used by ⌘click, which can afford
    /// stat-verification before showing UI.
    func pathTapHits(at point: NSPoint) -> SurfacePathHitEngine.TapScan {
        guard pathPreviewContext != nil, !isTornDown,
              let cell = cellSizePoints(), let cs = currentSize else { return .empty }
        return pathHitEngine.tapHits(
            point: point, cellSize: cell, viewportRows: cs.rows,
            cols: pathWrapCols?() ?? cs.columns,
            scrollTop: lastScrollTop,
            readText: { [weak self] in self?.readScrollback() })
    }

    /// ⌘click on path candidates: a self-contained explicit token opens
    /// immediately (the panel shows not-found if it lied); everything else —
    /// bare relatives, wrap-chain joins, truncated suffixes — resolves through
    /// `SmartPathResolver` first, and the first candidate that exists wins.
    func handlePathClick(_ scan: SurfacePathHitEngine.TapScan) {
        guard let context = pathPreviewContext else { return }
        clearPathHover()
        let hits = scan.hits
        if hits[0].fastPath {
            onOpenPreview?(hits[0].path, hits[0].line, context)
            return
        }
        pathClickSeq += 1
        let seq = pathClickSeq
        Task { @MainActor [weak self] in
            let res = try? await SmartPathResolver.resolveFirst(
                paths: hits.map(\.path), rootHints: scan.rootHints,
                context: context)
            guard let self, self.pathClickSeq == seq, !self.isTornDown else { return }
            if let res {
                onOpenPreview?(res.resolvedPath, hits[res.index].line, context)
            } else if let url = hits.lazy.compactMap({ TerminalLinkDetector.schemelessURL($0.path) }).first {
                // Nothing exists by that name and it's host-shaped
                // ("github.com/NovaShang/…"): it was a link all along. Checked
                // AFTER resolution so a real file of that name still wins.
                LinkRouter.open(url, from: self.linkOrigin)
            } else {
                // Nothing stat'd. Open the best guess anyway so the panel says
                // "not found" — a ⌘click that resolves to silence is
                // indistinguishable from a ⌘click that never fired, and sends
                // the user looking for a broken build instead of a wrong path.
                onOpenPreview?(hits[0].path, hits[0].line, context)
            }
        }
    }

    /// A plain click that landed on a file path in a pane whose program owns
    /// the mouse. Forwarding it is correct — the program asked for clicks — but
    /// the user near-certainly wanted the preview, and nothing on screen says
    /// the gesture moved. Claude Code's fullscreen mode made this the common
    /// case: it grabs the mouse for a UI whose most clickable-looking things are
    /// the file paths it prints, which are Bento's, not its.
    func notePathClickForwarded(at p: NSPoint) {
        guard pathPreviewContext != nil else { return }
        if let last = lastPathHintAt, Date().timeIntervalSince(last) < 300 { return }
        guard pathHit(at: p) != nil else { return }
        lastPathHintAt = Date()
        PaneHintChip.show("⌘-click to preview this path", in: self)
    }

    /// ⌘hover: highlight the path token under the cursor. Recomputed only when
    /// the hovered cell changes (mouse-moved storms are cheap).
    func updatePathHover(_ event: NSEvent) {
        guard pathPreviewContext != nil, let cell = cellSizePoints() else { return }
        let p = convert(event.locationInWindow, from: nil)
        let cellPos = (col: Int(p.x / cell.width), row: Int(p.y / cell.height))
        if let last = lastHoverCell, last == cellPos { return }
        lastHoverCell = cellPos
        let hit = pathHit(at: p)
        hoveredPathHit = hit
        if let hit {
            let view = ensurePathHighlight()
            view.rects = hit.rects
            view.isHidden = false
            toolTip = nil
            NSCursor.pointingHand.set()
        } else {
            clearPathHover()
        }
    }

    func clearPathHover() {
        lastHoverCell = nil
        hoveredPathHit = nil
        guard let pathHighlight, !pathHighlight.isHidden else { return }
        pathHighlight.isHidden = true
        mouseCursor.set()
    }

    private func ensurePathHighlight() -> PathHighlightView {
        if let pathHighlight { return pathHighlight }
        let v = PathHighlightView(frame: bounds)
        v.autoresizingMask = [.width, .height]
        v.isHidden = true
        addSubview(v)
        pathHighlight = v
        return v
    }

    /// Open the preview in the side dock for a confirmed hit.
    func presentPathPreview(_ hit: SurfacePathHitEngine.Hit) {
        guard let context = pathPreviewContext else { return }
        clearPathHover()
        onOpenPreview?(hit.candidate.path, hit.candidate.line, context)
    }

    public override func flagsChanged(with event: NSEvent) {
        if !event.modifierFlags.contains(.command) { clearPathHover() }
        super.flagsChanged(with: event)
    }

    public override func mouseExited(with event: NSEvent) {
        clearPathHover()
        super.mouseExited(with: event)
    }
}
#endif
