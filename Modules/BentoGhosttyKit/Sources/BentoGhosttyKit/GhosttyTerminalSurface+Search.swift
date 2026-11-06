import BentoFilePreviewKit
import BentoFoundationKit
#if canImport(UIKit)
import UIKit
import GhosttyKit

extension GhosttyTerminalSurface {

    // Scrollback search is macOS-only for now — the engine side is shared (see
    // GhosttySel.search), only the find-bar UI is not built for touch yet. These
    // stubs exist because the runtime's action router is one shared switch.
    // MARK: - Scrollback search
    //
    // The engine owns the search itself — it walks the scrollback, highlights
    // the matches in the renderer, tracks the current hit and reports the counts
    // back. The surface only relays; the host owns the find bar, because on iOS
    // it has to be positioned against the keyboard.

    /// Start (or re-run) the search. An empty needle ends it.
    public func runSearch(_ needle: String) {
        guard let surface else { return }
        GhosttySel.search(surface, needle: needle)
        if needle.isEmpty {
            searchTotal = nil
            searchSelected = nil
            onSearchCounts?(nil, nil)
        }
        setNeedsDraw()
    }

    public func navigateSearch(forward: Bool) {
        guard let surface else { return }
        GhosttySel.navigateSearch(surface, forward: forward)
        setNeedsDraw()
    }

    public func endSearch() {
        guard let surface else { return }
        GhosttySel.endSearch(surface)
        searchTotal = nil
        searchSelected = nil
        setNeedsDraw()
    }

    /// Current selection, when it makes a usable needle (single-line, non-empty).
    /// Seeds the find field the way ⌘E does on the Mac.
    public func selectionAsNeedle() -> String? {
        guard let surface else { return nil }
        return SearchBarModel.needle(fromSelection: GhosttySel.selectedText(surface))
    }

    public func handleStartSearch(needle: String?) { onSearchStartRequested?(needle) }
    public func handleEndSearch() { onSearchEnded?() }

    public func handleSearchTotal(_ total: Int?) {
        searchTotal = total
        onSearchCounts?(searchTotal, searchSelected)
    }

    public func handleSearchSelected(_ selected: Int?) {
        searchSelected = selected
        onSearchCounts?(searchTotal, searchSelected)
    }
}
#endif
