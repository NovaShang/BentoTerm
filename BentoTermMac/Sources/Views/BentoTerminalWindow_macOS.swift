import BentoFilePreviewKit
import BentoFoundationKit
import BentoSessionKit
import BentoUISharedKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Resolve the product-layer ID (server+name), not BentoTmuxKit's wire `$N` ID.
public typealias TmuxSessionID = BentoFoundationKit.TmuxSessionID

/// Opens native libghostty terminals backed by a local pty + `tmux -CC`. macOS
/// uses the *same* runtime stack as iOS; only the transport differs.
///
/// The app is a single-window terminal. A window holds every session and plain
/// terminal opened in it and shows one at a time; its sidebar is how you move
/// between them. A second window is made only when asked for (⇧⌘N, a sidebar
/// row's Open in New Window, the native tab bar's ＋) or when there is none.
/// Windows still join a native tab group (`tabbingIdentifier`), so Merge All
/// Windows and dragging a tab out keep working.
@MainActor
public enum BentoTerminalWindow {
    /// Every terminal window.
    private static var managers: [TerminalWindowManager] = []
    /// Every tmux SESSION open in any window, shown or not. Everything that
    /// lists, finds or names sessions reads this, so a plain terminal — which
    /// has no session — never has to be filtered back out one feature at a time.
    private static var sessionTabs: [SessionTab] {
        managers.flatMap(\.tabs).filter { !$0.isPlain }
    }

    /// The session the app opens when there is nothing to go back to.
    /// User-configurable (Settings → General → Default session name); `bento`
    /// when unset.
    public nonisolated static var defaultSessionName: String {
        TmuxSessionNaming.configuredDefault()
    }

    /// The local `tmux ls` poll wants to run as soon as something changed here,
    /// rather than up to 5s later. Wired in the app target.
    public static var onLocalServerChanged: (() -> Void)?

    /// Session KEYS currently open as tabs (drives the ✓ in the Sessions menu).
    /// Keys, not names: a remote `bento` and a local `bento` are two sessions
    /// and must not tick each other's box. See `TmuxSessionID.key`.
    public static var openSessionKeys: Set<String> { Set(sessionTabs.map(\.sessionKey)) }

    /// The identities of every open session, for callers that need to tell
    /// local from remote rather than just "is it open".
    public static var openSessionIDs: [TmuxSessionID] { sessionTabs.map(\.id) }

    /// Whether any session window is up. A window being built isn't in
    /// `managers` yet, so this answers "am I opening into an empty screen?".
    static var hasOpenWindows: Bool { !managers.isEmpty }

    /// Select a session (loading it if needed), or open the window if none yet.
    /// Takes a KEY so a menu item can name a remote session unambiguously; an
    /// unparseable key is ignored rather than guessed at.
    public static func focusOrOpen(sessionKey key: String) {
        guard let id = TmuxSessionID(key: key) else { return }
        focusOrOpen(id)
    }

    /// Go to session `id` — in THIS window: shown if it is open here, else
    /// opened here beside the others. One open in another window comes forward
    /// there (two connections on one session would be a duplicate).
    public static func focusOrOpen(_ id: TmuxSessionID) {
        focusOrOpen(id, then: nil)
    }

