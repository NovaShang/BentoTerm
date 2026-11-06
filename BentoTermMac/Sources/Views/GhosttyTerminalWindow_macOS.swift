import BentoTmuxKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftUI
import BentoAgentKit
import BentoSessionKit
import BentoUISharedKit
/// Resolve the product-layer ID (server+name), not BentoTmuxKit's wire `$N` ID.
public typealias TmuxSessionID = BentoFoundationKit.TmuxSessionID

/// Opens native libghostty terminals backed by a local pty + `tmux -CC`. macOS
/// uses the *same* runtime stack as iOS; only the transport differs.
///
/// Sessions are NATIVE macOS window tabs: one `TerminalWindowManager` and one
/// NSWindow per session, joined into a tab group by `tabbingIdentifier`. AppKit
/// then owns the tab bar (including hiding it at a single tab), ⌘⇧[ / ⌘⇧],
/// drag to reorder, drag out to a new window, and Merge All Windows — all of
/// which the previous self-managed strip either lacked or reimplemented.
///
/// A window's toolbar therefore carries the session's ACTIONS, not a switcher,
/// and its centre belongs to that session's tmux windows.
@MainActor
public enum BentoTerminalWindow {
    /// One window per session, all joined into a native tab group.
    private static var managers: [TerminalWindowManager] = []

    /// The session the app opens when there is nothing to go back to.
    /// User-configurable (Settings → General → Default session name); `bento`
    /// when unset.
    public nonisolated static var defaultSessionName: String {
        TmuxSessionNaming.configuredDefault()
    }

    /// App-provided hooks for toolbar actions that live in the app target.
    public static var onNewAgentSession: (() -> Void)?
    /// The local `tmux ls` poll wants to run as soon as something changed here,
    /// rather than up to 5s later. Wired in the app target.
    public static var onLocalServerChanged: (() -> Void)?

    /// Session KEYS currently open as tabs (drives the ✓ in the Sessions menu).
    /// Keys, not names: a remote `bento` and a local `bento` are two sessions
    /// and must not tick each other's box. See `TmuxSessionID.key`.
    public static var openSessionKeys: Set<String> { Set(managers.map(\.tab.sessionKey)) }

    /// The identities of every open session, for callers that need to tell
    /// local from remote rather than just "is it open".
    public static var openSessionIDs: [TmuxSessionID] { managers.map(\.tab.id) }

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

    /// Go to session `id` — in THIS window.
    ///
    /// The app is single-window by default, so picking a session (Session ⌄,
    /// ⌘P, the Dock menu, the launcher's session rows) moves the window you are
    /// in onto it with `switch-client`, the way `prefix s` does in a terminal,
    /// instead of piling up a window per session. Exceptions, all of which
    /// open a window because there is nothing to switch:
    ///   - the session is already up in another window → that window comes
    ///     forward (two windows on one session would be a duplicate);
    ///   - there is no session window, or the front one is a plain terminal;
    ///   - the session is on a different machine than the front window — a
    ///     control client can only switch between sessions on its own server.
    /// `openInNewWindow` is the explicit "keep this one, open that beside it".
    public static func focusOrOpen(_ id: TmuxSessionID) {
        if let m = manager(for: id.key) {
            m.bringToFront()
        } else if let m = switchableManager(for: id) {
            m.switchSession(to: id)
        } else {
            open(choice: .createOrAttach(name: id.name), server: id.server,
                 title: titleFor(id))
        }
    }

    /// Session ⌄ → Open in New Window (or ⌥-click): the one explicit way to
    /// get a second window for a session, instead of switching this one.
    public static func openInNewWindow(_ id: TmuxSessionID) {
        if let m = manager(for: id.key) {
            m.bringToFront()
        } else {
            open(choice: .createOrAttach(name: id.name), server: id.server,
                 title: titleFor(id))
        }
    }

    /// The window a session pick should switch: the front session window, when
    /// it is a live tmux session on the same server as `id`.
    private static func switchableManager(for id: TmuxSessionID) -> TerminalWindowManager? {
        guard let m = frontmostManager(), !m.tab.isPlain, m.tab.id.server == id.server,
              m.tab.viewModel.isTmuxReady else { return nil }
        return m
    }

