#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

// MARK: - TerminalToolbarController: the centre window strip

extension TerminalToolbarController {
    /// The centre of the toolbar is shared: the window strip when the session
    /// has more than one window, otherwise the focused pane's location title.
    ///
    /// A single-window session is the common case, and a one-item switcher is
    /// chrome that says nothing.
    func setCenterShowsTabs(_ showTabs: Bool) {
        guard let tb = toolbarRef, showTabs != centerShowsTabs || tb.items.isEmpty else { return }
        centerShowsTabs = showTabs
        let want = showTabs ? Self.centerID : Self.locationID
        if let idx = tb.items.firstIndex(where: {
            $0.itemIdentifier == Self.centerID || $0.itemIdentifier == Self.locationID
        }), tb.items[idx].itemIdentifier != want {
            tb.removeItem(at: idx)
            tb.insertItem(withItemIdentifier: want, at: idx)
            tb.centeredItemIdentifiers = [want]
        }
    }

    func configureGroup(_ g: NSToolbarItemGroup) {
        g.selectionMode = .selectOne
        g.controlRepresentation = .expanded
        g.target = self
        g.action = #selector(tabsGroupAction)
        g.label = "Windows"
    }

    /// Refresh the session segments (titles + agent dots) and the selection. The
    /// segmented control is rebuilt (via the `titles:` convenience initializer —
    /// the same path Finder uses, which renders the proper pill-selected segments)
    /// whenever a title OR a dot changes; a selection-only change just moves the
    /// `selectedIndex` in place.
    func updateTabs(_ items: [(title: String, key: String, image: NSImage?)], selected: Int) {
        let sig = items.map { "\($0.title)\u{1}\($0.key)" }
        if sig != currentSig {
            currentSig = sig
            swapGroup(titles: items.map(\.title))
        }
        for (i, sub) in tabsGroup.subitems.enumerated() where i < items.count {
            // Dot images are memoized upstream (same dot + appearance → same
            // instance), so an identity match means nothing to update — skip the
            // assignment rather than dirty the toolbar item every refresh. A
            // fresh group after swapGroup has nil images and always assigns.
            if sub.image !== items[i].image { sub.image = items[i].image }
        }
        if tabsGroup.subitems.indices.contains(selected) { tabsGroup.selectedIndex = selected }
        // The control is rebuilt with the group, so re-find it after AppKit has
        // laid the new one out. Cheap and idempotent (see attachWindowMenu).
        DispatchQueue.main.async { [weak self] in self?.attachWindowMenu() }
    }

    // MARK: - Window segment context menu

    /// Cache the segmented control AppKit renders for the expanded item group.
    ///
    /// It has to be found by walking the title bar's views: `NSToolbarItemGroup`
    /// has no accessor for the control it builds, and the group is swapped
    /// wholesale on every title/dot change. Idempotent; a miss just means no
    /// context menu until the next refresh.
    private func attachWindowMenu() {
        guard centerShowsTabs, let host = hostWindow else { return }
        if let seg = segmentedRef, seg.window === host,
           seg.segmentCount == tabsGroup.subitems.count { return }
        // The theme frame, so the search covers the title bar as well as content.
        guard let root = host.contentView?.superview,
              let seg = Self.findSegmented(in: root, count: tabsGroup.subitems.count)
        else { return }
        segmentedRef = seg
    }

    /// Right-click at `point` (window coordinates) — show that window tab's menu
    /// if the click landed on one. Returns true when handled, so the window can
    /// swallow the event.
    ///
    /// This is driven from `NSWindow.sendEvent` rather than the view's `menu`
    /// property, which looks like the obvious hook and does not work: the
    /// expanded group's control is SwiftUI-backed internally and consumes
    /// `rightMouseDown` without ever consulting `.menu` (measured — an
    /// NSEvent posted into the app's own queue never reached the delegate).
    /// `sendEvent` sees events before dispatch, and `self` is by construction
    /// the window that received the click — so unlike the global monitor this
    /// replaces, there is no way to attribute it to another window.
    func handleRightClick(atWindowPoint point: NSPoint) -> Bool {
        attachWindowMenu()
        guard centerShowsTabs, let seg = segmentedRef, seg.window === hostWindow else { return false }
        guard seg.convert(seg.bounds, to: nil).contains(point) else { return false }
        guard let host = hostWindow else { return false }
        guard let index = segmentIndex(in: seg, screenPoint: host.convertPoint(toScreen: point)),
              let items = onWindowMenu?(index), !items.isEmpty
        else {
            // Landed on the strip but not on a window (the overflow "…", or a
            // strip mid-rebuild). Swallow it: the stock toolbar menu is not
            // something to fall back to, and acting on a neighbouring window
            // would be worse than doing nothing.
            return true
        }
        let menu = NSMenu()
        for item in items { menu.addItem(item) }
        menu.popUp(positioning: nil, at: seg.convert(point, from: nil), in: seg)
        return true
    }

    private static func findSegmented(in view: NSView, count: Int) -> NSSegmentedControl? {
        if let s = view as? NSSegmentedControl, s.segmentCount == count, count > 1 { return s }
        for sub in view.subviews {
            if let found = findSegmented(in: sub, count: count) { return found }
        }
        return nil
    }

    /// Which segment the pointer is over, in screen coordinates.
    ///
    /// `NSSegmentedControl` publishes no point→segment API, and the three
    /// obvious substitutes are all dead ends here (measured, not assumed):
    /// `width(forSegment:)` reports 0 because the control is SwiftUI-backed
    /// internally, the view's `accessibilityChildren` is just its cell, and
    /// there is no `rectForSegment:`. The CELL, though, publishes one
    /// `NSAccessibilitySegment` per segment carrying a real screen frame, in
    /// order and non-overlapping — AppKit's own geometry rather than a
    /// reconstruction of it.
    ///
    /// Every assumption is rechecked on each call and any mismatch returns nil.
    /// This menu can close a window, and the last time something in the title
    /// bar acted on a target the user hadn't pointed at, it killed a live
    /// session — so guessing is not on the table.
    private func segmentIndex(in seg: NSSegmentedControl, screenPoint: NSPoint) -> Int? {
        guard let cell = seg.cell else { return nil }
        let kids = (cell as AnyObject).accessibilityChildren?() ?? []
        guard kids.count == seg.segmentCount else { return nil }
        for (i, kid) in kids.enumerated() {
            guard let frame = (kid as AnyObject).accessibilityFrame?() else { continue }
            if frame.contains(screenPoint) { return i }
        }
        return nil
    }

    /// Rebuild the group with the convenience initializer and re-insert it into
    /// the toolbar (the only way to get Finder's exact segmented appearance — a
    /// hand-built `subitems` array renders as faint plain text instead).
    private func swapGroup(titles: [String]) {
        let g = NSToolbarItemGroup(
            itemIdentifier: Self.centerID,
            titles: titles.isEmpty ? [""] : titles,
            selectionMode: .selectOne,
            labels: nil,
            target: self,
            action: #selector(tabsGroupAction))
        g.controlRepresentation = .expanded
        g.label = "Windows"
        tabsGroup = g
        guard centerShowsTabs, let tb = toolbarRef,
              let idx = tb.items.firstIndex(where: { $0.itemIdentifier == Self.centerID })
        else { return }
        tb.removeItem(at: idx)
        tb.insertItem(withItemIdentifier: Self.centerID, at: idx)
    }

    @objc private func tabsGroupAction() { onSelectSegment?(tabsGroup.selectedIndex) }
}
#endif