    /// Go to session `id` as `focusOrOpen` does, then `act` on the window that
    /// shows it — once its panes are known, which for a session still opening
    /// means waiting for the attach (bounded: an attach that never completes
    /// just lands on the session as it is).
    static func focusOrOpen(_ id: TmuxSessionID, then act: ((TerminalWindowManager) -> Void)?) {
        open(choice: .createOrAttach(name: id.name), server: id.server, title: titleFor(id))
        guard let act else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                guard let m = manager(for: id.key), m.tab.sessionKey == id.key else { return }
                let vm = m.tab.viewModel
                if vm.isTmuxReady, vm.activeTmuxSessionName == id.name, !vm.sessionPanes.isEmpty {
                    act(m)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// The sidebar's Open in New Window. One already open behind another in its
    /// window moves out, connection and all.
    public static func openInNewWindow(_ id: TmuxSessionID) {
        guard let m = manager(for: id.key), let open = m.sessionTab(id.key) else {
            open(choice: .createOrAttach(name: id.name), server: id.server,
                 title: titleFor(id), inNewWindow: true)
            return
        }
        if m.tabs.count > 1 {
            m.remove(open)
            addWindow(for: open, connect: false).bringToFront()
        } else {
            m.bringToFront()
        }
    }

    /// Pushed from the app's `tmux ls` poll: every session on the LOCAL server.
    ///
    /// This is now only the *dormant sessions* list — the names a window can
    /// offer to open that aren't open yet. It deliberately no longer decides
    /// whether an open window's session is still alive: that answer belongs to
    /// the window's own control channel, which is the only thing that knows
    /// which server to ask (`TerminalViewModel.sessionListGeneration`).
    public static func setLocalServerSessions(_ names: [LocalTmuxSessionName]) {
        knownServerSessions = names
        hasHeardFromServer = true
        for m in managers { m.updateLocalServerSessions(names) }
    }

    /// The last `tmux ls` the app pushed in. Kept here (not only fanned out to
    /// the managers) because the reopen path runs when there are none.
    private(set) static var knownServerSessions: [LocalTmuxSessionName] = []
    /// Whether `knownServerSessions` is an answer at all. Empty after a poll
    /// means "no sessions"; empty before one means "don't know yet".
    private static var hasHeardFromServer = false

    /// What else the poll knows about those sessions (window count, last
    /// activity), keyed by name. Pushed separately from the names so the
    /// name list keeps its single meaning — "these exist" — and a surface that
    /// only needs names is unaffected by a poll that hasn't described them yet.
    public private(set) static var serverSessionInfo: [String: LocalSessionInfo] = [:]

    public static func setLocalServerSessionInfo(_ infos: [LocalSessionInfo]) {
        serverSessionInfo = Dictionary(infos.map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })
    }

    /// Every session on the local server, as far as this process knows: the
    /// last `tmux ls` the app pushed in, plus anything we have open (the poll
    /// runs every 5s, so a just-created session isn't in it yet). Read by
    /// `OpenTargetProvider` — which is how the Dock menu reaches the session
    /// list without core having to know the Mac app exists.
    public static var serverSessions: [String] {
        var seen = Set<String>()
        // Sessions on an ssh host stay out: these rows attach on the LOCAL
        // server, and a remote name offered here would create an empty local
        // session under it.
        let open = sessionTabs
            .filter { $0.id.isLocal }
            .map(\.id.name)
        return (knownServerSessions.map(\.rawValue) + open)
            .filter { seen.insert($0).inserted }
    }

    /// The legacy reopen list (every local session that was open). Read once
    /// as a fallback for `lastSessionKey`, never written any more.
    nonisolated static let lastSessionsKey = "mac_last_terminal_sessions"
    /// The ONE local session that was in use last — what launch and the Dock
    /// icon bring back. See `recordSessionInUse`.
    nonisolated static let lastSessionKey = "mac_last_session"

    /// Close the terminal window (sessions keep running on the server; the next
    /// open reconnects them). The red traffic-light button does the same.
    public static func closeMainWindow() { frontmostManager()?.requestClose() }

    /// Test hook: run Kill Session on the frontmost window, skipping ONLY the
    /// confirmation alert (see `BENTO_TEST_KILL_SESSION_AFTER`).
    ///
    /// Kill Session lives in a toolbar `NSMenu` and there is no menu-bar item
    /// for it, so there is no scriptable route to the thing that most needs
    /// verifying: that killing from a REMOTE window leaves a local session of
    /// the same name alone. This enters the real `performKillSession`, so the
    /// path under test is the shipping one — the alert it skips is a
    /// confirmation, not the mechanism.
    public static func killFrontmostSessionSkippingConfirmation() {
        frontmostManager()?.killActiveSessionWithoutConfirmation()
    }

    /// Split the frontmost window's active pane — the ⌘D path, reached without
    /// the responder chain. See `BENTO_TEST_SPLIT_AFTER`.
    ///
    /// The menu item goes through `NSApp.sendAction(…, to: nil)`, which needs a
    /// KEY window to find a target; a test launch that never came to the front
    /// has none, so the dispatch quietly hits nobody. `frontmostManager()`
    /// falls back to the last window instead, which is what a headless run
    /// means by "frontmost". Same call the menu makes.
    public static func splitFrontmostPane() {
        frontmostManager()?.tab.viewModel.splitPane(horizontal: true)
    }

    /// Open a file preview in the focused window's side dock (the default
    /// surface — ⌘click and the context menu land here).
    static func openPreview(path: String, line: Int?, context: PathPreviewContext) {
        frontmostManager()?.openPreview(path: path, line: line, context: context)
    }

    /// The machine the focused pane is on. A `localhost` address typed into
    /// the browser's address bar means THAT box — the same thing it means in the terminal in front of
    /// you — rather than always this one.
    static func focusedLinkOrigin() -> LinkOrigin? {
        guard let m = frontmostManager() else { return nil }
        return m.tab.paneHost?.activeLinkOrigin
    }

    /// Open a page in the focused window's side dock — the destination
    /// `LinkRouter` sends web links to. Returns false when there is no window
    /// to put it in, which is the router's cue to fall back to the system
    /// browser rather than swallow the click.
    /// A plain terminal has no dock, so its links go to the system browser.
    @discardableResult
    static func openWeb(url: URL, origin: LinkOrigin?) -> Bool {
        guard let manager = frontmostManager(), !manager.tab.isPlain else { return false }
        manager.openWeb(url: url, origin: origin)
        return true
    }

    /// Show/hide the preview dock (pins survive a hide). ⌥⌘P and the toolbar.
    public static func togglePreviewDock() { frontmostManager()?.togglePreviewDock() }

    /// `BENTO_OPEN_SESSIONS` says "open exactly these, and nothing else".
    ///
    /// The app delegate honours that when it launches, but the restore path has
    /// a second entrance — `applicationShouldHandleReopen`, which fires on a
    /// Dock click and on any activation that finds no visible window — and that
    /// one went straight to `openMainWindow()`. A run started with the hook set
    /// could therefore still end up attaching to whatever the user had open,
    /// which is the one thing the hook exists to prevent, and it is not
    /// hypothetical: it happened during this work, attaching a test build to
    /// the live session the developer was using and resizing it. Checked here
    /// rather than at the delegate so every route into restore is covered by
    /// the same answer.
    static var sessionRestoreSuppressed: Bool {
        ProcessInfo.processInfo.environment["BENTO_OPEN_SESSIONS"] != nil
    }

    /// Launch, a Dock click, and ⌘N with no window: open the terminal.
    ///
    /// A window already up just comes forward — a Dock click is "show me the
    /// app", not "give me another". With none, the session that was in use
    /// LAST comes back if the server still has it, otherwise the default
    /// session (`new-session -A -s <default>`, so it attaches when it exists).
    /// The app opens straight into something you can type in; "pick what to
    /// open" is the ＋ menu.
    ///
    /// Only the most recent session is reopened, not every one that was open:
    /// the app is single-window by default, and one window brought back is
    /// the expectation; the rest are in the sidebar.
    public static func openMainWindow() {
        if let m = frontmostManager() {
            m.bringToFront()
            return
        }
        openMainWindowCreating()
    }

    /// The remembered session, falling back to the first entry of the list the
    /// app kept before it was single-window.
    static var lastSessionInUse: String? {
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: lastSessionKey), !name.isEmpty { return name }
        return defaults.stringArray(forKey: lastSessionsKey)?.first { !$0.isEmpty }
    }