    /// Open/focus `id` and land on the window with tmux INDEX `windowIndex`.
    ///
    /// The whole point of listing another session's windows in a menu is to
    /// arrive in the one you picked. The old menu-bar version of this attached
    /// with a window argument that was ignored, so it quietly landed on
    /// whatever window the session was last on.
    ///
    /// The select cannot be issued with the open: the window's tmux ID isn't
    /// known until the control channel has attached and listed them, and the
    /// index is all a poll can give. So wait for the list, then select. Bounded,
    /// because an attach that never completes must not leave a task waiting on
    /// it forever — and landing on the session's own current window is a fine
    /// failure mode.
    public static func focusOrOpen(_ id: TmuxSessionID, windowIndex: Int?) {
        focusOrOpen(id)
        guard let windowIndex else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let m = manager(for: id.key),
                   let window = m.tab.viewModel.windows.first(where: { $0.index == windowIndex }) {
                    m.tab.viewModel.selectWindow(window.id)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
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
        // An open launcher is showing this list as rows; push, don't poll.
        LauncherWindowController.serverSessionsChanged()
    }

    /// The last `tmux ls` the app pushed in. Kept here (not only fanned out to
    /// the managers) because the reopen path runs when there are none.
    private static var knownServerSessions: [LocalTmuxSessionName] = []
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
    /// `OpenTargetProvider` — which is how the launcher reaches the session
    /// list without core having to know the Mac app exists.
    public static var serverSessions: [String] {
        var seen = Set<String>()
        // Plain (no-tmux) tabs keep a sessionKey too, but there's no session
        // behind it — attaching to one would create an empty session by that
        // name, so they stay out. So do sessions on an ssh host, for the same
        // reason: the launcher attaches on the LOCAL server, and a remote name
        // offered here would create an empty local session under it.
        let open = managers.map(\.tab)
            .filter { !$0.isPlain && $0.id.isLocal }
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
    /// The strip's stable left-to-right tab order, persisted so it survives
    /// relaunches instead of re-alphabetizing on every cold start.
    nonisolated static let sessionOrderKey = "mac_session_strip_order"

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

    /// ⌘P: open the command palette over the focused window's active pane.
    public static func presentCommandPalette() {
        // Over a launcher window there is no pane to hang the File / Pane
        // sections off, but the palette still means what it means everywhere
        // else, so the launcher builds the sections that survive an empty
        // window and opens the same panel. It emphatically does NOT get its own
        // kind of search: the page used to answer ⌘P by focusing a filter over
        // its own dozen rows, which found strictly less than this does.
        if LauncherWindowController.presentPaletteIfKey() { return }
        guard let manager = frontmostManager() else { return }
        // A plain (no-tmux) tab has no pane host, and ⌘P used to silently do
        // nothing there — including for the dock's "+" while that still called
        // this. Fall back to the window itself so the panel always opens.
        if let paneHost = manager.tab.paneHost {
            paneHost.presentCommandPalette()
        } else {
            manager.presentCommandPaletteForPlainTab()
        }
    }

    /// Open a file preview in the focused window's side dock (the default
    /// surface — ⌘click, palette, context menu all land here).
    static func openPreview(path: String, line: Int?, context: PathPreviewContext) {
        frontmostManager()?.openPreview(path: path, line: line, context: context)
    }

    /// The machine the focused pane is on. A `localhost` address typed into
    /// ⌘P means THAT box — the same thing it means in the terminal in front of
    /// you — rather than always this one.
    static func focusedLinkOrigin() -> LinkOrigin? {
        guard let m = frontmostManager() else { return nil }
        return m.tab.paneHost?.activeLinkOrigin ?? m.tab.plainSurface?.linkOrigin
    }

    /// Open a page in the focused window's side dock — the destination
    /// `LinkRouter` sends web links to. Returns false when there is no window
    /// to put it in, which is the router's cue to fall back to the system
    /// browser rather than swallow the click.
    @discardableResult
    static func openWeb(url: URL, origin: LinkOrigin?) -> Bool {
        guard let manager = frontmostManager() else { return false }
        manager.openWeb(url: url, origin: origin)
        return true
    }

    /// Show/hide the preview dock (pins survive a hide). ⌥⌘P and the palette.
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
    /// Never the launcher: the app opens straight into something you can type
    /// in, and "pick what to open" is New ⌄ → New Session….
    ///
    /// Only the most recent session is reopened, not every one that was open:
    /// the app is single-window by default, and one window brought back is
    /// the expectation; the rest are a Session ⌄ away.
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
    /// Plain terminals have no session to come back to.
    static func recordSessionInUse(_ tab: SessionTab) {
        guard !tab.isPlain else { return }
        recordSessionInUse(tab.id)
    }

    static func recordSessionInUse(_ id: TmuxSessionID) {
        guard id.isLocal else { return }
        UserDefaults.standard.set(id.name, forKey: lastSessionKey)
    }

    /// Set at the start of ⌘Q, before any window closes. Nothing is recorded
    /// on close any more (see `recordSessionInUse`), so this is informational:
    /// a window closing during it is the app leaving, not the user tidying.
    public static var isTerminating = false

    /// Open a plain shell as a TAB with NO tmux (raw local pty, single surface).
    /// Closing the tab destroys it — there's no session to reconnect.
    public static func newWindowNoTmux() {
        openPlain(title: "Terminal")
    }

    public static func newWindow(session: String = defaultSessionName) {
        let id = TmuxSessionID.local(session)
        open(choice: .createOrAttach(name: session), server: .local, title: titleFor(id))
    }

    /// Open a tmux session on a REMOTE host over ssh, tiled exactly like a
    /// local one. `host` is an alias from the user's `~/.ssh/config`; how to
    /// actually reach it is ssh's problem, not ours.
    ///
    /// The whole remote capability is this one line plus an honest identity:
    /// `tmux -CC` is parsed entirely client-side off the byte stream, so once
    /// the bytes come from `ssh` instead of a login shell, every pane, split,
    /// window and status detection above it works unchanged.
    public static func newTmuxWindow(host: String, session: String = defaultSessionName) {
        let id = TmuxSessionID.ssh(host: host, name: session)
        open(choice: .createOrAttach(name: session), server: id.server, title: titleFor(id))
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
    /// This used to be ⌘N and open the launcher. ⌘N now adds a pane or tmux
    /// window to the session you are in (`newPaneOrWindow`) — the app is a
    /// single-window terminal by default — and the launcher is reached from
    /// New ⌄ → New Session….
    public static func newSessionWindow() {
        newWindow(session: nextSessionName())
    }

    /// ⌘N: one more of what the front session is made of — a pane split along
    /// the active pane's longer side in Parallel, a tmux window in Focus (see
    /// `TerminalViewModel.newPaneOrWindow`). With no session window to add to,
    /// it does what launching does.
    public static func newPaneOrWindow() {
        if let m = frontmostManager(), !m.tab.isPlain, m.tab.viewModel.isTmuxReady {
            m.tab.viewModel.newPaneOrWindow()
        } else if let m = managers.last(where: { !$0.tab.isPlain }) {
            // The front window is a plain terminal: it has no panes to add to,
            // so go to the session window you were last in instead.
            m.bringToFront()
        } else {
            openMainWindowCreating()
        }
    }

    /// `openMainWindow`, minus "a window exists, front it": the restore path
    /// for when every open window is a plain terminal.
    private static func openMainWindowCreating() {
        guard !sessionRestoreSuppressed else { return }
        let live = hasHeardFromServer ? knownServerSessions.map(\.rawValue) : nil
        newWindow(session: TmuxSessionNaming.reopenTarget(
            last: lastSessionInUse, live: live, defaultName: defaultSessionName))
    }

    /// What File → ⌘N says right now: "New Pane" or "New tmux Window",
    /// following the front session's mode.
    static var newItemTitle: String {
        guard let m = frontmostManager(), !m.tab.isPlain,
              m.tab.viewModel.sessionMode == .list else { return newPaneTitle }
        return newTmuxWindowTitle
    }
    nonisolated static let newPaneTitle = "New Pane"
    nonisolated static let newTmuxWindowTitle = "New tmux Window"

    /// Retitle File → ⌘N for the front session's mode.
    ///
    /// Done on the AppKit item rather than by making `TerminalCommands`
    /// observe state: a re-evaluated `.commands` body lets SwiftUI rebuild the
    /// menu, and its rebuild re-synthesizes File → Close with ⌘W — silently
    /// taking ⌘W back from Close Pane (see `reclaimClosePaneShortcut`). The
    /// item is found by its key equivalent so the title can't hide it.
    static func refreshNewItemTitle() {
        guard let main = NSApp.mainMenu else { return }
        let title = newItemTitle
        for top in main.items {
            for item in top.submenu?.items ?? []
            where item.keyEquivalent == "n" && item.keyEquivalentModifierMask == .command {
                if item.title != title { item.title = title }
            }
        }
    }

    /// The window a new tab would join: the frontmost session window, or nil
    /// when none is open. The launcher needs it for the same reason `addWindow`
    /// does — a launcher that will become a session has to appear where a
    /// session would.
    static var tabGroupHost: NSWindow? { frontmostManager()?.window }

    /// Open a window that has no session yet and shows the launcher. Picking
    /// something in it turns THAT window into the session (see
    /// `LauncherWindowController`) — no second window appears, which is the
    /// whole point of asking before creating.
    public static func openLauncherWindow() {
        LauncherWindowController.open()
    }

    /// Lowest unused `<default>-N` (N ≥ 2). Checked against every session the
    /// local server is known to have, not just the ones with windows — a
    /// window-only check would quietly attach to a `bento-2` that some other
    /// terminal made.
    static func nextSessionName() -> String {
        var taken = Set(serverSessions)
        for m in managers { taken.formUnion(m.tab.viewModel.availableTmuxSessions) }
        return TmuxSessionNaming.numbered(defaultSessionName, existing: taken)
    }

    public static func newWindow(agent spec: AgentSpec) {
        // The launch is recorded where the session is actually built
        // (`applyTmuxChoice`), so iPad's wizard gets it too.
        open(choice: .createAgent(spec: spec), server: .local,
             title: titleFor(.local(spec.sessionName)))
    }

    /// Open a plain (no-tmux) tab running `ssh <host>`, where `host` is an
    /// alias from ~/.ssh/config. Like any plain tab, it's gone when ssh exits
    /// or the tab closes — persistence lives on the remote side, if anywhere.
    public static func newSSHWindow(host: String) {
        openPlain(title: host, command: ["ssh", host])
    }

    /// Whether the NEXT session should join the current tab group.
    ///
    /// A launcher window asks this too, and must: it is a session window whose
    /// session hasn't been chosen yet, so if sessions open as tabs then the
    /// question "what should I open?" belongs in a tab as well — otherwise
    /// answering it moves the answer from a window into the tab bar, or leaves
    /// a stray window behind.
    ///
    /// macOS already asks this question globally (System Settings → Desktop &
    /// Dock → "Prefer tabs when opening documents"), so Bento follows that
    /// answer instead of keeping a second one.
    static var shouldOpenAsTab: Bool {
        NSWindow.userTabbingPreference == .always
    }

    /// Create a window for `tab` and join it to the existing tab group.
    ///
    /// Sessions are macOS window tabs now, one NSWindow each, rather than a
    /// hand-rolled strip inside a single window. That hands ⌘⇧[ / ⌘⇧], drag to
    /// reorder, drag out to a new window, Merge All Windows, and the tab bar
    /// itself (which hides itself at one tab) to AppKit — all of which the
    /// self-managed version either lacked or had to reimplement.
    @discardableResult
    private static func addWindow(for tab: SessionTab,
                                  adopting shell: TerminalSessionWindow? = nil) -> TerminalWindowManager {
        let m = TerminalWindowManager(tab: tab, adopting: shell)
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
            refreshNewItemTitle()
        }
        // Join the frontmost window's group only when tabs are what the user
        // wants; otherwise this stands alone. Either way `tabbingIdentifier` is
        // set, so Merge All Windows and dragging a tab out both keep working —
        // the preference decides the DEFAULT, not what's possible.
        //
        // An ADOPTED window is already on screen where the user put it, so it
        // never moves into somebody else's tab group: the gesture was "fill
        // this window", and a window that jumps into a tab bar as it fills has
        // not been filled, it has been replaced.
        if shell == nil, shouldOpenAsTab, let host = frontmostManager()?.window {
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

    static func manager(for key: String) -> TerminalWindowManager? {
        managers.first { $0.tab.sessionKey == key }
    }

    private static func open(choice: TmuxStartChoice, server: TmuxServer, title: String,
                             adopting shell: TerminalSessionWindow? = nil) {
        let id = SessionTab.id(for: choice, on: server)
        let m: TerminalWindowManager
        if let existing = manager(for: id.key) {
            m = existing
        } else {
            m = addWindow(for: SessionTab(choice: choice, server: server, title: title),
                          adopting: shell)
        }
        m.bringToFront()
        recordSessionInUse(m.tab)
        refreshNewItemTitle()
    }

    /// Turn a launcher window into a session window, in place.
    ///
    /// This is the one entry point that takes an existing window shell and
    /// gives it a session, and it exists because the launcher must not spawn:
    /// picking a session in a window that is asking you to pick one has to fill
    /// THAT window, or the act of choosing leaves two windows behind — the
    /// thing you chose, and the question you already answered.
    ///
    /// The session may nonetheless already be open in another window (New
    /// Session… and then a session that's up). Then there is nothing to
    /// adopt: `open` fronts the existing window and the caller closes the
    /// launcher, which is why this reports whether the shell was consumed.
    @discardableResult
    static func fill(_ shell: TerminalSessionWindow,
                     choice: TmuxStartChoice, server: TmuxServer, title: String) -> Bool {
        let id = SessionTab.id(for: choice, on: server)
        guard manager(for: id.key) == nil else {
            manager(for: id.key)?.bringToFront()
            return false
        }
        open(choice: choice, server: server, title: title, adopting: shell)
        return true
    }

    /// The launcher's own routes into a session, named so the launcher does not
    /// have to know about `TmuxStartChoice` or `TmuxServer`.
    ///
    /// A tmux session picked on the launcher is a session SWITCH like any
    /// other (`focusOrOpen`): the session window behind the launcher moves onto
    /// it and the launcher closes (false = shell not consumed). Only with no
    /// session window to switch does the launcher's own window become the
    /// session.
    static func fill(_ shell: TerminalSessionWindow, localSession name: String) -> Bool {
        let id = TmuxSessionID.local(name)
        if manager(for: id.key) == nil, let m = switchableManager(for: id) {
            m.switchSession(to: id)
            return false
        }
        return fill(shell, choice: .createOrAttach(name: name), server: .local,
                    title: titleFor(id))
    }

    static func fill(_ shell: TerminalSessionWindow, agent spec: AgentSpec) -> Bool {
        fill(shell, choice: .createAgent(spec: spec), server: .local,
             title: titleFor(.local(spec.sessionName)))
    }

    static func fill(_ shell: TerminalSessionWindow, tmuxHost host: String,
                     session: String = defaultSessionName) -> Bool {
        let id = TmuxSessionID.ssh(host: host, name: session)
        return fill(shell, choice: .createOrAttach(name: session), server: id.server,
                    title: titleFor(id))
    }

    /// A plain (no-tmux) shell — `ssh <alias>`, or a bare login shell — in the
    /// launcher's own window. Plain tabs are never deduped, so unlike the tmux
    /// routes this always consumes the shell.
    static func fill(_ shell: TerminalSessionWindow, plainTitle title: String,
                     command: [String]? = nil) {
        var n = 1
        var key = title
        while manager(for: key) != nil { n += 1; key = "\(title) \(n)" }
        addWindow(for: SessionTab(choice: .noTmux, server: .local, title: key,
                                  key: key, command: command),
                  adopting: shell)
            .bringToFront()
    }

    /// A plain (no-tmux) tab: never deduped — each is a new terminal — and never
    /// persisted, so closing it is final.
    static func openPlain(title: String, command: [String]? = nil) {
        var n = 1
        var key = title
        while manager(for: key) != nil { n += 1; key = "\(title) \(n)" }
        addWindow(for: SessionTab(choice: .noTmux, server: .local, title: key,
                                  key: key, command: command))
            .bringToFront()
    }

    static func titleFor(_ id: TmuxSessionID) -> String {
        if !id.isLocal { return "BentoTerm · \(id.displayName)" }
        return id.name == defaultSessionName ? "BentoTerm" : "BentoTerm · \(id.name)"
    }
}

// MARK: - SessionTab (a live, self-managed session)

/// One session: its view model, pane host, and lifecycle. Kept alive while it's
/// a background tab — the tmux -CC client keeps streaming so the surfaces stay
/// current; only the active tab's `paneHost` is in the window.
@MainActor
final class SessionTab {
    let viewModel: TerminalViewModel
    /// A tmux tab tiles panes; a plain (no-tmux) tab is a single raw surface.
    /// Exactly one of these is non-nil — `contentView` is whichever the window
    /// should host.
    let paneHost: GhosttyTiledPaneHost?
    let plainSurface: GhosttyTerminalSurface?
    /// The session's identity everywhere (strip order, active selection,
    /// persistence). A tmux rename changes that identity, so the manager
    /// migrates it to follow (`migrateSessionKey`) — the SERVER never changes,
    /// only the name on it.
    fileprivate(set) var id: TmuxSessionID
    /// String form of `id`, for the places identity has to travel as text.
    var sessionKey: String { id.key }
    let choice: TmuxStartChoice
    let windowTitle: String
    /// The ssh control socket this session keeps open, so a clicked
    /// `localhost:5173` can be tunnelled without a second login. Released in
    /// `teardown` — a forward never outlives the session that carries it.
    private var controlSocket: (alias: String, path: String?)?

    /// A plain tab has no tmux behind it: no panes/windows/agents, and closing it
    /// destroys it (it isn't persisted or reconnected).
    var isPlain: Bool { plainSurface != nil }
    var contentView: NSView { paneHost ?? plainSurface! }

    /// The focused pane's file context (tmux host → its active pane; plain
    /// tab → its surface) — what the dock's directory tree roots itself at.
    var previewContext: PathPreviewContext? {
        paneHost?.activePathPreviewContext ?? plainSurface?.pathPreviewContext
    }

    /// `command` overrides the plain (no-tmux) tab's login shell — a
    /// quick-connect `["ssh", host]`, or a one-liner from the wizard.
    ///
    /// A tmux-backed tab must leave `command` nil for the LOCAL server (the VM
    /// types the tmux line into a login shell). For a session on an ssh host it
    /// is the opposite: the command is built here, below, and carries the
    /// `tmux -CC` invocation as ssh's own argument.
    init(choice: TmuxStartChoice, server: TmuxServer, title: String,
         key: String? = nil, command: [String]? = nil) {
        self.choice = choice
        self.windowTitle = title
        self.id = key.flatMap(TmuxSessionID.init(key:)) ?? Self.id(for: choice, on: server)
        let theme = ThemeStore.shared.makeTerminalTheme()
        let storedKey = id.key
        let env = TerminalEnvironment(
            idealTerminalSize: { (120, 30) },
            // What `ssh` asks for, when the user asked us to remember it.
            loadKeychainPassword: { key in MacKeychain.load(key) },
            saveKeychainPassword: { key, value in MacKeychain.save(key, value) },
            onSessionUpdate: { _, session, awaiting, prompt in
                // The VM reports the session NAME; the notifier keys on
                // IDENTITY. On a remote session those differ, and passing the
                // bare name would let an agent waiting in `bento` on a build
                // box overwrite the notification for the local `bento`.
                let key = session.isEmpty
                    ? storedKey
                    : TmuxSessionID(server: server, name: session).key
                MacAwaitingNotifier.shared.update(
                    sessionKey: key, awaiting: awaiting, prompt: prompt)
            }
        )
        let transport: LocalPtyTransport
        var adopted: (alias: String, path: String?)?
        if let sshHost = server.sshHost, choice != .noTmux {
            // The tmux invocation goes in as ssh's ARGUMENT rather than being
            // typed at a shell afterwards.
            //
            // Typing it is a race with the connection: the launch write is
            // gated on a fixed 500ms sleep, which is a guess about how long a
            // login takes. On a host that asks for a password or a 2FA code
            // that guess is not just wrong, it is dangerous — the launch line,
            // and then a newline, get typed into the prompt. As an argument
            // there is no window at all: ssh does not run the command until
            // authentication has completed, however long that takes and however
            // many prompts it involves.
            //
            // `-t` forces a pty, which tmux requires; ssh otherwise allocates
            // none when it is given a command to run.
            let launch = Self.remoteLaunchCommand(for: choice, name: id.name)
            // Keep a control socket on this connection. A port forward added
            // later rides it (`ssh -O forward`) instead of opening a second
            // connection and asking for the password — or the 2FA code — again.
            let socket = SSHControlSockets.adopt(alias: sshHost)
            adopted = (sshHost, socket.controlPath)
            transport = LocalPtyTransport(
                command: ["ssh", "-t"] + socket.options + [sshHost, launch],
                isLocalLink: false,
                startsInTmuxControlMode: true)
        } else if let command, command.first == "ssh", command.count >= 2 {
            // Quick-connect (`ssh <alias>`, no tmux) gets the same treatment —
            // it is still a machine whose ports a link can point at.
            let alias = command[1]
            let socket = SSHControlSockets.adopt(alias: alias)
            adopted = (alias, socket.controlPath)
            transport = LocalPtyTransport(
                command: ["ssh"] + socket.options + Array(command.dropFirst()))
        } else {
            transport = LocalPtyTransport(command: command)
        }
        let vm = TerminalViewModel(
            host: Host(name: server.sshHost ?? "Local"),
            transport: transport,
            environment: env)
        self.viewModel = vm
        self.controlSocket = adopted
        // Computed from the local `adopted` rather than from `self.linkHost`:
        // the surfaces below are stored properties that are not set yet, so
        // `self` is still off limits here.
        let tabLinkHost: LinkHost = adopted
            .map { LinkHost(remoteID: $0.alias, label: $0.alias) }
            ?? .local(label: "This Mac")
        if choice == .noTmux {
            // No tmux → a single raw surface (no tiling host); the VM streams
            // bytes straight to/from it.
            let surface = GhosttyTerminalSurface(theme: theme)
            surface.onInput = { [weak vm] data in vm?.sendData(data) }
            surface.onSizeChanged = { [weak vm] size in
                vm?.resizeTerminal(cols: size.columns, rows: size.rows)
            }
            // Path preview: a plain tab is a local shell; cwd comes from the
            // shell's OSC 7 report (ghostty shell integration). A quick-connect
            // `ssh <host>` tab is remote for its whole life (it dies when ssh
            // exits) — refuse local browsing/preview honestly.
            let block = PathPreviewContext.localSourceBlock(sessionHost: nil,
                                                            foregroundCommand: command?.first)
            surface.pathPreviewContext = PathPreviewContext(
                source: LocalFileSource(),
                cwd: { [weak surface] in surface?.reportedPwd },
                hostLabel: "This Mac",
                isLocal: true,
                remoteBlock: block.map { reason in { @Sendable @MainActor in reason } })
            surface.onOpenPreview = { path, line, context in
                BentoTerminalWindow.openPreview(path: path, line: line, context: context)
            }
            vm.onRawDataReceived = { [weak surface] data in
                Task { @MainActor [weak surface] in surface?.feed(data) }
            }
            self.plainSurface = surface
            self.paneHost = nil
            surface.linkOriginProvider = { LinkOrigin(paneID: nil, host: tabLinkHost) }
        } else {
            let tiled = GhosttyTiledPaneHost(viewModel: vm, theme: theme)
            tiled.linkHost = tabLinkHost
            self.paneHost = tiled
            self.plainSurface = nil
        }
    }

    func connect() {
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.connect()
            await self.viewModel.applyTmuxChoice(self.choice)
        }
    }

    func teardown() {
        paneHost?.teardown()
        plainSurface?.teardown()
        viewModel.disconnect()
        MacAwaitingNotifier.shared.clear(sessionKey: sessionKey)
        if let controlSocket {
            // The session is what the tunnels ride on: when it goes, they go.
            PortForwarders.current?.closeAll(on: linkHost)
            SSHControlSockets.release(alias: controlSocket.alias, controlPath: controlSocket.path)
            self.controlSocket = nil
        }
    }

    /// Which machine this tab's panes mean by `localhost`.
    var linkHost: LinkHost {
        guard let alias = controlSocket?.alias else { return .local(label: "This Mac") }
        return LinkHost(remoteID: alias, label: alias)
    }

    static func id(for choice: TmuxStartChoice, on server: TmuxServer) -> TmuxSessionID {
        switch choice {
        case .createOrAttach(let name): return TmuxSessionID(server: server, name: name)
        case .createAgent(let spec): return TmuxSessionID(server: server, name: spec.sessionName)
        case .shareWithDesktop(let target): return TmuxSessionID(server: server, name: target)
        // A plain tab has no session behind it; it is deduped by title instead
        // (see `openPlain`), and this is only its starting point.
        case .noTmux: return .local("local")
        }
    }

    /// The `tmux -CC …` line handed to `ssh` as its argument. Built by the same
    /// builder the typed local path uses, so a remote session is created and
    /// attached on exactly the same terms as a local one — wrapped in a login
    /// shell, because unlike the local path there is no login shell here
    /// otherwise (`remoteLaunchCommandLine`).
    static func remoteLaunchCommand(for choice: TmuxStartChoice, name: String) -> String {
        switch choice {
        case .createAgent(let spec):
            return TmuxControlMode.remoteLaunchCommandLine(
                sessionName: name, path: spec.workingDir,
                command: spec.agentCommand.isEmpty ? nil : spec.agentCommand)
        case .shareWithDesktop(let target):
            return TmuxControlMode.remoteLaunchCommandLine(
                sessionName: "\(target)-mobile", groupWith: target)
        case .createOrAttach, .noTmux:
            return TmuxControlMode.remoteLaunchCommandLine(sessionName: name)
        }
    }
}

// MARK: - TerminalWindowManager (one window, many session tabs)

@MainActor
final class TerminalWindowManager: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow!
    /// The ONE session this window shows. Several sessions means several
    /// windows, joined into a native tab group — see `BentoTerminalWindow`.
    let tab: SessionTab
    /// Every tmux session on the LOCAL machine (pushed from the app's `tmux ls`
    /// poll). Only the dormant-session list for the strip — it says nothing
    /// about whether THIS window's session is alive when this window is remote.
    private var localServerSessions: [LocalTmuxSessionName] = []
    /// Consecutive self-polls in which this window's session was missing from
    /// its OWN server's session list.
    private var absentPolls = 0
    private static let absentPollsToClose = 4
    /// The last `sessionListGeneration` acted on, so a Combine republish that
    /// isn't a fresh list can't be counted as a miss.
    private var lastSessionListGeneration = 0
    /// The sessions currently shown as segments (subset when overflowing).
    /// The tmux windows currently shown as segments (a subset when they
    /// overflow the strip). Sessions moved to the named button on the left.
    private var visibleWindows: [TmuxWindowID] = []

    private let toolbar = TerminalToolbarController()
    /// The window's content is the SYSTEM sidebar arrangement — an
    /// `NSSplitViewController` whose first item is a real sidebar split item.
    /// Material, full-height layout, animated collapse, drag-to-resize, and
    /// width persistence are all AppKit's; we only decide WHEN it shows
    /// (Focus mode) and WHAT it hosts (the shared SwiftUI `WindowSidebar`).
    private let splitVC = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var sidebarHosting: NSHostingController<AnyView>!
    /// Trailing "pin previews here" dock — a collapsed split item that expands
    /// on the first pin. One model per window, persists across tab switches.
    let previewDock = PreviewDockModel()
    private var dockItem: NSSplitViewItem!
    /// Content column root. With `.fullSizeContentView` the column extends
    /// under the toolbar, so the terminal container insets by the safe area —
    /// re-derived on every layout pass (the closure runs `layoutContent`).
    private let contentRoot = LayoutHookView()
    private let container = NSView()
    /// Opaque theme-colored filler under the toolbar band. The unified
    /// toolbar's material samples the content BENEATH it — with the terminal
    /// inset below the safe area, that band would otherwise be undefined
    /// chrome, and the toolbar's frosting could never match the terminal.
    /// Frosting the theme color itself is the system-correct unified look
    /// (what Safari's toolbar does over page content).
    private let topFill = NSView()
    /// The tab the sidebar's rootView was built for (swapped on tab switch).
    private var sidebarHostKey: String?
    /// True when more sessions exist than fit — the last segment becomes a `⋯`
    /// that pops the full list.
    private var hasOverflow = false
    // A local right-click monitor used to pop the session menu anywhere in the
    // titlebar band. It was written when the centre strip held SESSIONS, so
    // right-clicking a session showed that session's actions. The strip holds
    // WINDOWS now and sessions are native tabs with their own system menu, so
    // it had become: right-click anywhere up there, get the ACTIVE session's
    // actions — including Kill Session — while the user was pointing at a
    // different tab. Destructive action, wrong target, no way to tell. Removed;
    // the session's actions live in the named button on the left.

    /// Toolbar bindings to the *active* tab's VM (re-subscribed on switch).
    private var activeCancellables = Set<AnyCancellable>()
    /// One failure alert per window — the view model can re-publish `showError`
    /// and the sheet must not stack.
    private var failureAlertShown = false

    /// The auth sheet currently up, if any. One at a time: ssh asks its next
    /// question only after this one is answered.
    private var authPromptAlert: NSAlert?
    /// Per-tab subscriptions (agent dots + tab titles), keyed by tab identity.
    private var tabCancellables: [ObjectIdentifier: Set<AnyCancellable>] = [:]

    var onEmpty: (() -> Void)?

    /// `shell` is an existing, already-visible window to take over — the
    /// launcher's. Everything below then configures that window instead of a
    /// fresh one, so the window the user was looking at becomes the session
    /// rather than being replaced by a second window beside it.
    init(tab: SessionTab, adopting shell: TerminalSessionWindow? = nil) {
        self.tab = tab
        super.init()
        // A session window and a launcher window are ONE kind of window, built
        // and dressed by one function (`TerminalSessionWindow.makeShell`). When
        // `shell` is non-nil it has already been through that function as a
        // launcher, so there is nothing here to redo — which is the point: the
        // two must not be able to drift, and they drifted for as long as each
        // configured its own window inline.
        let win = shell ?? TerminalSessionWindow.makeShell()
        win.delegate = self

        // Content = the system sidebar arrangement. The sidebar split item
        // brings the native material, full-height layout, animated collapse,
        // divider drag, and width autosave — no hand-rolled chrome.
        contentRoot.autoresizesSubviews = false
        topFill.wantsLayer = true
        contentRoot.addSubview(topFill)
        contentRoot.addSubview(container)

        sidebarHosting = NSHostingController(rootView: AnyView(EmptyView()))
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 340
        sidebar.allowsFullHeightLayout = true
        sidebar.isCollapsed = true
        // The item's first-layout thickness comes from its view's frame — set
        // it to the new 50%-wider default (1.5× the 180 minimum) BEFORE the
        // split view ever lays out, or the window opens with the stale width.
        sidebarHosting.view.frame = NSRect(x: 0, y: 0, width: 270, height: 640)
        sidebarItem = sidebar

        let contentVC = NSViewController()
        contentVC.view = contentRoot
        let contentItem = NSSplitViewItem(viewController: contentVC)
        // The terminal's floor. The dock has no ceiling (see below), so this is
        // what stops a dock drag from squeezing the terminal to nothing and
        // resizing tmux to a pathological column count.
        contentItem.minimumThickness = 400
        splitVC.addSplitViewItem(sidebar)
        splitVC.addSplitViewItem(contentItem)

        // Trailing preview dock: collapsed until something is pinned. The
        // dock's content starts BELOW the title bar (safe-area top) — unlike
        // the full-height sidebar, it reads as a panel UNDER the window
        // chrome, not a column through it.
        let dockVC = NSViewController()
        let dockRoot = NSView()
        let dockHosting = NSHostingView(rootView: PreviewDock(model: previewDock))
        dockHosting.translatesAutoresizingMaskIntoConstraints = false
        dockRoot.addSubview(dockHosting)
        NSLayoutConstraint.activate([
            dockHosting.topAnchor.constraint(equalTo: dockRoot.safeAreaLayoutGuide.topAnchor),
            dockHosting.leadingAnchor.constraint(equalTo: dockRoot.leadingAnchor),
            dockHosting.trailingAnchor.constraint(equalTo: dockRoot.trailingAnchor),
            dockHosting.bottomAnchor.constraint(equalTo: dockRoot.bottomAnchor),
        ])
        dockVC.view = dockRoot
        let dock = NSSplitViewItem(viewController: dockVC)
        dock.canCollapse = true
        dock.minimumThickness = 300
        // No maximum. A 720pt cap is fine on a laptop and absurd on a 27" —
        // reading a long markdown file there wants half the window. How wide
        // the dock should be is the user's call; the terminal's floor
        // (contentItem.minimumThickness) is the only thing we insist on.
        dock.isCollapsed = true
        dock.holdingPriority = NSLayoutConstraint.Priority(251)  // terminal flexes, dock holds
        dockItem = dock
        splitVC.addSplitViewItem(dock)
        // Inspector-style toolbar toggle (always present). The dock's first
        // tab is the focused pane's directory tree; the provider resolves the
        // CURRENT pane at load time, so the tree follows the user.
        toolbar.onTogglePreview = { [weak self] in self?.togglePreviewDock() }
        previewDock.treeContextProvider = { [weak self] in self?.activeTab?.previewContext }

        // Key bumped from "BentoSidebarSplit" so the wider default (270)
        // applies even where the old key remembers a narrower width; drags
        // from here on save into the new key.
        splitVC.splitView.autosaveName = "BentoSidebarSplitWide"
        // Assigning a `contentViewController` RESIZES the window to that
        // controller's fitting size — measured, and for this split view that is
        // 500 × 500. On a fresh window nobody sees it (the real size is set on
        // the next line); on an adopted one it is the fill visibly shrinking a
        // window the user is looking at, which is exactly the jump this path
        // exists to avoid. So the adopted frame is captured and put back.
        let adoptedFrame = shell?.frame
        win.contentViewController = splitVC
        if let adoptedFrame {
            win.setFrame(adoptedFrame, display: true)
        } else {
            win.setContentSize(Self.defaultContentSize)
        }
        // The splitView autosave (kept for the sidebar width) also remembers
        // the dock's expanded state across window incarnations — a fresh
        // window would restore yesterday's EXPANDED dock with a brand-new,
        // empty, uncloseable model behind it. Dock visibility is model-driven
        // only: re-assert emptiness after the restoration that the
        // contentViewController assignment just applied (and once more next
        // runloop turn, in case restoration lands on first display).
        dockItem.isCollapsed = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dockItem.isCollapsed = self.previewDock.tabs.isEmpty
        }
        applyWindowBackground(to: win)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: .terminalThemeChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(surfaceBackgroundChanged(_:)),
            name: .ghosttySurfaceBackgroundChanged, object: nil)

        // Toolbar: <session> ⌄ | [window tabs] | New ⌄ | ⋯ — the centre hosts the
        // current session's tmux WINDOWS as a Finder-style segmented
        // `NSToolbarItemGroup`; sessions live in the named button's menu on the
        // left. That gives tmux's three levels three fixed places (session /
        // window / pane) instead of leaving the middle one homeless.
        toolbar.onSelectSegment = { [weak self] idx in self?.segmentPicked(idx) }
        // Picking a session moves THIS window onto it (switch-client); one
        // already up in another window comes forward instead. ⌥ / the row's
        // "Open in New Window" keeps this window and opens that one beside it.
        toolbar.onSelectSession = { key in BentoTerminalWindow.focusOrOpen(sessionKey: key) }
        toolbar.onOpenSessionInNewWindow = { key in
            if let id = TmuxSessionID(key: key) { BentoTerminalWindow.openInNewWindow(id) }
        }
        toolbar.onOpenSearch = { [weak self] in
            guard let self else { return }
            self.tab.paneHost?.presentCommandPalette(from: self.toolbar.searchAnchor)
        }
        // New ⌄ → New Session…: the launcher, the one place that asks what to
        // open (agent, empty, plain shell, ssh host). Not ⌘N any more — see
        // `BentoTerminalWindow.newPaneOrWindow`.
        toolbar.onNewSession = { BentoTerminalWindow.openLauncherWindow() }
        toolbar.onReleaseSize = { [weak self] in
            self?.activeTab?.viewModel.releaseSessionSize()
            self?.rebuildTabBar()
        }
        toolbar.onClaimSessionSize = { [weak self] in
            self?.activeTab?.viewModel.claimSessionSize()
            self?.rebuildTabBar()
        }
        toolbar.onSelectMode = { [weak self] mode in self?.requestMode(mode) }
        toolbar.onKillSession = { [weak self] in self?.killActiveSession() }
        toolbar.onDetach = { [weak self] in self?.detachActiveSession() }
        // A plain tab vanishes with its window — there's nothing to reconnect.
        toolbar.onCloseTab = { [weak self] in self?.window.close() }
        toolbar.onRenameSession = { [weak self] in self?.presentRenameSheet() }
        toolbar.onWindowMenu = { [weak self] index in self?.windowMenuItems(forSegment: index) }
        toolbar.hostWindow = win
        win.onRightClick = { [weak toolbar] point in
            toolbar?.handleRightClick(atWindowPoint: point) ?? false
        }
        win.toolbar = toolbar.makeToolbar()
        win.toolbarStyle = .unified
        // Restore size + position, but only for the window that opens into an
        // empty screen — the rest join its tab group (which shares one frame) or
        // cascade beside it, and AppKit refuses a duplicate autosave name anyway.
        //
        // An ADOPTED launcher already claimed the name and is already at the
        // restored frame; the claim rides along with the window because it IS
        // the same window, so there is no handover and therefore no window in
        // which the name is unowned and a resize goes unrecorded. Moving it now
        // would be wrong twice over: it is on screen and being looked at, and
        // the frame it is at is the one the user just settled on.
        if BentoWindowFrame.owns(win) {
            // Nothing to do — the launcher brought the name with it.
        } else if !BentoTerminalWindow.hasOpenWindows, BentoWindowFrame.claim(win) {
            if shell == nil, !win.setFrameUsingName(BentoWindowFrame.name) { win.center() }
        }
        self.window = win
        installContentConstraints(in: win)

        // Bring the session up. This used to live in `loadTab`, which ran when a
        // tab was added to the old multi-tab window; with one session per window
        // it belongs to construction — a window without these is a titled box
        // with nothing connected behind it.
        subscribe(tab)
        tab.connect()
        show(tab)
        BentoTerminalWindow.recordSessionInUse(tab)
    }

