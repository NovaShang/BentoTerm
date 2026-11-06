import BentoTmuxKit
import BentoFoundationKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoSessionKit
import BentoUISharedKit

// MARK: - Pane menu (title-bar ⌄ button + the surface's right-click menu)

extension GhosttyTiledPaneHost {
    /// Pop up a per-pane context menu (split / zoom / close) anchored to the
    /// title-bar menu button. The pane is already selected, so the existing
    /// responder-chain actions operate on it.
    func showPaneMenu(for paneID: TmuxPaneID, from anchor: NSView) {
        let menu = NSMenu()
        for item in paneMenuItems(for: paneID) { menu.addItem(item) }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: anchor.bounds.maxY),
                   in: anchor)
    }

    /// Every pane action, in menu order — the title bar's ⌄ button and the
    /// surface's right-click menu both build from this, so the two cannot drift
    /// into offering different things (they did: right-click had none of it,
    /// and Focus mode has no title bar to fall back to).
    ///
    /// Rebuilt per open: zoom state, session mode and the session list all
    /// change under the user.
    func paneMenuItems(for paneID: TmuxPaneID) -> [NSMenuItem] {
        let menu = NSMenu()
        // No session-level entries: this menu is about one pane.
        let zoomed = (viewModel.zoomedPaneID == paneID)
        // Rows, order and words come from the shared catalog (PaneMenuLayout):
        // splits only in Parallel — Focus creates via the sidebar's New Window,
        // and the ⌘D actions no-op there the same way.
        let context = PaneMenuContext(sessionMode: viewModel.sessionMode, zoomed: zoomed)
        let rows = PaneMenuLayout.macPaneMenu(context)
        for row in rows {
            switch row {
            case .command(let command):
                guard let action = Self.paneMenuSelector(command) else { continue }
                let row = item(command.title(on: .macPaneMenu, zoomed: zoomed), action,
                               symbol: command.symbol(on: .macPaneMenu, zoomed: zoomed))
                // macOS 27 hides menu images by default; the splits and the
                // destructive row keep theirs (see `keepingImageVisible`).
                if Self.paneMenuRowsWithImages.contains(command) { row.keepingImageVisible() }
                menu.addItem(row)
            case .separator:
                menu.addItem(.separator())
            case .recentAgents:
                // The agents you've had open lately, ready to split off again.
                // Nothing remembered yet → no separator either: a "Recent
                // Agents" header over an empty stretch reads as broken.
                let recents = Self.recentAgentItems(host: viewModel.launchHost, target: self,
                                                    action: #selector(splitRecentLaunch(_:)))
                if !recents.isEmpty {
                    menu.addItem(.separator())
                    let header = NSMenuItem(title: "Recent Agents", action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                    recents.forEach { menu.addItem($0) }
                }
            case .layouts:
                menu.addItem(layoutMenuItem())
            case .moveToSession:
                menu.addItem(makeMoveToSessionItem())
            case .paste:
                break   // iOS-only row; the Mac pastes from Edit and right-click.
            }
        }
        // Detached so the caller can splice them into a menu it owns. An
        // NSMenuItem may belong to only one menu at a time, which is also why
        // this is rebuilt per open rather than cached.
        let items = menu.items
        for it in items { menu.removeItem(it) }
        return items
    }

    static let paneMenuRowsWithImages: Set<PaneCommand> = [
        .splitRight, .splitDown, .splitDuplicate, .splitPathCommand, .closePane,
    ]

    /// How the Mac performs a catalog command: the responder-chain selectors
    /// the menu bar uses too. nil = not a pane-menu action on this platform.
    static func paneMenuSelector(_ command: PaneCommand) -> Selector? {
        switch command {
        case .splitRight: return BentoPaneAction.splitVertically
        case .splitDown: return BentoPaneAction.splitHorizontally
        case .splitDuplicate: return BentoPaneAction.splitDuplicate
        case .splitPathCommand: return BentoPaneAction.splitPathCommand
        case .zoom: return BentoPaneAction.toggleZoom
        case .closePane: return BentoPaneAction.closePane
        // ⌘N's route: `BentoTerminalWindow.newPaneOrWindow`, not a pane action.
        case .newPane, .newTmuxWindow: return nil
        case .find: return BentoPaneAction.findInPane
        case .exitCopyMode: return nil
        }
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

    static var tmuxLayouts: [TmuxNamedLayout] { TmuxNamedLayout.all }

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

    /// Rows for the remembered agents on `host` (the session's `launchHost`),
    /// for whichever menu is asking. Empty when nothing has been remembered
    /// there yet, and the caller drops the separator with it — a lone "Recent
    /// Agents" header over nothing reads as broken.
    static func recentAgentItems(host: String?, target: AnyObject?, action: Selector) -> [NSMenuItem] {
        LaunchRecents.shared.agentLaunches(host: host).map { record in
            let item = NSMenuItem(title: "\(record.command)  ·  \(tildeAbbreviated(record.dir))",
                                  action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = record
            item.image = NSImage(systemSymbolName: "clock.arrow.circlepath",
                                 accessibilityDescription: nil)
            return item
        }
    }
}
#endif