    /// Remember `tab`'s session as the one in use. Called when a session window
    /// becomes key, opens, or switches session — never when one closes, so
    /// closing everything (or ⌘Q) leaves the record pointing at what you were
    /// last looking at, which is exactly what the next launch should bring back.
    ///
    /// Local sessions only. Reopening is `new-session -A`, which creates when
    /// the name is gone, so `openMainWindow` checks the name against the
    /// server's list first — and for an ssh host that check is a network round
    /// trip that can hang on a password or 2FA prompt before any window is up.
    /// (Plain terminals have no session; their windows never call this.)
    static func recordSessionInUse(_ id: TmuxSessionID) {
        guard id.isLocal else { return }
        UserDefaults.standard.set(id.name, forKey: lastSessionKey)
    }

    /// Set at the start of ⌘Q, before any window closes. Nothing is recorded
    /// on close any more (see `recordSessionInUse`), so this is informational:
    /// a window closing during it is the app leaving, not the user tidying.
    public static var isTerminating = false

    /// Open a plain shell with NO tmux (raw local pty, single surface) in the
    /// front window. Closing it destroys it — there's no session to reconnect.
    public static func newWindowNoTmux() {
        openPlain(title: "Terminal")
    }

    private static func newWindow(session: String) {
        let id = TmuxSessionID.local(session)
        open(choice: .createOrAttach(name: session), server: .local, title: titleFor(id),
             inNewWindow: true)
    }