    /// The size a session window opens at when nothing is remembered.
    nonisolated static let defaultContentSize = NSSize(width: 980, height: 640)

    var activeTab: SessionTab? { tab }

    /// ⌘P over a plain (no-tmux) tab, which has no pane host to build the
    /// pane-flavoured sections. The file context comes from the tab's single
    /// surface instead; everything else the panel offers still applies.
    func presentCommandPaletteForPlainTab() {
        let ctx = plainSurfaceContext
        CommandPaletteController.shared.present(
            fileContext: ctx,
            hostLabel: ctx?.hostLabel ?? "This Mac",
            staticSpecs: [],
            from: nil)
    }

    private var plainSurfaceContext: PathPreviewContext? {
        tab.plainSurface?.pathPreviewContext
    }

    /// Open a preview in the side dock (expanding it) and bring the window front.
    func openPreview(path: String, line: Int?, context: PathPreviewContext) {
        previewDock.open(path: path, line: line, context: context)
        dockItem?.animator().isCollapsed = false
        window?.makeKeyAndOrderFront(nil)
    }

    /// Same, for a page. The window comes forward but focus stays where it is —
    /// clicking a link in a terminal must not take the keyboard away from it.
    func openWeb(url: URL, origin: LinkOrigin?) {
        previewDock.openWeb(url: url, origin: origin)
        dockItem?.animator().isCollapsed = false
        window?.orderFront(nil)
    }

