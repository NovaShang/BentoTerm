import AppKit
import BentoTerminalCore

/// The menu behind a right-click on the Dock icon.
///
/// This is the third surface built on `OpenTargetProvider`, after the command
/// palette — and it is the one that pays for the provider existing. Closing the
/// last window does not quit BentoTerm (`applicationShouldTerminateAfterLast‐
/// WindowClosed` is `false`), so the app routinely sits in the Dock with zero
/// windows, and until now the only way back in was a plain click on the icon,
/// which reopens whatever happened to be open last. Everything else — another
/// session, a recent launch, an ssh host — needed a window first, so you had to
/// open the wrong thing to get at the right one. Right-click now answers "what
/// can I open?" directly, with no window in the picture.
///
/// **Nothing here may block.** AppKit asks for this menu synchronously, on the
/// main thread, in the moment of the right-click; anything slow shows up as a
/// Dock that doesn't respond. So all three sources are local reads: the session
/// list is a cached array the 5s poll already filled in, `~/.ssh/config` is one
/// small file, and the recents come from `UserDefaults`. No `tmux` shell-out,
/// and specifically no ssh: enumerating sessions on a remote host is a network
/// round trip that can also stop on a password or 2FA prompt, which is why the
/// SSH section offers hosts (`ssh <alias>`, exactly as the palette does) rather
/// than sessions on them.
///
/// Vocabulary and ordering are deliberately the palette's, so the two surfaces
/// can't disagree about what a thing is called: "Sessions", "Recent Launches",
/// "SSH Hosts". The order is the flat one `OpenTargetProvider.allTargets`
/// documents — what's running, then what you ran recently, then where you can
/// reach — because with no window on screen the likeliest reason you came here
/// is to get back to a session that is already up.
@MainActor
enum DockMenu {
    /// Caps, not scrollbars. A Dock menu is read at a glance while the pointer
    /// is already moving; past roughly half a dozen rows a section stops being
    /// scannable and the palette (⌘P, fuzzy-matched, unbounded) is the better
    /// tool. The numbers differ per section by how fast the tail decays:
    /// sessions are few and all plausible; a `~/.ssh/config` can hold dozens of
    /// aliases of which a handful are ever opened by hand; and for recents only
    /// the newest few are ever the one you meant.
    static let sessionLimit = 6
    static let recentLimit = 4
    static let sshLimit = 5

    /// Build the menu fresh. Called per right-click — there is no cache to
    /// invalidate, which is also why a session created a second ago is in it.
    static func build(provider: OpenTargetProvider = .shared) -> NSMenu {
        let menu = NSMenu()

        // Sessions come from the provider, i.e. from
        // `BentoTerminalWindow.serverSessions`, which is the LOCAL server's
        // list. `openSessionIDs` is the remote-aware one and is deliberately
        // not used: it lists sessions this process currently has windows for,
        // so in the case this menu exists for — zero windows — it is empty by
        // construction, and the rows it would add when windows *are* open go
        // through the remote-open path that is being revised elsewhere. Local
        // sessions survive the app; that is what makes them worth listing here.
        let open = BentoTerminalWindow.openSessionKeys
        addSection(to: menu, title: "Sessions",
                   targets: provider.sessionTargets(), limit: sessionLimit,
                   provider: provider) { target, item in
            // ✓ = already open as a tab, so clicking fronts it rather than
            // opening a second one. Same mark, same meaning as the toolbar's
            // Sessions menu.
            if case .tmuxSession(let name) = target.kind,
               open.contains(TmuxSessionID.local(name).key) {
                item.state = .on
            }
        }

        addSection(to: menu, title: "Recent Launches",
                   targets: provider.recentTargets(), limit: recentLimit,
                   provider: provider)

        addSection(to: menu, title: "SSH Hosts",
                   targets: provider.sshTargets(), limit: sshLimit,
                   provider: provider)

        // Always last, always present: a first run has no sessions, no recents
        // and possibly no `~/.ssh/config`, and a menu that renders as nothing
        // reads as a broken app rather than an empty one. ⌘N's action, so the
        // row means the same thing it means in the File menu.
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(actionItem(title: "New Window", systemImage: "plus.rectangle") {
            BentoTerminalWindow.newSessionWindow()
        })

        return menu
    }

    /// One section, or nothing at all. An empty section must not leave its
    /// header behind — a header over no rows is the skeleton of a feature the
    /// user doesn't have yet.
    private static func addSection(to menu: NSMenu, title: String,
                                   targets: [OpenTarget], limit: Int,
                                   provider: OpenTargetProvider,
                                   decorate: (OpenTarget, NSMenuItem) -> Void = { _, _ in }) {
        let shown = Array(targets.prefix(limit))
        guard !shown.isEmpty else { return }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(.sectionHeader(title: title))
        for target in shown {
            let item = actionItem(title: target.title, systemImage: target.systemImage) {
                provider.open(target)
            }
            item.toolTip = target.subtitle
            decorate(target, item)
            menu.addItem(item)
        }
    }

    private static func actionItem(title: String, systemImage: String,
                                   run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(DockAction.fire), keyEquivalent: "")
        let action = DockAction(run)
        item.target = action
        // `NSMenuItem.target` is weak; `representedObject` is what keeps the
        // action alive for as long as the menu is on screen.
        item.representedObject = action
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        return item
    }
}

/// A closure with an `@objc` face, so a menu item can carry its own action
/// without a switch over item tags somewhere else.
@MainActor
private final class DockAction: NSObject {
    private let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }
}