    /// A new tmux session on this Mac, `<default>-2`, `-3`, …, in the front
    /// window (＋, ⇧⌘T, the Dock menu).
    public static func newSession() {
        focusOrOpen(.local(nextSessionName()))
    }

    /// Open a brand-new uniquely-named tmux session as a tab (the tab-bar `+`).
    public static func newSessionTab() {
        newWindow(session: nextSessionName())
    }

    /// File → New Window (⇧⌘N): a new Mac window holding a new tmux session,
    /// `<default>-2`, `-3`, … — the one gesture that asks for a second window.
    /// Whether it lands as a window or a tab is the system's "prefer tabs"
    /// answer (`shouldOpenAsTab`), the same as every other new session.
    ///
    /// ⌘N adds a pane or tmux window to the session you are in
    /// (`newPaneOrWindow`) — the app is a single-window terminal by default.
    public static func newSessionWindow() {
        newWindow(session: nextSessionName())
    }

    /// ⌘N: one more of what the front window is made of — a pane split along
    /// the active pane's longer side in Parallel, a tmux window in Focus (see
    /// `TerminalViewModel.newPaneOrWindow`), another plain terminal in front of
    /// a plain one. With no window at all, it does what launching does.
    public static func newPaneOrWindow() {
        guard let m = frontmostManager() else {
            openMainWindowCreating()
            return
        }
        if m.tab.isPlain {
            newWindowNoTmux()
        } else if m.tab.viewModel.isTmuxReady {
            m.tab.viewModel.newPaneOrWindow()
        }
    }

    /// `openMainWindow`, minus "a window exists, front it".
    private static func openMainWindowCreating() {
        guard !sessionRestoreSuppressed else { return }
        let live = hasHeardFromServer ? knownServerSessions.map(\.rawValue) : nil
        newWindow(session: TmuxSessionNaming.reopenTarget(
            last: lastSessionInUse, live: live, defaultName: defaultSessionName))
    }