    /// Show/hide the dock without touching its tabs.
    func togglePreviewDock() {
        dockItem.animator().isCollapsed.toggle()
    }

    // MARK: Sidebar (Focus mode's window switcher)

    /// The window chrome wears the terminal's background, so the transparent
    /// title bar and any uncovered chrome read as one surface with the
    /// terminal (the ghostty look). The color of record is what the ENGINE
    /// says it renders (`reportedChromeColor`, from GHOSTTY_ACTION_COLOR_CHANGE
    /// — it reflects the user's own ghostty config and runtime OSC 11); the
    /// configured theme is only the pre-first-report fallback.
    private func applyWindowBackground(to win: NSWindow) {
        let color = reportedChromeColor ?? themeBackgroundColor()
        win.backgroundColor = color
        topFill.layer?.backgroundColor = color.cgColor
    }

    /// Last engine-reported background (nil until a surface's first report).
    private var reportedChromeColor: NSColor?

    private func themeBackgroundColor() -> NSColor {
        // The CURRENT effective theme's background — it follows appearanceMode /
        // systemIsDark LIVE. Deliberately NOT `GhosttyRuntime.effectiveBackgroundRGB()`
        // (the base ghostty config): that config is built ONCE at runtime init,
        // and the OS appearance can resolve late (defaulting to aqua
        // early), so a dark launch baked the LIGHT theme (0xFFFFFF) into the base
        // config and never rebuilt — leaving the title bar white in dark mode
        // even across relaunches. The live `reportedChromeColor` (a pane's actual
        // rendered bg) still wins in `applyWindowBackground`, so a custom ghostty
        // `background =` is honored the moment a surface reports; this is only the
        // pre-first-report fallback, and it must track the theme, not a stale config.
        return NSColor(hex: ThemeStore.shared.current.bg)
    }

