import BentoTmuxKit
import BentoFoundationKit
import BentoSessionKit
import BentoUISharedKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

// MARK: - TerminalWindowManager: the session sidebar

/// The sidebar is the window's navigator: every tmux session on this Mac (and
/// on the ssh hosts open in Bento), each opening to its windows. It is the
/// user's to show or hide (the toolbar's sidebar button, View → Show Sidebar,
/// ⌃⌘S), in either layout mode. While it is shown it IS the switcher, so the
/// toolbar's window strip and the session menu's list step aside.
extension TerminalWindowManager {
    /// The last choice, for every window: shown unless the user put it away.
    nonisolated static let sidebarShownKey = "mac_sidebar_shown"

    static var sidebarPreferred: Bool {
        UserDefaults.standard.object(forKey: sidebarShownKey) as? Bool ?? true
    }

    /// Fill the sidebar from what this process knows: sessions open in a Bento
    /// window are read live from their view models; the rest of this Mac's come
    /// from the 5 s `tmux` poll; another host's from its window's session list.
    func rebuildSidebar() {
        // A plain terminal is no session's window, though its key (a host alias,
        // say) can read the same as one's.
        let currentKey = tab.isPlain ? "" : tab.sessionKey
        var sections: [SidebarSection] = []

        // This Mac: the poll's sessions plus any open here the poll hasn't
        // caught yet (it runs every 5 s).
        var localIDs = localServerSessions.map(\.id)
        for id in BentoTerminalWindow.openSessionIDs where id.isLocal && !localIDs.contains(id) {
            localIDs.append(id)
        }
        sections.append(section(id: "local", title: "This Mac", ids: localIDs, currentKey: currentKey))

        // Each ssh host a Bento window is attached to: its session list comes
        // over that window's own control channel.
        var remoteServers: [TmuxServer] = []
        for id in BentoTerminalWindow.openSessionIDs where !id.isLocal && !remoteServers.contains(id.server) {
            remoteServers.append(id.server)
        }
        // By name: what is on show changes, and the groups mustn't move under
        // the pointer.
        remoteServers.sort { ($0.sshHost ?? "").localizedStandardCompare($1.sshHost ?? "") == .orderedAscending }
        for server in remoteServers {
            var names: [String] = []
            for id in BentoTerminalWindow.openSessionIDs where id.server == server {
                if !names.contains(id.name) { names.append(id.name) }
                if let open = BentoTerminalWindow.tab(for: id.key) {
                    for n in open.viewModel.availableTmuxSessions where !names.contains(n) { names.append(n) }
                }
            }
            let ids = names.map { TmuxSessionID(server: server, name: $0) }
            let host = server.sshHost ?? "Remote"
            sections.append(section(id: "ssh:\(host)", title: host, ids: ids, currentKey: currentKey))
        }
        // The plain terminals open in this window.
        let terminals = tabs.filter(\.isPlain).sorted { $0.windowTitle.localizedStandardCompare($1.windowTitle) == .orderedAscending }
        if !terminals.isEmpty {
            sections.append(SidebarSection(id: "terminals", title: "Terminals", sessions: terminals.map {
                SidebarSessionRow(key: $0.plainRowKey, name: $0.windowTitle, subtitle: "A shell without tmux",
                                  waiting: 0, panes: [], isCurrent: $0 === tab, isLocal: true,
                                  isOpenElsewhere: false, isPlain: true)
            }))
        }

        if sidebarModel.sections != sections { sidebarModel.sections = sections }
        let canRelease = tab.viewModel.sizingMode.offersRelease
        if sidebarModel.canReleaseSize != canRelease { sidebarModel.canReleaseSize = canRelease }
        // While split the session row is what's on screen; with one pane shown
        // alone, that pane's row.
        let vm = tab.viewModel
        let selected: SidebarItemID = tab.isPlain ? .session(tab.plainRowKey) : vm.sessionMode == .list
            ? vm.activePaneID.map { .pane(session: currentKey, pane: "\($0)") } ?? .session(currentKey)
            : .session(currentKey)
        if sidebarModel.selection != selected { sidebarModel.selection = selected }
    }

