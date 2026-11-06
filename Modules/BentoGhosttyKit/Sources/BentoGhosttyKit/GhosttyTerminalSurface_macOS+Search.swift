#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFilePreviewKit
import BentoFoundationKit
import AppKit
import GhosttyKit

extension GhosttyTerminalSurface {

    // MARK: - Scrollback search (⌘F)

    /// True while the find bar holds the keyboard. The host checks this before
    /// re-asserting first responder on the surface — otherwise its periodic
    /// `updateActiveBorders` would yank the caret out of the field mid-typing.
    public var searchFieldHasFocus: Bool { searchBar?.fieldHasFocus ?? false }

    public var isSearchOpen: Bool { searchBar != nil }

    /// Open the find bar. `prefill` (⌘F with a selection, or the engine's own
    /// START_SEARCH) seeds the field and searches immediately.
    public func beginSearch(prefill: String? = nil) {
        let bar = searchBar ?? makeSearchBar()
        if let seed = SearchBarModel.needle(
            fromSelection: prefill ?? surface.flatMap { GhosttySel.selectedText($0) }) {
            bar.query = seed
            bar.model.setQuery(seed)   // counts for a seed that never went through typing
            runSearch(seed)
        }
        layoutSearchBar()
        bar.focusField()
    }

    /// Close the find bar and hand the keyboard back to the terminal.
    public func endSearchUI() {
        guard let bar = searchBar else { return }
        bar.model.cancelPendingQuery()
        bar.removeFromSuperview()
        searchBar = nil
        // Ask the engine to drop the search LAST: ghostty performs keybind
        // actions synchronously and echoes END_SEARCH back through
        // handleEndSearch → this method. With the bar already nil'd the echo
        // hits `guard searchBar != nil` and returns — dispatch first, and the
        // echo re-dispatches end_search forever (observed: ~770 stack levels).
        if let surface { GhosttySel.endSearch(surface) }
        // Only reclaim first responder if the bar actually had it; a click that
        // moved focus to another pane must not be dragged back here.
        if window?.firstResponder == nil || bar.fieldHasFocus {
            window?.makeFirstResponder(self)
        }
        setNeedsDraw()
    }

    public func findNext() { navigateSearch(forward: true) }
    public func findPrevious() { navigateSearch(forward: false) }

    /// ⌘E — Use Selection for Find (the standard macOS pair with ⌘F/⌘G).
    public func useSelectionForFind() {
        guard let surface,
              let text = SearchBarModel.needle(fromSelection: GhosttySel.selectedText(surface))
        else { return }
        let bar = searchBar ?? makeSearchBar()
        bar.query = text
        bar.model.setQuery(text)
        runSearch(text)
        layoutSearchBar()
    }

    private func navigateSearch(forward: Bool) {
        guard let surface else { return }
        // ⌘G with no bar open is still meaningful once a search has run, but the
        // engine drops the search on end_search — so open the bar first.
        guard searchBar != nil else { beginSearch(); return }
        GhosttySel.navigateSearch(surface, forward: forward)
        setNeedsDraw()
    }

    private func makeSearchBar() -> PaneSearchBar {
        let bar = PaneSearchBar(frame: PaneSearchBar.frame(in: bounds.size))
        bar.model.onQueryChanged = { [weak self] text in self?.runSearch(text) }
        bar.model.onNext = { [weak self] in self?.findNext() }
        bar.model.onPrevious = { [weak self] in self?.findPrevious() }
        bar.model.onClose = { [weak self] in self?.endSearchUI() }
        addSubview(bar)
        searchBar = bar
        return bar
    }

    private func runSearch(_ needle: String) {
        guard let surface else { return }
        GhosttySel.search(surface, needle: needle)
        if needle.isEmpty { searchBar?.model.setCounts(total: nil, selected: nil) }
        setNeedsDraw()
    }

    func layoutSearchBar() {
        guard let bar = searchBar else { return }
        bar.frame = PaneSearchBar.frame(in: bounds.size)
    }

    // Engine → app. All four arrive on the main thread inside `ghostty_app_tick`.

    public func handleStartSearch(needle: String?) {
        beginSearch(prefill: needle)
    }

    public func handleEndSearch() {
        guard searchBar != nil else { return }
        endSearchUI()
    }

    public func handleSearchTotal(_ total: Int?) {
        searchTotal = total
        searchBar?.model.setCounts(total: searchTotal, selected: searchSelected)
    }

    public func handleSearchSelected(_ selected: Int?) {
        searchSelected = selected
        searchBar?.model.setCounts(total: searchTotal, selected: searchSelected)
    }
}
#endif