    @objc private func themeChanged() {
        // New theme → stale report; surfaces re-report after the config reload.
        reportedChromeColor = nil
        applyWindowBackground(to: window)
    }

    /// A surface in THIS window reported the background it actually renders —
    /// adopt it for the chrome. (Any pane will do: panes of one session share
    /// a background outside exotic per-pane OSC use.)
    @objc private func surfaceBackgroundChanged(_ note: Notification) {
        guard let view = note.object as? GhosttyTerminalSurface,
              view.window === window,
              let color = view.reportedBackgroundColor else { return }
        reportedChromeColor = color
        applyWindowBackground(to: window)
    }

    /// The sidebar is MODE-driven, never user-toggled: it appears exactly when
    /// the active tab is a tmux session in Focus mode (there it IS the window
    /// management surface) and hides in Parallel / plain tabs.
    private var shouldShowSidebar: Bool {
        guard let tab = activeTab, !tab.isPlain else { return false }
        return tab.viewModel.sessionMode == .list
    }

    /// Create / swap / remove the hosted `WindowSidebar` to match the active
    /// tab and its mode, then re-derive the two content frames. Called on tab
    /// switch, mode change, and the toolbar toggle.
    private func updateSidebar() {
        let showing = shouldShowSidebar
        if showing, let tab = activeTab {
            if sidebarHostKey != tab.sessionKey {
                sidebarHosting.rootView = AnyView(WindowSidebar(viewModel: tab.viewModel))
                sidebarHostKey = tab.sessionKey
            }
        } else if let key = sidebarHostKey, key != activeTab?.sessionKey {
            // The hosted VM's tab is gone (or switched away) — drop the
            // observation so a torn-down VM isn't kept alive by SwiftUI.
            sidebarHosting.rootView = AnyView(EmptyView())
            sidebarHostKey = nil
        }
        // In Focus the toolbar's centre shows the current window's name as a
        // label, not a switcher — the sidebar IS the switcher. Letting the user
        // drag it shut would leave Focus with no way to change window at all,
        // so it is pinned open while that mode is on.
        sidebarItem.canCollapse = !showing
        if sidebarItem.isCollapsed == showing {
            sidebarItem.animator().isCollapsed = !showing
        }
    }