    private func section(id: String, title: String, ids: [TmuxSessionID],
                         currentKey: String) -> SidebarSection {
        // Stable order — a list that re-sorts by activity moves under the
        // pointer. tmux's `ls` is by name too.
        let rows = ids
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { sessionRow($0, currentKey: currentKey) }
        return SidebarSection(id: id, title: title, sessions: rows)
    }

    private func sessionRow(_ id: TmuxSessionID, currentKey: String) -> SidebarSessionRow {
        let isCurrent = id.key == currentKey
        let local = LocalTmuxSessionName(id)
        let info = local.flatMap { BentoTerminalWindow.serverSessionInfo[$0.rawValue] }
        let home = NSHomeDirectory()
        let remote = id.server.sshHost
        // Live wherever a Bento window has it: names, status and "done, unseen"
        // follow the control channel instead of lagging a poll behind.
        if let open = isCurrent ? tab : BentoTerminalWindow.tab(for: id.key) {
            let vm = open.viewModel
            let byWindow = vm.panesByWindow
            let polledPanes = info?.windows.flatMap(\.panes) ?? []
            let panes = vm.sessionPanes.map { pane -> SidebarPaneRow in
                let window = pane.windowID.flatMap { w in vm.windows.first { $0.id == w } }
                let sole = pane.windowID.flatMap { byWindow[$0]?.count == 1 ? $0 : nil }
                let path = vm.paneWorkingDirectories[pane.id]
                    ?? polledPanes.first { $0.id == "\(pane.id)" }?.path
                return SidebarPaneRow(
                    sessionKey: id.key, paneID: "\(pane.id)", windowIndex: window?.index,
                    soleWindow: sole,
                    name: SidebarText.paneName(title: pane.title, command: pane.currentCommand, path: path,
                                               windowName: sole != nil ? window?.name : nil,
                                               home: home, remoteHost: remote),
                    detail: SidebarText.paneDetail(command: pane.currentCommand, path: path,
                                                   home: home, remoteHost: remote),
                    status: vm.paneDisplayStatus(pane.id))
            }
            return SidebarSessionRow(
                key: id.key, name: vm.activeTmuxSessionName ?? id.name,
                subtitle: SidebarText.paneCount(panes.count),
                waiting: vm.panesAwaiting, panes: panes,
                isCurrent: isCurrent, isLocal: id.isLocal, isOpenElsewhere: sessionTab(id.key) == nil,
                isOpenHere: sessionTab(id.key) != nil)
        }
        guard let info else {
            // Another host's session we only know the name of.
            return SidebarSessionRow(key: id.key, name: id.name, subtitle: remote ?? "",
                                     waiting: 0, panes: [], isCurrent: false,
                                     isLocal: id.isLocal, isOpenElsewhere: false)
        }
        let panes = info.windows.flatMap { w in
            w.panes.map { p in
                SidebarPaneRow(
                    sessionKey: id.key, paneID: p.id, windowIndex: w.index, soleWindow: nil,
                    name: SidebarText.paneName(title: p.title, command: p.command, path: p.path,
                                               windowName: w.panes.count == 1 ? w.name : nil,
                                               home: home, remoteHost: nil),
                    detail: SidebarText.paneDetail(command: p.command, path: p.path, home: home, remoteHost: nil),
                    status: p.status)
            }
        }
        return SidebarSessionRow(
            key: id.key, name: id.name, subtitle: SidebarText.paneCount(panes.count),
            waiting: info.windows.reduce(0) { $0 + $1.awaitingCount }, panes: panes,
            isCurrent: false, isLocal: true, isOpenElsewhere: false)
    }

    // MARK: Picks

    func wireSidebar() {
        let model = sidebarModel
        model.onSelectSession = { [weak self] row in self?.sidebarPickedSession(row) }
        model.onSelectPane = { [weak self] row in self?.sidebarPickedPane(row) }
        model.onOpenInNewWindow = { row in
            if let id = TmuxSessionID(key: row.key) { BentoTerminalWindow.openInNewWindow(id) }
        }
        model.onRenameSession = { [weak self] row in self?.sidebarRename(row) }
        model.onKillSession = { [weak self] row in self?.sidebarKill(row) }
        model.onDetachSession = { [weak self] row in
            guard let self, let open = self.sessionTab(row.key) else { return }
            self.close(open)
        }
        model.onCloseTerminal = { [weak self] row in
            guard let self, let t = self.tabs.first(where: { $0.isPlain && $0.plainRowKey == row.key }) else { return }
            self.close(t)
        }
        model.onReleaseSize = { [weak self] in self?.releaseSize() }
    }

