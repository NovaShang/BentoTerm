import BentoTmuxKit
import BentoFoundationKit
import BentoSessionKit
import BentoUISharedKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

// MARK: - TerminalWindowManager: the toolbar's window strip

extension TerminalWindowManager {
    /// Fill the toolbar's centre strip with the ACTIVE SESSION'S WINDOWS, and
    /// leave sessions to the named button on the left.
    ///
    /// tmux nests session → window → pane, and the strip used to be sessions,
    /// which left the middle level with no permanent home at all: windows
    /// appeared only in Focus mode's sidebar, so in the default view a user's
    /// `prefix-n` / `prefix-1..9` habit had nothing to look at. Mapping the
    /// strip to windows also matches iTerm2's tmux integration (window → tab,
    /// pane → split) — the muscle memory most arrivals bring, since control
    /// mode was built for iTerm2 in the first place.
    ///
    /// One app window therefore shows one session; several projects means
    /// several app windows, which is what ⌘` already switches between.
    func rebuildTabBar() {
        updateTabTitle()
        // The tab bar only knows about sessions that are OPEN, so the left
        // button still lists every session on the machine — a dormant one is
        // otherwise unreachable.
        //
        // Everything below is in KEY space, not name space. A local `foo` and a
        // remote `foo` are two rows here, each labelled for the machine it is
        // on — folding them into one entry by name would show one and silently
        // switch to the other.
        let openIDs = BentoTerminalWindow.openSessionIDs
        let openKeys = Set(openIDs.map(\.key))
        var ids = openIDs
        for local in localServerSessions where !openKeys.contains(local.id.key) {
            ids.append(local.id)
        }
        toolbar.sessions = ids
            .sorted { ($0.isLocal ? 0 : 1, $0.displayName) < ($1.isLocal ? 0 : 1, $1.displayName) }
            .map { id in
                // The poll only describes the LOCAL server, so a remote session
                // gets a name and nothing else — deliberately, see `SessionRow`.
                let local = LocalTmuxSessionName(id)
                return TerminalToolbarController.SessionRow(
                    key: id.key,
                    label: id.displayName,
                    dot: dotImage(for: dot(forSession: id)),
                    isOpen: openKeys.contains(id.key),
                    local: local,
                    info: local.flatMap { BentoTerminalWindow.serverSessionInfo[$0.rawValue] })
            }
        toolbar.activeSessionKey = tab.sessionKey

        let tmuxWindows = tab.viewModel.windows
        let maxVisible = computeMaxVisible()
        var visible = Array(tmuxWindows.prefix(maxVisible))
        // Keep the current window visible even if it would land in the overflow.
        let activeWindowID = activeTab?.viewModel.activeWindowID
        if let activeWindowID, !visible.contains(where: { $0.id == activeWindowID }),
           let current = tmuxWindows.first(where: { $0.id == activeWindowID }), !visible.isEmpty {
            visible[visible.count - 1] = current
        }
        visibleWindows = visible.map(\.id)
        hasOverflow = tmuxWindows.count > visible.count

        // `index:name` is tmux's own label, so what the strip says is what
        // `select-window -t` takes. `key` carries the status so the controller
        // knows when a dot — not just a title — changed.
        var items: [(title: String, key: String, image: NSImage?)] = visible.map { window in
            let vm = activeTab?.viewModel
            let status = vm?.windowStatus(window.id) ?? .idle
            let body = vm?.windowBodyName(window.id) ?? window.name
            let label = window.index.map { "\($0):\(body)" } ?? body
            return (label, status.dotKey, dotImage(for: status))
        }
        if hasOverflow {
            items.append(("", "more", NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More windows")))
        }
        // The centre is shared with the location title. A switcher for ONE window says nothing, and in Focus the
        // sidebar is already the window list — so in both cases that space says
        // where the focused pane is instead.
        let isFocus = tab.viewModel.sessionMode == .list
        toolbar.setCenterShowsTabs(!isFocus && tmuxWindows.count > 1)

        let activeIdx = activeWindowID.flatMap { id in visible.firstIndex { $0.id == id } } ?? -1
        toolbar.updateTabs(items, selected: activeIdx)

        if let active = activeTab {
            let name = displayTitle(for: active)
            window.title = name
            toolbar.setSessionTitle(name)
            toolbar.sizingMode = active.viewModel.sizingMode
            toolbar.sizingOwner = active.viewModel.sizingOwner
            toolbar.sizingOwnerIsMe = active.viewModel.sizingOwnerIsMe
            toolbar.sizeMismatch = active.viewModel.sessionSizeMismatch
        }
    }


    /// Map a visible-segment index to an action: the trailing `⋯` pops the full
    /// window list; any other segment selects that window.
    func segmentPicked(_ idx: Int) {
        if hasOverflow && idx == visibleWindows.count {
            // Pop the overflow list at the cursor, then restore the selection
            // (the `⋯` segment must not stay highlighted).
            overflowMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            rebuildTabBar()
        } else if visibleWindows.indices.contains(idx) {
            activeTab?.viewModel.selectWindow(visibleWindows[idx])
        }
    }

    private enum DotStyle { case filled, ring }

    /// A small status glyph for a segment: a filled disc (live) or a hollow ring
    /// (dormant). Drawn in the window's effective appearance so semantic
    /// label-color (neutral) glyphs resolve to the right light/dark shade.
    private func dotImage(_ color: NSColor, style: DotStyle, diameter d: CGFloat = 7) -> NSImage {
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            switch style {
            case .filled:
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: d, height: d)).fill()
            case .ring:
                let lw: CGFloat = 1.2
                color.setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: lw / 2, y: lw / 2,
                                                       width: d - lw, height: d - lw))
                ring.lineWidth = lw
                ring.stroke()
            }
        }
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    /// The status of a session segment. Two independent dimensions:
    ///   • shape — filled = open as a tab in Bento, hollow ring = exists on the
    ///     machine but not opened here (dormant). This is OUR own connection
    ///     state, not tmux's `session_attached` (which also counts Terminal.app /
    ///     iPhone clients and lags behind the poll).
    ///   • color (filled only) — pane status, highest priority first:
    ///     awaiting (amber) → done-unseen (green) → working (blue) → idle (gray).
    fileprivate enum SessionDot: String { case awaiting, doneUnseen, working, idle, dormant }

    /// What the window, its native tab, and the toolbar's session button call
    /// this session. A remote one reads `name — host`, so two tabs on
    /// same-named sessions on different machines are tellable apart at a
    /// glance, rather than only after clicking one.
    func displayTitle(for tab: SessionTab) -> String {
        let live = tab.viewModel.activeTmuxSessionName ?? tab.id.name
        return TmuxSessionID(server: tab.id.server, name: live).displayName
    }

    /// Put the session name and its status on the native tab.
    ///
    /// A tab title is a plain string, so the dot rides IN it: a pane waiting
    /// on you has to be visible from a background tab, which is the whole point
    /// of the colour language. `NSWindow.tab.attributedTitle` lets it be a real
    /// coloured glyph rather than a letter standing in for one.
    private func updateTabTitle() {
        let name = displayTitle(for: tab)
        window.title = name
        let dot = sessionDot()
        guard let color = tabDotColor(dot) else {
            window.tab.attributedTitle = nil
            return
        }
        let text = NSMutableAttributedString(
            string: "● ", attributes: [.foregroundColor: color])
        text.append(NSAttributedString(
            string: name, attributes: [.foregroundColor: NSColor.labelColor]))
        window.tab.attributedTitle = text
    }

    /// nil = nothing worth colouring (idle), so the tab keeps its
    /// ordinary title rather than wearing a grey dot that means "nothing".
    private func tabDotColor(_ dot: SessionDot) -> NSColor? {
        switch dot {
        case .awaiting:   return PaneState.awaitingInput.nsColor
        case .doneUnseen: return PaneTitleBar.doneColor
        case .working:    return PaneState.working.nsColor
        case .idle, .dormant: return nil
        }
    }

    /// The dot for ANY session name: its own manager's live state when it's
    /// open here, a hollow ring when it only exists on the server.
    private func dot(forSession id: TmuxSessionID) -> SessionDot {
        guard let m = BentoTerminalWindow.manager(for: id.key) else { return .dormant }
        return m.sessionDot()
    }

    fileprivate func sessionDot() -> SessionDot {
        let vm = tab.viewModel
        // Same priority as a window's status (`windowStatus`): something still
        // running outranks something that finished while you were away.
        if vm.panesAwaiting > 0   { return .awaiting }
        if vm.panesWorking > 0    { return .working }
        if vm.panesDoneUnseen > 0 { return .doneUnseen }
        return .idle           // open, no pane status → filled gray
    }

    /// Render a session-dot (memoized). Neutral grays use semantic label colors
    /// so they adapt to light/dark; the status colors are fixed.
    private func dotImage(for dot: SessionDot) -> NSImage {
        let key = "\(dot.rawValue)-\(window.effectiveAppearance.name.rawValue)"
        if let cached = dotImageCache[key] { return cached }
        let img: NSImage
        switch dot {
        case .awaiting:   img = dotImage(PaneState.awaitingInput.nsColor, style: .filled) // yellow
        case .doneUnseen: img = dotImage(PaneTitleBar.doneColor, style: .filled)                       // green
        case .working:    img = dotImage(PaneState.working.nsColor, style: .filled)                    // blue
        case .idle:       img = dotImage(.secondaryLabelColor, style: .filled)                         // attached, idle
        case .dormant:    img = dotImage(.tertiaryLabelColor, style: .ring)                            // not attached
        }
        dotImageCache[key] = img
        return img
    }

    /// How many segments fit before overflowing, from the window width.
    private func computeMaxVisible() -> Int {
        let budget = max(220, window.frame.width - 540)
        return max(1, Int(budget / 110))
    }

    /// The overflow `⋯` menu — every window in this session, the current one
    /// checkmarked, labelled the way `list-windows` labels them.
    private func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        guard let vm = activeTab?.viewModel else { return menu }
        for window in vm.windows {
            let body = vm.windowBodyName(window.id)
            let title = window.index.map { "\($0): \(body)" } ?? body
            let item = NSMenuItem(title: title, action: #selector(overflowPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = window.id
            item.state = (window.id == vm.activeWindowID) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func overflowPicked(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? TmuxWindowID {
            activeTab?.viewModel.selectWindow(id)
        }
    }

    /// Status dot for a window segment, reusing the session-dot rasterizer so
    /// both levels of the hierarchy read with the same colour language.
    private func dotImage(for status: WindowDisplayStatus) -> NSImage {
        switch status {
        case .awaiting:   return dotImage(for: SessionDot.awaiting)
        case .doneUnseen: return dotImage(for: SessionDot.doneUnseen)
        case .working:    return dotImage(for: SessionDot.working)
        case .idle:       return dotImage(for: SessionDot.idle)
        }
    }

    func presentRenameSheet() {
        guard let tab = activeTab else { return }
        Task { [window] in
            guard let name = await window?.askName(SessionPromptCopy.renameSession,
                                                  initial: tab.viewModel.activeTmuxSessionName ?? "")
            else { return }
            tab.viewModel.renameSession(to: name)
        }
    }

    // MARK: - Window strip context menu

    /// The actions for the tmux window under the pointer in the toolbar strip —
    /// the same set the Focus sidebar's rows carry, because it is the same
    /// thing in a different place. nil when that segment holds no window (the
    /// overflow "…" segment, or a strip mid-rebuild).
    func windowMenuItems(forSegment index: Int) -> [NSMenuItem]? {
        guard visibleWindows.indices.contains(index) else { return nil }
        let id = visibleWindows[index]
        let vm = tab.viewModel
        // Name the target at the top. A segment is a small thing to have aimed
        // at, and every item below it acts on a live window.
        let header = NSMenuItem(title: vm.windowDisplayName(id), action: nil, keyEquivalent: "")
        header.isEnabled = false

        let move = NSMenuItem(title: "Move to Session", action: nil, keyEquivalent: "")
        move.submenu = moveToSessionSubmenu(for: id)

        return [
            header,
            .separator(),
            ClosureMenuItem("Rename Window…") { [weak self] in self?.promptRenameWindow(id) },
            move,
            .separator(),
            ClosureMenuItem("Close Window") { [weak self] in self?.confirmCloseWindow(id) },
        ]
    }

    private func moveToSessionSubmenu(for id: TmuxWindowID) -> NSMenu {
        let menu = NSMenu()
        let vm = tab.viewModel
        for name in vm.availableTmuxSessions where name != vm.activeTmuxSessionName {
            menu.addItem(ClosureMenuItem(name) { [weak self] in self?.moveWindow(id, to: name) })
        }
        if menu.items.count > 0 { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem("New Session…") { [weak self] in
            self?.promptMoveToNewSession(id)
        })
        // The list is only as fresh as the last poll; refresh for the next open.
        Task { await vm.refreshTmuxSessions() }
        return menu
    }

    private func promptRenameWindow(_ id: TmuxWindowID) {
        let vm = tab.viewModel
        Task { [window] in
            guard let name = await window?.askName(SessionPromptCopy.renameWindow,
                                                  initial: vm.windowBodyName(id))
            else { return }
            vm.renameWindow(id, to: name)
        }
    }

    private func confirmCloseWindow(_ id: TmuxWindowID) {
        let vm = tab.viewModel
        let copy = SessionPromptCopy.closeWindow(vm.windowDisplayName(id))
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.message ?? ""
        alert.alertStyle = .warning
        alert.addButton(withTitle: copy.confirm)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            vm.closeWindow(id)
        }
    }

    private func promptMoveToNewSession(_ id: TmuxWindowID) {
        Task { [weak self, window] in
            guard let name = await window?.askName(SessionPromptCopy.moveWindowToNewSession)
            else { return }
            // A typed name may match an EXISTING session, so this goes through
            // the same landing pipeline as a menu pick rather than assuming new.
            self?.moveWindow(id, to: name)
        }
    }

    /// Run the move; a target session that hasn't settled into Parallel or Focus
    /// asks where the window should land (same pipeline the sidebar uses — see
    /// `TerminalViewModel.moveWindow`).
    private func moveWindow(_ id: TmuxWindowID, to session: String) {
        let vm = tab.viewModel
        Task { [window] in
            await vm.moveWindow(id, toSession: session) { session in
                await window?.askMoveLanding(session: session)
            }
        }
    }
}

/// An `NSMenuItem` that runs a closure. AppKit menu items are target/action
/// only, and these are built per right-click against a specific tmux window —
/// a shared selector would have to look that window up again from somewhere,
/// which is exactly the indirection that gets the target wrong.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { run() }
}
#endif