    /// The container fills the content column BELOW the toolbar (full-size
    /// content puts the column under it; the safe area says by how much).
    /// Divider drag / sidebar collapse resize flows into the pane host, which
    /// re-fits the tmux client grid — the same path as a window resize.
    /// Pin the terminal below the window's chrome using AppKit's own
    /// `contentLayoutGuide`, and fill the band above it with the theme colour.
    ///
    /// Constraints rather than arithmetic on purpose. The chrome's height
    /// changes when the native tab bar appears or goes — and with
    /// `.fullSizeContentView` that happens WITHOUT the window or the content
    /// view resizing, so nothing fires a layout pass and nothing is there to
    /// recompute. Earlier attempts (safe-area insets, then KVO on
    /// `contentLayoutRect`) each got the value or the timing wrong and left the
    /// terminal under the tab bar, or a dead band where it used to be. The
    /// layout guide is maintained by AppKit itself, so there is no moment to
    /// miss.
    private func installContentConstraints(in win: NSWindow) {
        guard let guide = win.contentLayoutGuide as? NSLayoutGuide else { return }
        container.translatesAutoresizingMaskIntoConstraints = false
        topFill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: guide.topAnchor),
            container.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor),

            topFill.topAnchor.constraint(equalTo: contentRoot.topAnchor),
            topFill.bottomAnchor.constraint(equalTo: container.topAnchor),
            topFill.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            topFill.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
        ])
    }

    // MARK: Mode switch (Tiled ⇄ List)

    /// The toolbar's Tiled|List segmented control picked `mode`. Mode switches
    /// are lossless and unconfirmed by design, with one exception: flattening a
    /// mixed external structure into List can't be exactly restored, so
    /// `setMode` declines and we warn before forcing.
    private func requestMode(_ mode: TmuxSessionMode) {
        guard let tab = activeTab, !tab.isPlain else { return }
        let vm = tab.viewModel
        Task { [weak self] in
            let switched = await vm.requestMode(mode)
            guard !switched, let self else { return }
            let copy = SessionPromptCopy.flatten
            let alert = NSAlert()
            alert.messageText = copy.title
            alert.informativeText = copy.message ?? ""
            alert.addButton(withTitle: copy.confirm)
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: self.window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    Task { await vm.setMode(mode, force: true) }
                } else {
                    // Snap the segmented control back to the real mode.
                    if let self { self.toolbar.setSessionMode(self.toolbarMode(for: self.tab)) }
                }
            }
        }
    }

    /// Move this window onto session `id` (same server — see
    /// `BentoTerminalWindow.focusOrOpen`). The view model follows tmux's
    /// `%session-changed`: name, windows, panes, mode and sizing are re-read,
    /// and `migrateSessionKey` carries this window's identity across. If the
    /// switch is refused (the session vanished between the menu and the
    /// click), the session opens in a window of its own rather than nowhere.
    func switchSession(to id: TmuxSessionID) {
        let vm = tab.viewModel
        Task { [weak self] in
            let ok = await vm.switchOrCreateSession(id.name)
            guard let self else { return }
            if ok {
                self.bringToFront()
                BentoTerminalWindow.recordSessionInUse(id)
                if id.isLocal { BentoTerminalWindow.onLocalServerChanged?() }
            } else {
                BentoTerminalWindow.openInNewWindow(id)
            }
        }
    }

    /// The Parallel/Focus switch, unless the session is a single pane — then
    /// there is nothing to arrange and the window should read as a plain
    /// terminal (`SessionChrome`). nil hides it.
    private func toolbarMode(for tab: SessionTab) -> TmuxSessionMode? {
        guard !tab.isPlain else { return nil }
        let vm = tab.viewModel
        guard SessionChrome.showsModeSwitch(paneCount: vm.sessionPanes.count,
                                            windowCount: vm.windows.count) else { return nil }
        return vm.sessionMode
    }

    /// Close the window (sessions survive on the server). `close()` is direct and
    /// always fires `windowWillClose` — more reliable than the traffic-light path.
    func requestClose() { window.close() }

    /// The native tab bar's `+`. AppKit sends this up the responder chain, so a
    /// window answering it is what makes the button create a SESSION rather
    /// than a duplicate of this one.
    @objc func newWindowForTab(_ sender: Any?) { BentoTerminalWindow.newSessionTab() }

    func bringToFront() {
        // `orderFrontRegardless` used to be here because an LSUIElement app that
        // had just flipped to `.regular` didn't reliably get key on the first
        // `activate`, and the window could open *behind* whatever the user was
        // in. That flip is gone — the app is always `.regular` — but this is
        // still reached from places where BentoTerm is not the active app (the
        // Dock icon, a URL/reopen, the toolbar's session menu acting on another
        // window), and the ordering guarantee is exactly what those want.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: Open / select / close


    /// Every session that exists right now: the poll's list plus any loaded tab not
    /// yet reflected by the poll (just-created).




    /// Pushed from the app's `tmux ls` poll — the LOCAL machine's session list.
    ///
    /// This used to also decide whether this window's session was still alive,
    /// and that was wrong the moment a window could be attached to a different
    /// tmux server: a remote session is never in the local list, so a remote
    /// window counted a miss every 5s and closed itself on the fourth. The
    /// liveness question moved to `sessionListChanged`, which asks the server
    /// this window is actually on. What is left here is presentation: the
    /// dormant local sessions a window can offer to open.
    func updateLocalServerSessions(_ names: [LocalTmuxSessionName]) {
        localServerSessions = names
        rebuildTabBar()
    }

    /// This window's OWN tmux server answered `list-sessions`. When our session
    /// isn't in it, it was killed from somewhere else (another client, a
    /// `tmux kill-session`) and the window closes rather than sit on a dead
    /// client — the same rule as before, now asked of the right machine.
    private func sessionListChanged(generation: Int, names: [String]) {
        guard generation != lastSessionListGeneration else { return }
        lastSessionListGeneration = generation
        guard !tab.isPlain, !names.isEmpty else { return }
        if !names.contains(tab.id.name) {
            absentPolls += 1
            // One transient miss must not close a live tab — a busy server can
            // drop a session from one listing.
            if absentPolls >= Self.absentPollsToClose { window.close() }
        } else {
            absentPolls = 0
        }
        rebuildTabBar()
    }







    /// Install this window's one session. Called once, at construction — there
    /// is no tab switching inside a window any more, so nothing reparents.
    private func show(_ tab: SessionTab) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let content = tab.contentView
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        window.makeFirstResponder(content)
        window.title = displayTitle(for: tab)
        rebindActiveToolbar(tab)
        toolbar.setSessionMode(toolbarMode(for: tab))
        updateSidebar()
        rebuildTabBar()
    }

    /// Detach: close this window but leave the tmux session running on the
    /// server, so the next open reconnects it.
    private func detachActiveSession() { window.close() }

    /// Kill the active tmux session (destroys it) and drop its tab.
    private func killActiveSession() {
        guard let tab = activeTab, let window else { return }
        let name = tab.id.displayName
        // Kill Session is destructive AND irreversible — every window/pane and
        // its running processes die. Confirm first (parity with iOS) so a stray
        // click doesn't silently end a session with work in it.
        let copy = SessionPromptCopy.killSession(name)
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.message ?? ""
        alert.alertStyle = .warning
        let killButton = alert.addButton(withTitle: copy.confirm)
        alert.addButton(withTitle: "Cancel")
        killButton.keyEquivalent = ""   // require a deliberate click, not Return
        if #available(macOS 11.0, *) { killButton.hasDestructiveAction = true }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performKillSession(tab: tab)
        }
    }

    /// See `BentoTerminalWindow.killFrontmostSessionSkippingConfirmation`.
    func killActiveSessionWithoutConfirmation() {
        guard let tab = activeTab else { return }
        performKillSession(tab: tab)
    }

    private func performKillSession(tab: SessionTab) {
        // Kill over THIS window's own control channel.
        //
        // This used to shell out to the local `tmux` binary, which was fine
        // while every window was local and a destroy-your-work bug the moment
        // one wasn't: with a remote window focused, "Kill Session" killed the
        // LOCAL session that happened to share the name. The control channel is
        // the one thing in the window that knows which machine it is talking
        // to, so routing the kill through it makes local and remote the same
        // code path instead of two, and there is no name left for a local
        // command to misread. The old race that motivated the CLI (tearing the
        // pty down with the kill still in the write buffer) is handled inside
        // `killSession`, which now awaits tmux's reply first.
        let id = tab.id
        Task { [weak self] in
            await tab.viewModel.killSession()
            guard let self else { return }
            if id.isLocal { BentoTerminalWindow.onLocalServerChanged?() }
            self.localServerSessions.removeAll { $0.rawValue == id.name }
            // Stop the self-poll from closing us on a stale miss — the window
            // is going away right now either way.
            self.absentPolls = 0
            self.window.close()
        }
    }


    // MARK: Bindings

    /// Active tab → toolbar. The centre strip IS the window list now, so it has
    /// to rebuild whenever the session's windows or its current window change —
    /// a window opened from a tmux command line shows up here too.
    private func rebindActiveToolbar(_ tab: SessionTab) {
        activeCancellables.removeAll()
        toolbar.launchHost = tab.viewModel.launchHost
        tab.viewModel.$windows
            .combineLatest(tab.viewModel.$activeWindowID)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _, _ in
                guard let self, let tab, tab === self.activeTab else { return }
                self.rebuildTabBar()
            }
            .store(in: &activeCancellables)
        // Mode drives the toolbar's Tiled|List switch and the sidebar (List
        // only). Plain tabs have no mode — the switch hides — and neither does
        // a single-pane session (`SessionChrome`), so the switch also follows
        // the session's pane and window counts. The values are taken from the
        // publishers rather than re-read: `@Published` emits BEFORE the
        // property is assigned.
        tab.viewModel.$sessionMode
            .combineLatest(tab.viewModel.$sessionPanes.map(\.count),
                           tab.viewModel.$windows.map(\.count))
            .map { mode, panes, windows -> TmuxSessionMode? in
                SessionChrome.showsModeSwitch(paneCount: panes, windowCount: windows) ? mode : nil
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] mode in
                guard let self, let tab, tab === self.activeTab else { return }
                self.toolbar.setSessionMode(tab.isPlain ? nil : mode)
                self.updateSidebar()
                BentoTerminalWindow.refreshNewItemTitle()
            }
            .store(in: &activeCancellables)
        // The take-over banner. Its own subscription rather than a ride on the
        // pane/window churn: it changes rarely (and only after the view model
        // has let one answer settle), and it must still land on a window that is
        // otherwise doing nothing — the canvas can be taken away from a session
        // nobody is touching.
        tab.viewModel.$sessionSizeMismatch
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] mismatch in
                guard let self, let tab, tab === self.activeTab else { return }
                self.toolbar.sizeMismatch = mismatch
            }
            .store(in: &activeCancellables)
        // The dock's directory tree follows the FOCUSED pane: switching window
        // (⌘1..9) or selecting another tiled pane changes activePaneID, so
        // re-root the tree on it (fires immediately for the newly-active tab
        // too — its initial value seeds the first load).
        //
        // …and it follows `cd` inside that pane: tmux pushes each pane's
        // directory (`paneWorkingDirectories`, a `refresh-client -B`
        // subscription — nothing else would tell us, a process changing
        // directory raises no event). Keyed on the (pane, directory) PAIR so a
        // pane switch is one reload, not one per publisher. On a tmux too old
        // to push, the directory stays nil and this is the pane switch alone.
        tab.viewModel.$activePaneID
            .combineLatest(tab.viewModel.$paneWorkingDirectories)
            .map { pane, dirs in PaneDirectoryKey(pane: pane, directory: pane.flatMap { dirs[$0] }) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _ in
                guard let self, let tab, tab === self.activeTab else { return }
                self.previewDock.refreshTree()
            }
            .store(in: &activeCancellables)
        // The toolbar's centre title: what runs in the focused pane and where.
        // Same directory source as the tree above (tmux pushes it on cd); the
        // command comes off the list-panes poll. A pane the subscription has
        // not reported yet is asked once — otherwise a fresh window, or any
        // window on a tmux too old to push, would show no path at all.
        tab.viewModel.$activePaneID
            .combineLatest(tab.viewModel.$paneWorkingDirectories,
                           tab.viewModel.$sessionPanes)
            .map { pane, dirs, panes in
                PaneLocationKey(
                    pane: pane,
                    directory: pane.flatMap { dirs[$0] },
                    command: pane.flatMap { id in panes.first { $0.id == id }?.currentCommand })
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] key in
                guard let self, let tab, tab === self.activeTab else { return }
                self.applyLocationTitle(key, tab: tab)
            }
            .store(in: &activeCancellables)
    }

    /// Directory answered by the one-shot query, for the pane that was asked
    /// about — used only until the subscription reports that pane.
    private var queriedDirectory: (pane: TmuxPaneID, path: String)?

    private func applyLocationTitle(_ key: PaneLocationKey, tab: SessionTab) {
        var directory = key.directory
        if directory == nil, let pane = key.pane {
            if let q = queriedDirectory, q.pane == pane {
                directory = q.path
            } else if let paneVM = tab.viewModel.paneViewModels.first(where: { $0.paneID == pane }) {
                Task { [weak self, weak tab] in
                    guard let path = await paneVM.currentWorkingDirectory(),
                          let self, let tab, tab === self.activeTab,
                          tab.viewModel.activePaneID == pane else { return }
                    self.queriedDirectory = (pane, path)
                    self.applyLocationTitle(key, tab: tab)
                }
            }
        }
        let text = PaneLocationTitle.text(
            command: key.command, directory: directory,
            sshHost: tab.id.server.sshHost,
            home: NSHomeDirectory())
        toolbar.setLocation(text ?? displayTitle(for: tab))
    }

    /// Each tab's agent activity + live session name drive its tab in the strip.
    private func subscribe(_ tab: SessionTab) {
        var bag = Set<AnyCancellable>()
        tab.viewModel.$agentsWorking
            .combineLatest(tab.viewModel.$agentsWaiting,
                           tab.viewModel.$agentsDoneUnseen,
                           tab.viewModel.$activeTmuxSessionName)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _, _, _, name in
                guard let self else { return }
                if let tab, let name { self.migrateSessionKey(of: tab, to: name) }
                self.rebuildTabBar()
            }
            .store(in: &bag)
        // Liveness, from this window's own control channel (see
        // `sessionListChanged`). The generation counter — not the array — is
        // what is observed, so only a genuinely fresh answer from the server
        // counts as a poll.
        tab.viewModel.$sessionListGeneration
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] generation in
                guard let self, let tab else { return }
                self.sessionListChanged(
                    generation: generation, names: tab.viewModel.availableTmuxSessions)
            }
            .store(in: &bag)
        // A session that could not be brought up at all.
        //
        // `showError` has existed on the view model for as long as iOS has had
        // an alert bound to it; on macOS nothing was ever bound, so the flag
        // was raised into a void. The visible result was a window that simply
        // sat there — most reliably when the ssh host had no tmux, where the
        // remote's own `tmux: command not found` was already in hand and still
        // nobody was told. Reported as "the app crashed", because a window that
        // does nothing forever is indistinguishable from one.
        tab.viewModel.$showError
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] show in
                guard show, let self, let tab else { return }
                self.presentSessionFailure(tab: tab)
            }
            .store(in: &bag)
        // `ssh` asking for something. Until this existed, the question went into
        // the control-mode stream where nothing rendered it and nothing could
        // answer it, so a password-authenticated host simply timed out after
        // twelve seconds — and blamed tmux, which was innocent.
        tab.viewModel.$authPrompt
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] prompt in
                guard let prompt, let self, let tab else { return }
                self.presentAuthPrompt(tab: tab, prompt: prompt)
            }
            .store(in: &bag)
        tabCancellables[ObjectIdentifier(tab)] = bag
    }

    /// Ask for the password / passphrase / code that `ssh` is waiting on, and
    /// type it into the connection.
    ///
    /// The prompt is shown verbatim: which of several 2FA methods a host is
    /// asking for is exactly the thing a paraphrase would lose.
    private func presentAuthPrompt(tab: SessionTab, prompt: SSHAuthPrompt) {
        guard let window, authPromptAlert == nil else { return }

        let alert = NSAlert()
        alert.messageText = "\(tab.viewModel.host.name) is asking for \(prompt.kind.noun)"
        alert.informativeText = tab.viewModel.authPromptRejected
            ? "That didn’t work. \(prompt.text)"
            : prompt.text
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        let remember = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
        remember.state = .on
        let accessory = NSStackView(views: prompt.isStorable ? [field, remember] : [field])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 260, height: prompt.isStorable ? 52 : 22)
        alert.accessoryView = accessory
        // Without this the sheet opens with the buttons focused and the first
        // thing typed goes nowhere.
        alert.window.initialFirstResponder = field

        authPromptAlert = alert
        alert.beginSheetModal(for: window) { [weak self, weak tab] response in
            guard let self else { return }
            self.authPromptAlert = nil
            guard let tab else { return }
            if response == .alertFirstButtonReturn {
                tab.viewModel.submitAuthPrompt(field.stringValue,
                                               remember: prompt.isStorable && remember.state == .on)
            } else {
                // Cancelling an auth prompt cancels the connection: there is no
                // session behind this window to fall back to.
                tab.viewModel.cancelAuthPrompt()
                self.window?.close()
            }
        }
    }

    /// Show why a session never came up, and close the window with it — there
    /// is nothing behind this window to go back to.
    private func presentSessionFailure(tab: SessionTab) {
        guard let window, !failureAlertShown else { return }
        failureAlertShown = true
        let alert = NSAlert()
        alert.messageText = "Couldn’t open “\(tab.id.displayName)”"
        // The view model puts the remote's own stderr in here when it has it
        // (see `failWithRemoteDiagnosis`) — that text is the whole point of the
        // alert, so it is shown verbatim rather than summarised away.
        alert.informativeText = tab.viewModel.errorMessage
            ?? "The session could not be started."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.window?.close()
        }
    }

    private func unsubscribe(_ tab: SessionTab) {
        tabCancellables[ObjectIdentifier(tab)] = nil
    }

    /// A tmux rename — ours or another client's (`%session-renamed`) — changes
    /// the session's identity, and `sessionKey` IS that identity everywhere:
    /// the strip order, the active selection, persistence, and the kill CLI
    /// target. The key must follow, or the old name haunts the strip forever
    /// (the loaded tab keeps it "present" past every prune) while the new name
    /// shows up as a phantom dormant session — and Kill Session silently kills
    /// a name that no longer exists.
    private func migrateSessionKey(of tab: SessionTab, to name: String) {
        let old = tab.id
        guard !name.isEmpty, name != old.name else { return }
        // The SERVER doesn't change under a rename — only the name on it. A
        // remote `bento` renamed to `work` is still on that host, and carrying
        // the server across is what keeps it from colliding with a local `work`.
        let new = TmuxSessionID(server: old.server, name: name)
        // Killing a session does NOT detach its clients — tmux parks them on
        // another session. So "my session is now called X" has two meanings: a
        // rename (X is mine), or my session died and I've been re-homed onto
        // someone else's. If a window already shows X, this is the second case
        // and there is nothing here to keep: two windows on one session is a
        // duplicate, and the poll would never close it because X is alive.
        if let other = BentoTerminalWindow.manager(for: new.key), other !== self {
            window.close()
            return
        }
        tab.id = new
        // Drop the old name from a not-yet-refreshed poll snapshot so the next
        // one doesn't read this window's session as gone.
        localServerSessions.removeAll { $0.rawValue == old.name }
        absentPolls = 0
        // A switch (or rename) in the window you are using: that is now the
        // session in use. One in a background window changes nothing about
        // what you were looking at.
        if window.isKeyWindow || window.isMainWindow {
            BentoTerminalWindow.recordSessionInUse(tab)
        }
        // The pane host keys the sidebar by session; a switched session gets a
        // fresh one bound to the same view model.
        updateSidebar()
        MacAwaitingNotifier.shared.clear(sessionKey: old.key)
    }

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
    private func rebuildTabBar() {
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

        let tmuxWindows = tab.isPlain ? [] : tab.viewModel.windows
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
        // The centre is shared with the location title (which opens the
        // palette). A switcher for ONE window says nothing, and in Focus the
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
            toolbar.activeTabIsPlain = active.isPlain
            toolbar.sizingMode = active.viewModel.sizingMode
            toolbar.sizingOwner = active.viewModel.sizingOwner
            toolbar.sizingOwnerIsMe = active.viewModel.sizingOwnerIsMe
            toolbar.sizeMismatch = active.viewModel.sessionSizeMismatch
        }
    }


    /// Map a visible-segment index to an action: the trailing `⋯` pops the full
    /// window list; any other segment selects that window.
    private func segmentPicked(_ idx: Int) {
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
    ///   • color (filled only) — agent activity, highest priority first:
    ///     awaiting (amber) → done-unseen (green) → working (blue) → idle (gray).
    fileprivate enum SessionDot: String { case awaiting, doneUnseen, working, idle, dormant, plain }

    /// What the window, its native tab, and the toolbar's session button call
    /// this session. A remote one reads `name — host`, so two tabs on
    /// same-named sessions on different machines are tellable apart at a
    /// glance, rather than only after clicking one.
    private func displayTitle(for tab: SessionTab) -> String {
        if tab.isPlain { return tab.windowTitle }
        let live = tab.viewModel.activeTmuxSessionName ?? tab.id.name
        return TmuxSessionID(server: tab.id.server, name: live).displayName
    }

    /// Put the session name and its status on the native tab.
    ///
    /// A tab title is a plain string, so the dot rides IN it: an agent waiting
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

    /// nil = nothing worth colouring (idle / plain), so the tab keeps its
    /// ordinary title rather than wearing a grey dot that means "nothing".
    private func tabDotColor(_ dot: SessionDot) -> NSColor? {
        switch dot {
        case .awaiting:   return PaneState.awaitingInput(profile: "").nsColor
        case .doneUnseen: return PaneTitleBar.doneColor
        case .working:    return PaneState.working.nsColor
        case .idle, .dormant, .plain: return nil
        }
    }

    /// The dot for ANY session name: its own manager's live state when it's
    /// open here, a hollow ring when it only exists on the server.
    private func dot(forSession id: TmuxSessionID) -> SessionDot {
        guard let m = BentoTerminalWindow.manager(for: id.key) else { return .dormant }
        return m.sessionDot()
    }

    fileprivate func sessionDot() -> SessionDot {
        if tab.isPlain { return .plain }   // no tmux → a terminal glyph, not a dot
        let vm = tab.viewModel
        // Same priority as a window's status (`windowStatus`): something still
        // running outranks something that finished while you were away.
        if vm.agentsWaiting > 0    { return .awaiting }
        if vm.agentsWorking > 0    { return .working }
        if vm.agentsDoneUnseen > 0 { return .doneUnseen }
        return .idle           // open, no agent activity → filled gray
    }

    /// Rendered dot images keyed by (dot, appearance). `rebuildTabBar` runs on
    /// every poll tick / VM publish — re-rasterizing identical NSImages each time
    /// is wasted work, and the stable instances also let `updateTabs` skip
    /// re-assigning unchanged segment images. Appearance is in the key because
    /// the neutral dots resolve semantic label colors at draw time.
    private var dotImageCache: [String: NSImage] = [:]

    /// Render a session-dot (memoized). Neutral grays use semantic label colors
    /// so they adapt to light/dark; the agent colors are fixed.
    private func dotImage(for dot: SessionDot) -> NSImage {
        let key = "\(dot.rawValue)-\(window.effectiveAppearance.name.rawValue)"
        if let cached = dotImageCache[key] { return cached }
        let img: NSImage
        switch dot {
        case .awaiting:   img = dotImage(PaneState.awaitingInput(profile: "").nsColor, style: .filled) // yellow
        case .doneUnseen: img = dotImage(PaneTitleBar.doneColor, style: .filled)                       // green
        case .working:    img = dotImage(PaneState.working.nsColor, style: .filled)                    // blue
        case .idle:       img = dotImage(.secondaryLabelColor, style: .filled)                         // attached, idle
        case .dormant:    img = dotImage(.tertiaryLabelColor, style: .ring)                            // not attached
        case .plain:      img = glyphImage("apple.terminal")                                           // no-tmux terminal
        }
        dotImageCache[key] = img
        return img
    }

    /// A small SF Symbol used in place of the status dot (e.g. the plain-terminal
    /// tab's terminal glyph), tinted to the label color and appearance-resolved.
    private func glyphImage(_ symbol: String) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Terminal")?
            .withSymbolConfiguration(cfg) ?? NSImage()
        let img = NSImage(size: base.size)
        img.lockFocus()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.secondaryLabelColor.set()
            base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        }
        img.unlockFocus()
        img.isTemplate = false
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

    private func presentRenameSheet() {
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
    /// overflow "…" segment, a plain tab, or a strip mid-rebuild).
    private func windowMenuItems(forSegment index: Int) -> [NSMenuItem]? {
        guard !tab.isPlain, visibleWindows.indices.contains(index) else { return nil }
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

    // MARK: NSWindowDelegate

    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions)
        -> NSApplication.PresentationOptions {
        proposedOptions.union(.autoHideToolbar)
    }

    /// The window you are in is the session in use — the one launch and the
    /// Dock icon bring back — and its mode decides what ⌘N is called.
    func windowDidBecomeKey(_ notification: Notification) {
        BentoTerminalWindow.recordSessionInUse(tab)
        BentoTerminalWindow.refreshNewItemTitle()
    }

    func windowWillClose(_ notification: Notification) {
        BentoWindowFrame.release(window)
        // Free every session's surfaces BEFORE AppKit tears the window down.
        activeCancellables.removeAll()
        tabCancellables.removeAll()
        // Drop the sidebar's SwiftUI observation before the VMs are torn down.
        sidebarHosting.rootView = AnyView(EmptyView())
        sidebarHostKey = nil
        tab.contentView.removeFromSuperview()
        tab.teardown()
        window.toolbar = nil
        window.delegate = nil
        onEmpty?()
    }
}