    /// What File → ⌘N says right now: "New Pane" or "New tmux Window",
    /// following the front session's mode, or "New Plain Terminal" in front of
    /// a plain one.
    static var newItemTitle: String {
        guard let m = frontmostManager() else { return newPaneTitle }
        if m.tab.isPlain { return newPlainTerminalTitle }
        return m.tab.viewModel.sessionMode == .list ? newTmuxWindowTitle : newPaneTitle
    }
    nonisolated static let newPaneTitle = "New Pane"
    nonisolated static let newTmuxWindowTitle = "New tmux Window"
    nonisolated static let newPlainTerminalTitle = "New Plain Terminal"

    /// The Session menu's title, and its Release row's, as `TerminalCommands`
    /// declares them and `refreshMenuItems` finds them.
    nonisolated static let sessionMenuTitle = "Session"

    static func renameFrontSession() { frontSessionManager()?.presentRenameSheet() }
    static func releaseFrontSessionSize() { frontSessionManager()?.releaseSize() }
    static func detachFrontSession() { frontSessionManager()?.detachActiveSession() }
    static func killFrontSession() { frontSessionManager()?.killActiveSession() }

    /// The front window, when it shows a tmux session.
    private static func frontSessionManager() -> TerminalWindowManager? {
        frontmostManager().flatMap { $0.tab.isPlain ? nil : $0 }
    }

    /// Bring the menu bar up to date with the front window: File → ⌘N's title
    /// for its session's mode, the Session menu only while it shows a tmux
    /// session, and Release Size only while something has fixed the size.
    ///
    /// Done on the AppKit item rather than by making `TerminalCommands`
    /// observe state: a re-evaluated `.commands` body lets SwiftUI rebuild the
    /// menu, and its rebuild re-synthesizes File → Close with ⌘W — silently
    /// taking ⌘W back from Close Pane (see `reclaimClosePaneShortcut`). The
    /// item is found by its key equivalent so the title can't hide it.
    static func refreshMenuItems() {
        guard let main = NSApp.mainMenu else { return }
        let title = newItemTitle
        for top in main.items {
            for item in top.submenu?.items ?? []
            where item.keyEquivalent == "n" && item.keyEquivalentModifierMask == .command {
                if item.title != title { item.title = title }
            }
            if top.submenu?.title == sessionMenuTitle {
                let m = frontSessionManager()
                top.isHidden = m == nil
                let release = m?.tab.viewModel.sizingMode.offersRelease ?? false
                for item in top.submenu?.items ?? [] where item.title == TerminalSizingMode.releaseTitle {
                    item.isHidden = !release
                }
            }
        }
    }

    /// Lowest unused `<default>-N` (N ≥ 2). Checked against every session the
    /// local server is known to have, not just the ones with windows — a
    /// window-only check would quietly attach to a `bento-2` that some other
    /// terminal made.
    static func nextSessionName() -> String {
        var taken = Set(serverSessions)
        for t in sessionTabs where t.id.isLocal { taken.formUnion(t.viewModel.availableTmuxSessions) }
        return TmuxSessionNaming.numbered(defaultSessionName, existing: taken)
    }

    /// Open a plain (no-tmux) terminal running `ssh <host>`, where `host` is an
    /// alias from ~/.ssh/config. Like any plain tab, it's gone when ssh exits
    /// or the tab closes — persistence lives on the remote side, if anywhere.
    public static func newSSHWindow(host: String) {
        openPlain(title: host, command: ["ssh", host])
    }

    /// Whether the NEXT session should join the current tab group.
    ///
    /// macOS already asks this question globally (System Settings → Desktop &
    /// Dock → "Prefer tabs when opening documents"), so Bento follows that
    /// answer instead of keeping a second one.
    static var shouldOpenAsTab: Bool {
        NSWindow.userTabbingPreference == .always
    }

