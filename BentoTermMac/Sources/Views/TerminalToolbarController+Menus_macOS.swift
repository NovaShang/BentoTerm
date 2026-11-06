import BentoSessionKit
import BentoFoundationKit
import BentoUISharedKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

// MARK: - TerminalToolbarController: menus and their actions

extension TerminalToolbarController {
    /// Check for Updates… is greyed while the updater can't check (a debug
    /// build has none; Sparkle is mid-check). Everything else is always on.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdatesAction) { return AppUpdater.shared.canCheck }
        return true
    }

    @objc func sessionMenuTapped() {
        pop(sessionActionsMenu(), from: sessionsButton)
    }

    /// The session switcher plus this session's actions, behind the named left
    /// button. Window switching lives in the centre strip and window creation in
    /// the New menu, so neither is duplicated here.
    func sessionActionsMenu() -> NSMenu {
        let menu = NSMenu()
        // The tab bar switches between OPEN sessions; this list covers the rest
        // — picking one moves this window onto it.
        sessionSwitchSection(menu)
        // A plain (no-tmux) terminal has no session/windows — just close it.
        if activeTabIsPlain {
            add(menu, "Close Terminal", #selector(closeTabAction))
            appSection(menu)
            return menu
        }
        add(menu, "Rename Session…", #selector(renameAction))
        // Only when something has fixed the size: taking it over is the
        // banner's job, and the default needs no row.
        if sizingMode.offersRelease {
            let release = NSMenuItem(title: TerminalSizingMode.releaseTitle,
                                     action: #selector(releaseSizeAction), keyEquivalent: "")
            release.target = self
            release.image = NSImage(systemSymbolName: TerminalSizingMode.releaseSymbol,
                                    accessibilityDescription: TerminalSizingMode.releaseTitle)
            release.toolTip = sizingMode.releaseNote(owner: sizingOwner, ownerIsMe: sizingOwnerIsMe)
            menu.addItem(release)
        }
        menu.addItem(.separator())
        add(menu, "Detach (keep running)", #selector(detachAction))  // unload; session survives
        // Destructive, and one row away from Detach — which is its harmless
        // twin — so a separator keeps them from being adjacent targets.
        menu.addItem(.separator())
        add(menu, "Kill Session", #selector(killAction))
        menu.items.last?.image = NSImage(systemSymbolName: "xmark.octagon", accessibilityDescription: nil)
        menu.items.last?.keepingImageVisible()
        // No "Close Window" here: next to ⇧⌘W (which closes the MAC window and
        // leaves the session running) a row that killed the tmux window read
        // as the same thing. Killing a window lives on the strip and the
        // sidebar, beside the window it kills.
        //
        // No window SWITCH list here any more: windows own the centre strip, so
        // duplicating them in this menu would give the same thing two homes and
        // leave the user unsure which one is authoritative.
        appSection(menu)
        return menu
    }

    /// The app's own rows, last: this button is the one menu every window has
    /// in the same place, so it doubles as the app menu for people who never
    /// look at the menu bar.
    ///
    /// ⌘, is shown as a hint only. This menu is a popup, not part of the main
    /// menu, so its key equivalent never competes with the real Settings item
    /// (which `AppDelegate.openSettings` finds by that very shortcut).
    private func appSection(_ menu: NSMenu) {
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsAction),
                                  keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.keepingImageVisible()
        menu.addItem(settings)
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesAction),
                                 keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        add(menu, "About BentoTerm", #selector(aboutAction))
    }

    /// Every session on the machine. Picking one moves this window onto it
    /// (`switch-client`); one already open in another window comes forward
    /// instead. The app is single-window by default, so a session pick is a
    /// switch, not a new tab — "Open in New Window" (or ⌥) is the explicit
    /// way to keep both.
    private func sessionSwitchSection(_ menu: NSMenu) {
        guard !sessions.isEmpty else { return }
        let header = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for session in sessions {
            let item = NSMenuItem(title: sessionRowTitle(session),
                                  action: #selector(selectSessionAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = session.key
            item.image = session.dot
            item.keepingImageVisible()
            item.state = (session.key == activeSessionKey) ? .on : .off
            if let sub = sessionRowSubmenu(session) {
                // An item with a submenu no longer fires its own action in
                // AppKit (unlike the SwiftUI `Menu … primaryAction:` this shape
                // came from), so the submenu leads with the action the row used
                // to perform. Clicking the row still costs nothing extra — it
                // opens the submenu, and the thing you wanted is the first item.
                item.submenu = sub
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    /// `name  ·  2 windows  ·  5m ago`, via the shared launcher phrasing so this
    /// menu and the launcher describe a session the same way. A remote session
    /// (no local poll info) is just its name — all we can honestly say about it.
    private func sessionRowTitle(_ session: SessionRow) -> String {
        if let subtitle = session.info?.subtitle() {
            return "\(session.label)  ·  \(subtitle)"
        }
        return session.label
    }

    /// A session's own actions, reachable WITHOUT switching to it first — which
    /// is the point: renaming or killing a session you are not in used to mean
    /// opening it, acting, and closing it again.
    ///
    /// Windows are listed for other sessions only. For the ACTIVE session the
    /// centre strip already owns its windows, and duplicating them here would
    /// give the same thing two homes; for a session you are not in, nothing else
    /// can reach them at all.
    private func sessionRowSubmenu(_ session: SessionRow) -> NSMenu? {
        // Local sessions only — see `SessionRow.info`.
        guard let local = session.local, let info = session.info else { return nil }
        let sub = NSMenu()
        let isActive = session.key == activeSessionKey

        let primary = NSMenuItem(
            title: session.isOpen && !isActive ? "Show Its Window" : "Switch to This Session",
            action: #selector(selectSessionAction(_:)), keyEquivalent: "")
        primary.target = self
        primary.representedObject = session.key
        primary.isEnabled = !isActive
        sub.addItem(primary)
        // The explicit second window. Not offered where it would only front a
        // window that is already there.
        if !session.isOpen {
            let newWindow = NSMenuItem(title: "Open in New Window",
                                       action: #selector(openSessionInNewWindowAction(_:)),
                                       keyEquivalent: "")
            newWindow.target = self
            newWindow.representedObject = session.key
            sub.addItem(newWindow)
        }

        if !isActive, !info.windows.isEmpty {
            sub.addItem(.separator())
            let header = NSMenuItem(title: "Windows", action: nil, keyEquivalent: "")
            header.isEnabled = false
            sub.addItem(header)
            for window in info.windows {
                let it = NSMenuItem(title: window.label,
                                    action: #selector(openSessionWindowAction(_:)),
                                    keyEquivalent: "")
                it.target = self
                it.representedObject = [session.key, window.index] as [Any]
                it.image = NSImage(systemSymbolName: window.isActive ? "circle.fill" : "circle",
                                   accessibilityDescription: nil)
                sub.addItem(it)
            }
        }

        sub.addItem(.separator())
        let rename = NSMenuItem(title: "Rename Session…",
                                action: #selector(renameNamedSessionAction(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = local
        sub.addItem(rename)
        sub.addItem(.separator())
        let kill = NSMenuItem(title: "Kill Session",
                              action: #selector(killNamedSessionAction(_:)), keyEquivalent: "")
        kill.target = self
        kill.representedObject = local
        kill.image = NSImage(systemSymbolName: "xmark.octagon", accessibilityDescription: nil)
        kill.keepingImageVisible()
        sub.addItem(kill)
        return sub
    }

    @objc private func openSessionWindowAction(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any], pair.count == 2,
              let key = pair[0] as? String, let index = pair[1] as? Int,
              let id = TmuxSessionID(key: key) else { return }
        BentoTerminalWindow.focusOrOpen(id, windowIndex: index)
    }

    @objc private func renameNamedSessionAction(_ sender: NSMenuItem) {
        guard let local = sender.representedObject as? LocalTmuxSessionName else { return }
        guard let newName = promptRename(current: local.rawValue) else { return }
        Task { try? await TmuxCLI.rename(session: local, to: newName) }
    }

    @objc private func killNamedSessionAction(_ sender: NSMenuItem) {
        guard let local = sender.representedObject as? LocalTmuxSessionName else { return }
        // Confirm here specifically. Everywhere else in Bento quitting or
        // closing is a DETACH — the session survives — so this is the one action
        // that actually destroys running processes, and from this menu it can be
        // aimed at a session that isn't even on screen.
        guard confirmKill(session: local.rawValue) else { return }
        Task { try? await TmuxCLI.kill(session: local) }
    }

    @objc private func selectSessionAction(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        if NSEvent.modifierFlags.contains(.option) {
            onOpenSessionInNewWindow?(key)
        } else {
            onSelectSession?(key)
        }
    }

    @objc private func openSessionInNewWindowAction(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        onOpenSessionInNewWindow?(key)
    }

    /// Every way to make something new, in one menu: more of this session
    /// (a pane or tmux window, an agent), then a new session, a plain shell, or
    /// a host from `~/.ssh/config`.
    ///
    /// Rows that create INSIDE a tmux session (the first row and Recent Agents)
    /// come from the shared catalog (`PaneMenuLayout.macNewMenuSessionRows`)
    /// and are dropped on a plain terminal rather than disabled. The level is
    /// spelled out in each title ("New tmux Window", "New Session"): a bare
    /// "Window" reads as a Mac window everywhere else in the OS. Key
    /// equivalents are the menu bar's, shown here as a reminder.
    @objc func newTapped() {
        let menu = NSMenu()
        let context = PaneMenuContext(isTmuxPane: !activeTabIsPlain,
                                      sessionMode: sessionMode ?? .tiled)
        let rows = PaneMenuLayout.macNewMenuSessionRows(context)
        for row in rows {
            guard case .command(let command) = row else { continue }
            let item = plainItem(symbol: command.symbol(on: .macNewMenu),
                                 title: command.title(on: .macNewMenu),
                                 tip: command.tip(on: .macNewMenu) ?? "",
                                 action: #selector(newPaneOrWindowAction))
            item.keyEquivalent = "n"
            item.keyEquivalentModifierMask = .command
            menu.addItem(item.keepingImageVisible())
        }
        menu.addItem(plainItem(symbol: LaunchAction.agentSession.systemImage, title: "New Agent…",
                               tip: LaunchAction.agentSession.detail,
                               action: #selector(newAgentAction)).keepingImageVisible())
        if rows.contains(.recentAgents) {
            // The agent you already had open in that repo, split in beside this
            // pane. Dispatched through the responder chain like the other pane
            // actions, so it lands on the active tab's pane host.
            let recents = GhosttyTiledPaneHost.recentAgentItems(
                host: launchHost, target: self, action: #selector(splitRecentAction(_:)))
            if !recents.isEmpty {
                let header = NSMenuItem(title: "Recent Agents", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                recents.forEach { menu.addItem($0) }
            }
        }

        menu.addItem(.separator())
        let session = plainItem(symbol: LaunchAction.emptySession.systemImage, title: "New Session",
                                tip: "A new tmux session in a window of its own.",
                                action: #selector(newSessionAction))
        session.keyEquivalent = "n"
        session.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(session.keepingImageVisible())
        menu.addItem(plainItem(symbol: LaunchAction.plainTerminal.systemImage,
                               title: "New Plain Terminal",
                               tip: LaunchAction.plainTerminal.detail,
                               action: #selector(newPlainTerminalAction)).keepingImageVisible())
        menu.addItem(SSHHostMenu.item(target: self,
                                      remoteTmux: #selector(remoteSessionAction(_:)),
                                      shell: #selector(sshShellAction(_:))).keepingImageVisible())

        pop(menu, from: newButton)
    }

    /// A one-line row: symbol, title, and the explanation on hover.
    private func plainItem(symbol: String?, title: String, tip: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
        if !tip.isEmpty { item.toolTip = tip }
        return item
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func pop(_ menu: NSMenu, from button: NSView) {
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        }
    }

    // MARK: - Actions

    @objc private func newPaneOrWindowAction() { BentoTerminalWindow.newPaneOrWindow() }
    @objc private func newAgentAction() { BentoTerminalWindow.onNewAgentSession?() }
    @objc private func newSessionAction() { BentoTerminalWindow.newSessionWindow() }
    @objc private func newPlainTerminalAction() { BentoTerminalWindow.newWindowNoTmux() }
    @objc private func sshShellAction(_ sender: NSMenuItem) {
        if let host = sender.representedObject as? String { BentoTerminalWindow.newSSHWindow(host: host) }
    }
    /// A session on an ssh host, or a new one there. A new one is numbered
    /// against what the host was last seen running, so it can't silently
    /// attach to a `bento-2` that already exists there.
    @objc private func remoteSessionAction(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? SSHHostMenu.RemoteSessionPick else { return }
        let name = pick.session ?? {
            let there = (try? RemoteTmuxSessions.cached(pick.host)?.get())?.map(\.name) ?? []
            return TmuxSessionNaming.numbered(BentoTerminalWindow.defaultSessionName, existing: Set(there))
        }()
        RemoteTmuxSessions.invalidate(pick.host)
        BentoTerminalWindow.focusOrOpen(TmuxSessionID.ssh(host: pick.host, name: name))
    }
    @objc private func closeTabAction() { onCloseTab?() }
    @objc private func settingsAction() { AppDelegate.openSettings() }
    @objc private func checkForUpdatesAction() { AppUpdater.shared.checkForUpdates() }
    @objc private func aboutAction() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    /// Forwarded with the menu item as the sender, because the record it
    /// carries IS the argument.
    @objc private func splitRecentAction(_ sender: Any?) {
        BentoPaneAction.dispatch(BentoPaneAction.splitRecent, from: sender)
    }
    @objc private func renameAction() { onRenameSession?() }
    @objc private func detachAction() { onDetach?() }
    @objc private func releaseSizeAction() { onReleaseSize?() }
    @objc private func killAction() { onKillSession?() }
}

// MARK: - Menu images

extension NSMenuItem {
    /// macOS 27 hides SF Symbol images in menus unless a row asks to keep its
    /// image. Only the rows whose icon carries meaning ask: creation rows,
    /// status dots, Settings, splits and destructive rows. Everything else is
    /// text-only, which is the system's default for a reason.
    @discardableResult
    func keepingImageVisible() -> NSMenuItem {
        preferredImageVisibility = .visible
        return self
    }
}
#endif