/// A session window that gives its toolbar first refusal on right-clicks.
///
/// The window strip is an `NSToolbarItemGroup` rendered by AppKit, and its
/// control eats `rightMouseDown` without consulting the `menu` property — so a
/// context menu on a window tab cannot be installed the normal way. `sendEvent`
/// sees the event before dispatch, and `self` is by construction the window
/// that received it: safe attribution without an event monitor, which is what
/// made the previous title-bar menu act on the wrong session.
final class TerminalSessionWindow: NSWindow {
    /// Returns true when the click landed on the window strip and was handled.
    var onRightClick: ((NSPoint) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown, onRightClick?(event.locationInWindow) == true { return }
        super.sendEvent(event)
    }

    /// **Every** Bento window is built here — with a session or without one.
    ///
    /// The launcher used to build its own `NSWindow` with its own style mask and
    /// nothing else, which made it a different kind of window that merely looked
    /// adjacent: no toolbar, no tab group, no frame autosave. Every one of those
    /// was a separate visible bug, and they were one bug. A window with no
    /// session is not a different window; it is this window with nothing in it
    /// yet, so it is dressed by the same function and only its CONTENT differs.
    @MainActor
    static func makeShell() -> TerminalSessionWindow {
        let win = TerminalSessionWindow(
            contentRect: NSRect(origin: .zero, size: TerminalWindowManager.defaultContentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        // Native window tabs: same identifier → one tab group, and AppKit hides
        // the tab bar entirely at one tab, which is why a session strip only
        // appears once there is more than one session to switch between.
        win.tabbingIdentifier = "bento.terminal"
        // `.preferred` when we're about to tab: `.automatic` defers to the
        // system preference at a moment AppKit picks, and with this window's
        // hidden title + full-size content that ended in windows joined to a
        // group whose tab bar never appeared — sessions became invisible
        // 33-pixel strips offscreen. Stating the intent avoids the ambiguity;
        // `tabbingIdentifier` is set either way, so Merge All Windows and
        // dragging a tab out still work in both modes.
        win.tabbingMode = BentoTerminalWindow.shouldOpenAsTab ? .preferred : .automatic
        win.titleVisibility = .hidden
        // Full-size content: the sidebar column runs the window's full height
        // (Finder-style) and the title bar blends into the terminal — the
        // window chrome wears the ghostty theme's background.
        win.styleMask.insert(.fullSizeContentView)
        win.titlebarAppearsTransparent = true
        win.titlebarSeparatorStyle = .none
        return win
    }
}

/// The one saved frame every Bento window shares, and who currently holds it.
///
/// Frame autosave is per WINDOW NAME, and every Bento window — session or
/// launcher — wants the same remembered geometry, so they would all fight over
/// one name. AppKit settles it by refusing: a second live window claiming a
/// held name silently gets nothing. Whichever window opens into an empty screen
/// therefore holds the name, and the others ride its tab group's frame.
///
/// This was a one-shot `didRestoreFrame` flag once, set on the first window of
/// the process and never cleared, so after closing every window the next one
/// got no name at all — it neither restored the size you left nor recorded the
/// one you set. Ownership is released on close now, so the next window into an
/// empty screen picks it up again.
///
/// It lives outside `TerminalWindowManager` because the manager is not the only
/// thing that opens a Bento window: the launcher does too, and the launcher
/// having no way to RECORD a frame is exactly why resizing it used to be
/// thrown away. Claiming is idempotent for the current owner, which is what
/// makes filling a launcher in place a no-op here rather than a handover — the
/// name never passes through an unowned moment.
@MainActor
enum BentoWindowFrame {
    nonisolated static let name = "BentoMainTerminalWindow"

    private static weak var owner: NSWindow?

    static func owns(_ win: NSWindow) -> Bool { owner === win }

    /// Give `win` the autosave name if nobody holds it. Returns whether `win`
    /// holds it afterwards.
    @discardableResult
    static func claim(_ win: NSWindow) -> Bool {
        if owner === win { return true }
        guard owner == nil else { return false }
        owner = win
        win.setFrameAutosaveName(name)
        return true
    }

    /// Record the arrangement the user is leaving and hand the name back.
    ///
    /// The save is unconditional. Autosave only fires on move/resize and only
    /// for the name's owner, so without this a window closed straight after a
    /// resize — or any window that isn't the owner — left nothing behind. Tabs
    /// in a group share one frame, so whichever closes last writes the same
    /// answer.
    static func release(_ win: NSWindow) {
        win.saveFrame(usingName: name)
        guard owner === win else { return }
        // Hand the name back BEFORE the window goes away: AppKit rejects a
        // second window claiming an autosave name that is still held.
        win.setFrameAutosaveName("")
        owner = nil
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

/// A plain view that reports layout passes — the content column uses it to
/// re-inset the terminal container by the (toolbar) safe area whenever the
/// split view or window reshapes it.
private final class LayoutHookView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}
#endif

// MARK: - Session prompts as sheets

extension NSWindow {
    /// The landing question for a move into an unsettled session, as a sheet
    /// on this window; nil = cancelled. Pass it as a move's `chooseLanding`.
    func askMoveLanding(session: String) async -> MoveLanding? {
        let copy = SessionPromptCopy.landing(session)
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.message
        alert.addButton(withTitle: copy.joinCurrentWindow)
        alert.addButton(withTitle: copy.newWindow)
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: self) { response in
                switch response {
                case .alertFirstButtonReturn:  continuation.resume(returning: .joinCurrentWindow)
                case .alertSecondButtonReturn: continuation.resume(returning: .newWindow)
                default:                       continuation.resume(returning: nil)
                }
            }
        }
    }

    /// A one-field name prompt as a sheet on this window: the typed text, or
    /// nil if cancelled.
    func askName(_ prompt: SessionPromptCopy.Prompt, initial: String = "") async -> String? {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message ?? ""
        alert.addButton(withTitle: prompt.confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = prompt.placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: self) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn
                                    ? field.stringValue : nil)
            }
        }
    }
}