    /// Create a window for `tab`, joined to the front one's tab group when the
    /// system's preference says so.
    @discardableResult
    private static func addWindow(for tab: SessionTab, connect: Bool = true) -> TerminalWindowManager {
        let m = TerminalWindowManager(tab: tab, connect: connect)
        m.onEmpty = { [weak m] in
            managers.removeAll { $0 === m }
            // Nothing is written here. The reopen record is the session last
            // IN USE (`recordSessionInUse`, on focus / open / switch), so a
            // close — one window, the last one, or every one on the way out of
            // ⌘Q — leaves it naming what you were looking at. Writing on close
            // is how the old list got emptied by the last window going and the
            // user's session replaced with a fresh default.
            //
            // NOTE: the activation policy is NOT touched here. BentoTerm is an
            // ordinary app — it stays `.regular` with its Dock icon even with no
            // windows left, which is how you get back in. Dropping to
            // `.accessory` (what the menu-bar build did) would now leave a
            // process with no Dock icon, no menu-bar item and no window: alive,
            // invisible and unquittable.
            refreshMenuItems()
        }
        // Join the frontmost window's group only when tabs are what the user
        // wants; otherwise this stands alone. Either way `tabbingIdentifier` is
        // set, so Merge All Windows and dragging a tab out both keep working —
        // the preference decides the DEFAULT, not what's possible.
        if shouldOpenAsTab, let host = frontmostManager()?.window {
            host.addTabbedWindow(m.window, ordered: .above)
        }
        managers.append(m)
        return m
    }

    private static func frontmostManager() -> TerminalWindowManager? {
        managers.first { $0.window.isKeyWindow }
            ?? managers.first { $0.window.isMainWindow }
            ?? managers.last
    }

    /// The window holding SESSION `key`, shown or not.
    static func manager(for key: String) -> TerminalWindowManager? {
        managers.first { $0.sessionTab(key) != nil }
    }

    /// SESSION `key`, wherever it is open.
    static func tab(for key: String) -> SessionTab? {
        sessionTabs.first { $0.sessionKey == key }
    }

    /// What is open in `manager` changed: every window's sidebar lists it.
    static func tabsChanged(from manager: TerminalWindowManager) {
        for m in managers where m !== manager { m.rebuildSidebar() }
        refreshMenuItems()
    }

    private static func open(choice: TmuxStartChoice, server: TmuxServer, title: String,
                             inNewWindow: Bool = false) {
        let id = SessionTab.id(for: choice, on: server)
        let m: TerminalWindowManager
        if let holder = manager(for: id.key), let existing = holder.sessionTab(id.key) {
            m = holder
            if m.tab !== existing { m.show(existing) }
        } else {
            let tab = SessionTab(choice: choice, server: server, title: title)
            m = place(tab, inNewWindow: inNewWindow)
        }
        m.bringToFront()
        recordSessionInUse(m.tab.id)
        refreshMenuItems()
        if server == .local { onLocalServerChanged?() }
    }

    /// Put a new `tab` in the front window, or in one of its own.
    private static func place(_ tab: SessionTab, inNewWindow: Bool = false) -> TerminalWindowManager {
        if !inNewWindow, let m = frontmostManager() {
            m.add(tab)
            return m
        }
        return addWindow(for: tab)
    }

    /// A plain (no-tmux) terminal: never deduped — each is a new one — and never
    /// persisted, so closing it is final. Its key only has to be unique among
    /// plain terminals.
    static func openPlain(title: String, command: [String]? = nil,
                          in manager: TerminalWindowManager? = nil) {
        let taken = Set(managers.flatMap(\.tabs).filter(\.isPlain).map(\.sessionKey))
        var n = 1
        var key = title
        while taken.contains(key) { n += 1; key = "\(title) \(n)" }
        let tab = SessionTab(plainTitle: key, key: key, command: command)
        if let manager {
            manager.add(tab)
            manager.bringToFront()
        } else {
            place(tab).bringToFront()
        }
    }

    static func titleFor(_ id: TmuxSessionID) -> String {
        if !id.isLocal { return "BentoTerm · \(id.displayName)" }
        return id.name == defaultSessionName ? "BentoTerm" : "BentoTerm · \(id.name)"
    }
}
#endif
