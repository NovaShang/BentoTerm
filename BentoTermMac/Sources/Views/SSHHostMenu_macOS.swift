import BentoSessionKit
import BentoFoundationKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

// MARK: - The ~/.ssh/config menu

/// The ＋ menu's `SSH ▸`: one submenu per host from `~/.ssh/config`, each
/// listing the tmux sessions running there, then New tmux Session and a plain
/// shell.
///
/// Hosts are re-read from `~/.ssh/config` every time the ＋ menu is built, so
/// edits show up without a relaunch; that read is one small local file. The
/// one network read is a host's session list, fetched when its submenu opens
/// (`RemoteSessionsMenuFiller`).
@MainActor
enum SSHHostMenu {
    static let title = "SSH"
    static let tip = "A host from your ~/.ssh/config: a tmux session on it, or a plain shell."

    /// What a session row carries: `session` nil = a new session.
    struct RemoteSessionPick {
        let host: String
        let session: String?
    }

    /// The submenus' delegates. `NSMenu.delegate` is weak, so something has to
    /// hold them for as long as the menu can open; replaced per build.
    private static var fillers: [RemoteSessionsMenuFiller] = []

    /// The `SSH ▸` row. `remoteTmux` gets a `RemoteSessionPick` as
    /// `representedObject`; `shell` gets the host alias.
    static func item(target: AnyObject, remoteTmux: Selector, shell: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "network", accessibilityDescription: title)
        item.toolTip = tip
        let hosts = SSHConfigHosts.hosts()
        let menu = NSMenu()
        fillers = []
        if hosts.isEmpty {
            // A missing or unreadable config lands here too.
            let none = NSMenuItem(title: "No hosts in ~/.ssh/config", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for host in hosts {
            let row = NSMenuItem(title: host, action: nil, keyEquivalent: "")
            let filler = RemoteSessionsMenuFiller(host: host, target: target,
                                                  pick: remoteTmux, shell: shell)
            let sessions = NSMenu()
            sessions.delegate = filler
            fillers.append(filler)
            row.submenu = sessions
            menu.addItem(row)
        }
        item.submenu = menu
        return item
    }
}

/// Fills `SSH ▸ host ▸` when it opens: what is running on the host, then the
/// two ways in that need no list.
///
/// The list comes over ssh (`RemoteTmuxSessions`, ~6s ceiling), so the menu
/// opens at once with a "Listing…" row and is filled in place when the answer
/// lands — the main actor still runs while a menu is tracking. New tmux Session
/// and the plain shell are there from the first frame: a host you cannot list is
/// still a host you can connect to.
@MainActor
final class RemoteSessionsMenuFiller: NSObject, NSMenuDelegate {
    private let host: String
    private weak var target: AnyObject?
    private let pick: Selector
    private let shell: Selector
    private var loading = false

    init(host: String, target: AnyObject, pick: Selector, shell: Selector) {
        self.host = host
        self.target = target
        self.pick = pick
        self.shell = shell
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let cached = RemoteTmuxSessions.cached(host) {
            fill(menu, with: cached)
            return
        }
        fill(menu, with: nil)
        guard !loading else { return }
        loading = true
        Task { @MainActor [weak self, weak menu] in
            guard let self else { return }
            let result = await RemoteTmuxSessions.list(alias: self.host)
            self.loading = false
            if let menu { self.fill(menu, with: result) }
        }
    }

    private func fill(_ menu: NSMenu,
                      with result: Result<[RemoteTmuxSessions.Session], RemoteTmuxSessions.Failure>?) {
        menu.removeAllItems()
        switch result {
        case nil:
            menu.addItem(disabled("Listing sessions on \(host)…"))
        case .success(let sessions) where sessions.isEmpty:
            menu.addItem(disabled("No tmux sessions on \(host)"))
        case .success(let sessions):
            for session in sessions {
                let item = NSMenuItem(title: session.name, action: pick, keyEquivalent: "")
                item.target = target
                item.representedObject = SSHHostMenu.RemoteSessionPick(host: host, session: session.name)
                item.image = NSImage(systemSymbolName: session.attached ? "record.circle" : "rectangle.stack",
                                     accessibilityDescription: nil)
                let windows = session.windows == 1 ? "1 window" : "\(session.windows) windows"
                item.subtitle = session.attached ? "\(windows) · attached" : windows
                menu.addItem(item)
            }
        case .failure(let why):
            menu.addItem(disabled(why.message))
        }
        menu.addItem(.separator())
        let new = NSMenuItem(title: "New tmux Session", action: pick, keyEquivalent: "")
        new.target = target
        new.representedObject = SSHHostMenu.RemoteSessionPick(host: host, session: nil)
        new.image = NSImage(systemSymbolName: "plus.rectangle.on.rectangle", accessibilityDescription: nil)
        menu.addItem(new)
        let plain = NSMenuItem(title: "Shell (no tmux)", action: shell, keyEquivalent: "")
        plain.target = target
        plain.representedObject = host
        plain.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        menu.addItem(plain)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
#endif
