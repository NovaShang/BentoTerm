import BentoSessionKit
import BentoFoundationKit
import BentoUISharedKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

// MARK: - TerminalToolbarController: menus and their actions

extension TerminalToolbarController {
    /// Every way to make something new, in one menu: more of this session
    /// (a pane or tmux window), then a new session, a plain shell, or a host
    /// from `~/.ssh/config`.
    ///
    /// Rows that create INSIDE a tmux session (the first row) come from the
    /// shared catalog (`PaneMenuLayout.macNewMenuSessionRows`)
    /// and are dropped on a plain terminal rather than disabled. The level is
    /// spelled out in each title ("New tmux Window", "New Session"): a bare
    /// "Window" reads as a Mac window everywhere else in the OS. Key
    /// equivalents are the menu bar's, shown here as a reminder.
    @objc func newTapped() {
        pop(newMenu(), from: newButton)
    }

    /// The toolbar's ＋ menu.
    func newMenu() -> NSMenu {
        let menu = NSMenu()
        let context = PaneMenuContext(isTmuxPane: !isPlain,
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
        // A plain terminal has no in-session rows, and a menu must not open
        // on a separator.
        if !rows.isEmpty { menu.addItem(.separator()) }
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
        return menu
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