/// What the dock's directory tree is rooted on: the focused pane and the
/// directory tmux last pushed for it (nil until pushed, or on tmux < 3.2).
private struct PaneDirectoryKey: Equatable {
    let pane: TmuxPaneID?
    let directory: String?
}

private struct PaneLocationKey: Equatable {
    let pane: TmuxPaneID?
    let directory: String?
    let command: String?
}

/// The toolbar's centre title: `<program> · <path>`, or just `<path>` while the
/// pane sits at a bare shell prompt (the shell's name says nothing). A remote
/// session leads with its host — the same path on two machines is two places.
enum PaneLocationTitle {
    static func text(command: String?, directory: String?,
                     sshHost: String?, home: String) -> String? {
        let program = command.flatMap { cmd -> String? in
            let trimmed = cmd.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || AgentHookState.isInteractiveShell(trimmed) ? nil : trimmed
        }
        var place: String?
        if let directory, !directory.isEmpty {
            // `~` only for this Mac: a remote home is a different directory, and
            // its path is not ours to guess.
            place = sshHost == nil ? abbreviate(directory, home: home) : directory
        }
        if let sshHost {
            place = place.map { "\(sshHost): \($0)" } ?? sshHost
        }
        switch (program, place) {
        case let (p?, l?): return "\(p) · \(l)"
        case let (p?, nil): return p
        case let (nil, l?): return l
        default: return nil
        }
    }

    static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
