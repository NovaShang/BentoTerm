import BentoFilePreviewKit
import BentoFoundationKit
#if canImport(UIKit)
import UIKit
import GhosttyKit

extension GhosttyTerminalSurface {

    // MARK: - Viewport position (feeds the hit-tests below)

    /// Called by GhosttyRuntime on every SCROLLBAR action.
    public func handleScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        lastScrollTop = Int(offset)
    }

    // MARK: - Path preview hit-testing

    public func handlePwd(_ pwd: String?) {
        if let pwd, !pwd.isEmpty { reportedPwd = pwd }
    }

    /// Ordered path candidates + highlight rects under a tap at `point`
    /// (surface coords) — wrap-chain joins first, bare fragment last — plus
    /// screen-context root hints. The caller stat-verifies in order unless
    /// `hits[0].fastPath`. `wrapCols` is the tmux pane width when available;
    /// nil falls back to ghostty's grid. Public: the iOS host lives in the app
    /// target.
    public func pathTapHits(at point: CGPoint, wrapCols: Int?) -> SurfacePathHitEngine.TapScan {
        guard let cs = currentSize, let cell = cellSize else { return .empty }
        return pathHitEngine.tapHits(
            point: point, cellSize: cell, viewportRows: cs.rows,
            cols: wrapCols ?? cs.columns,
            scrollTop: lastScrollTop,
            readText: { [weak self] in self?.readScrollback() })
    }

    /// The whole scrollback as text (one line per row, top-aligned with the
    /// SCROLLBAR row space). Public: the iOS host lives in the app target.
    public func readScrollback() -> String? {
        guard let surface else { return nil }
        return GhosttySel.screenText(surface)
    }

    // MARK: - Tap-to-open links

    /// Only logged on change: the engine re-reports the hovered link on every
    /// mouse-position update, not just when it changes.
    public func handleMouseOverLink(_ url: String?) {
        let clean = (url?.isEmpty == false) ? url : nil
        defer { engineLinkURL = clean }
        guard clean != engineLinkURL else { return }
        linkLog.log("MOUSE_OVER_LINK url=⟨\(clean ?? "nil", privacy: .public)⟩")
    }

    /// A tap landed at `point` — if a URL is rendered under it, open it. This
    /// is what makes remote agent sign-in (an OAuth URL printed by a headless
    /// host) completable from the phone.
    ///
    /// Returns whether a URL was found and opened — callers chain the
    /// path-preview hit-test off a miss (the two detectors are disjoint).
    @discardableResult
    public func openLinkIfPresent(at point: CGPoint, wrapCols: Int? = nil) -> Bool {
        guard let url = linkTapHit(at: point, wrapCols: wrapCols) else { return false }
        LinkRouter.open(url, from: linkOrigin)
        return true
    }

    public var linkOrigin: LinkOrigin? { linkOriginProvider?() }

    /// The URL under `point`, or nil — hit-test only, nothing is opened.
    ///
    /// The iOS host asks for the URL rather than for "did it open", because a
    /// tap only OFFERS the link (chip) and the answer also decides whether the
    /// program running in the pane gets this tap at all.
    ///
    /// Two routes: the engine's OSC 8 answer, then a scrape. The scrape reads
    /// the VISUAL row under the tap and reassembles the wrap-chain when the row
    /// runs edge-to-edge (long OAuth URLs always wrap), then regexes for a URL
    /// span containing the tap column. Links the app would refuse to open
    /// (anything outside the scheme allowlist) count as a MISS, so a `file://`
    /// in the output falls through to path detection instead of offering a chip
    /// that does nothing.
    public func linkTapHit(at point: CGPoint, wrapCols: Int? = nil) -> String? {
        guard let url = detectLink(at: point, wrapCols: wrapCols),
              LinkRouter.canOpen(url) else { return nil }
        return url
    }

    private func detectLink(at point: CGPoint, wrapCols: Int? = nil) -> String? {
        guard !isTornDown, let size = currentSize, let cell = cellSize else { return nil }
        // A touch has no hover, so report the pointer at the tapped cell to
        // provoke the engine's OSC 8 answer, then take it if one arrived.
        engineLinkURL = nil
        if let surface {
            ghostty_surface_mouse_pos(surface, Double(point.x), Double(point.y), GHOSTTY_MODS_NONE)
        }
        return SurfaceLinkResolver.url(engine: engineLinkURL) {
            pathHitEngine.logicalLine(
                point: point, cellSize: cell, viewportRows: size.rows,
                cols: wrapCols ?? size.columns,
                scrollTop: lastScrollTop,
                readText: { [weak self] in self?.readScrollback() })
        }
    }
}
#endif