    /// A session row: its panes, split side by side.
    private func sidebarPickedSession(_ row: SidebarSessionRow) {
        if row.isPlain {
            if let t = tabs.first(where: { $0.isPlain && $0.plainRowKey == row.key }) { show(t) }
        } else if row.isCurrent {
            showSplit()
        } else if let id = TmuxSessionID(key: row.key) {
            BentoTerminalWindow.focusOrOpen(id) { $0.showSplit() }
        }
    }

    /// A pane row: that pane alone.
    private func sidebarPickedPane(_ row: SidebarPaneRow) {
        if !tab.isPlain, row.sessionKey == tab.sessionKey {
            showAlone(pane: row.paneID)
        } else if let id = TmuxSessionID(key: row.sessionKey) {
            BentoTerminalWindow.focusOrOpen(id) { $0.showAlone(pane: row.paneID) }
        }
    }

    /// Gather the panes back into one split window (the structure `Parallel`
    /// used to name). Lossless: the layout they were split in comes back.
    func showSplit() {
        requestMode(.tiled)
        returnFocusToTerminal()
    }

    /// Show one pane alone: every pane gets a window of its own (what
    /// `Focus` used to name) and this one's comes forward. Once spread,
    /// moving between panes is only `select-window` — nothing is redrawn.
    ///
    /// A session built outside Bento with windows AND splits isn't flattened
    /// to do this (that can't be undone exactly): the pane's window comes
    /// forward with the pane selected in it.
    func showAlone(pane raw: String) {
        let vm = tab.viewModel
        Task { [weak self] in
            guard let target = vm.sessionPanes.first(where: { "\($0.id)" == raw }) else { return }
            if !vm.isMixedStructure, vm.sessionMode != .list {
                guard await vm.requestMode(.list) else { return }
            }
            if let window = vm.sessionPanes.first(where: { $0.id == target.id })?.windowID,
               window != vm.activeWindowID {
                vm.selectWindow(window)
            }
            if vm.activePaneID != target.id { vm.selectPane(target.id) }
            self?.rebuildSidebar()
            self?.returnFocusToTerminal()
        }
    }

    /// A pick is navigation, not a reason to keep the keyboard in the list:
    /// typing goes to the terminal you just landed in.
    private func returnFocusToTerminal() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let host = self.tab.paneHost else { return }
            host.updateActiveBorders()
        }
    }

    private func sidebarRename(_ row: SidebarSessionRow) {
        if row.isCurrent {
            presentRenameSheet()
            return
        }
        guard let local = TmuxSessionID(key: row.key).flatMap(LocalTmuxSessionName.init) else { return }
        Task { [window] in
            guard let name = await window?.askName(SessionPromptCopy.renameSession, initial: row.name)
            else { return }
            try? await TmuxCLI.rename(session: local, to: name)
            BentoTerminalWindow.onLocalServerChanged?()
        }
    }

    private func sidebarKill(_ row: SidebarSessionRow) {
        guard let window else { return }
        let copy = SessionPromptCopy.killSession(row.name)
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.message ?? ""
        alert.alertStyle = .warning
        let kill = alert.addButton(withTitle: copy.confirm)
        alert.addButton(withTitle: "Cancel")
        kill.keyEquivalent = ""
        kill.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            // Over its own connection where there is one: killed from outside,
            // that connection would see the session vanish under it.
            if let m = BentoTerminalWindow.manager(for: row.key), let open = m.sessionTab(row.key) {
                m.performKillSession(tab: open)
            } else if let local = TmuxSessionID(key: row.key).flatMap(LocalTmuxSessionName.init) {
                Task {
                    try? await TmuxCLI.kill(session: local)
                    BentoTerminalWindow.onLocalServerChanged?()
                }
            }
        }
    }
}
#endif
