import BentoTmuxKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftUI
import BentoAgentKit
import BentoTerminalCore
/// Resolve the core product-layer ID (server+name), not BentoTmuxKit's wire `$N` ID.
public typealias TmuxSessionID = BentoTerminalCore.TmuxSessionID

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

    /// The session created when the window opens with no previous session.
    /// User-configurable (Settings → Sessions); defaults to the app name.
    public nonisolated static let defaultSessionNameKey = "default_session_name"
    private nonisolated static let fallbackDefaultSessionName = "bento"
    public nonisolated static var defaultSessionName: String {
        let raw = UserDefaults.standard.string(forKey: defaultSessionNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return fallbackDefaultSessionName }
        // tmux uses ':' and '.' as target separators — keep them out of names.
        return raw.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    /// App-provided hooks for toolbar actions that live in the app target.
    public static var onNewAgentSession: (() -> Void)?
    public static var onOpenSettings: (() -> Void)?
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

    public static func focusOrOpen(_ id: TmuxSessionID) {
        if let m = manager(for: id.key) {
            m.bringToFront()
        } else {
            open(choice: .createOrAttach(name: id.name), server: id.server,
                 title: titleFor(id))
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
        for m in managers { m.updateLocalServerSessions(names) }
        // An open launcher is showing this list as rows; push, don't poll.
        LauncherWindowController.serverSessionsChanged()
    }

    /// The last `tmux ls` the app pushed in. Kept here (not only fanned out to
    /// the managers) because the reopen path runs when there are none.
    private static var knownServerSessions: [LocalTmuxSessionName] = []

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

    nonisolated static let lastSessionsKey = "mac_last_terminal_sessions"
    /// The strip's stable left-to-right tab order, persisted so it survives
    /// relaunches instead of re-alphabetizing on every cold start.
    nonisolated static let sessionOrderKey = "mac_session_strip_order"
    public nonisolated static let autoHideToolbarFullscreenKey = "auto_hide_toolbar_fullscreen"

    static var autoHideToolbarInFullscreen: Bool {
        UserDefaults.standard.object(forKey: autoHideToolbarFullscreenKey) as? Bool ?? true
    }

    /// Open (or focus) the terminal window — the behavior when the app icon is
    /// clicked, and at launch.
    ///
    /// With no window yet: reconnect the session(s) that were open when the app
    /// last quit — unless the user emptied the screen by hand during THIS run,
    /// in which case the launcher comes up instead (see
    /// `closedEverythingByHand`). With nothing to reconnect, also the launcher.
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

    /// Menu-bar command: hand sizing back to this window. A one-shot re-fit
    /// used to live here and looked broken — tmux recomputes a window's size
    /// from its clients, so the push was undone as soon as any other client was
    /// used. This sets the sticky policy instead (see `TerminalSizingMode`).
    public static func trackActiveSessionSize() {
        frontmostManager()?.tab.viewModel.setSizingMode(.tracking)
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
        frontmostManager()?.tab.paneHost?.presentCommandPalette()
    }

    /// Open a file preview in the focused window's side dock (the default
    /// surface — ⌘click, palette, context menu all land here).
    static func openPreview(path: String, line: Int?, context: PathPreviewContext) {
        frontmostManager()?.openPreview(path: path, line: line, context: context)
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

    /// Set when the user closes the last session window by hand while the app
    /// stays alive. Cleared the moment a session window exists again, so it
    /// only ever describes "right now, on purpose, there is nothing open".
    /// `isTerminating` guards ⌘Q, which also empties `managers`.
    private static var closedEverythingByHand = false

    public static func openMainWindow() {
        if let m = frontmostManager() {
            m.bringToFront()
            return
        }
        guard !sessionRestoreSuppressed else { return }
        if closedEverythingByHand {
            openLauncherWindow()
            return
        }
        var last = (UserDefaults.standard.stringArray(forKey: lastSessionsKey) ?? [])
            .filter { !$0.isEmpty }
        // Reopening means RECONNECTING. Every window here goes up via
        // `new-session -A`, which creates the session when the name is absent —
        // so a name that outlived its session (killed elsewhere, or a scratch
        // session from a previous run) came back as a brand-new empty session
        // every single time the icon was clicked. Drop anything the server no
        // longer has; only the "nothing to reconnect" fallback below is allowed
        // to create. An empty poll means we haven't heard from tmux yet — trust
        // the list rather than throw it away.
        if !knownServerSessions.isEmpty {
            let live = Set(knownServerSessions.map(\.rawValue))
            last = last.filter { live.contains($0) }
        }
        if last.isEmpty {
            // Nothing to reconnect. This used to conjure a session named
            // `bento` that the user never asked for; it now opens a window that
            // ASKS — the launcher (docs/launcher-design.md §9). The window is
            // real either way, because "no windows at all" reads as a broken
            // app with a Dock icon; what changed is that its content is a
            // question rather than a guess.
            openLauncherWindow()
        } else {
            for name in last { newWindow(session: name) }
        }
        // Only LOCAL sessions are in `last` — see `persistOpenSessions`.
        // Front the FIRST one reopened, not the last: the list is in creation
        // order, so the first is the session this window group started as.
        (managers.first ?? frontmostManager())?.bringToFront()
    }

    static func persistOpenSessions() {
        // Only tmux sessions are reconnectable — plain tabs vanish on close, so
        // they never go into the "reopen last session" list.
        //
        // Sessions on an ssh host are deliberately left out as well, and it is
        // worth saying why, because "reopen what was open" would seem to want
        // them. Reopening means `new-session -A`, which CREATES when the name
        // is absent — which is why `openMainWindow` first prunes the list
        // against the sessions the server actually still has. For a remote host
        // that check is a network round trip that can hang, or stop on a
        // password / 2FA prompt, before the app has put a single window on
        // screen; and skipping the check is how you get a phantom empty session
        // created on the build box every time the Dock icon is clicked. So a
        // remote session is scoped to the run that opened it. The key format
        // already carries the host (`ssh://host/name`), so a later step that
        // wants to offer "reopen bento on gpu-box" as a deliberate, user-driven
        // action has everything it needs — it just must not happen unasked at
        // launch.
        let names = managers.map(\.tab)
            .filter { !$0.isPlain && $0.id.isLocal }
            .map(\.sessionKey)
        // Never write the list empty. "No reconnectable tab is open right now"
        // is not the same statement as "there is nothing to reconnect", and
        // this function cannot tell them apart — it is called from window
        // creation too, so opening a plain no-tmux terminal as your only window
        // used to silently wipe the record. That became a common path the
        // moment New Terminal without tmux was made the launcher's default
        // action: ⌘N ⏎ would cost you your restore list.
        //
        // Refusing to write empty is safe because a stale name cannot survive
        // being used: `openMainWindow` prunes the list against the sessions the
        // server actually still has before reopening anything, so the list
        // shrinks there instead — at the one moment we know the truth.
        guard !names.isEmpty else { return }
        UserDefaults.standard.set(names, forKey: lastSessionsKey)
    }

    /// Set before any window closes on the way out of ⌘Q, so quitting is
    /// recorded as "these were open" rather than as N separate tab closures.
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

    /// File → New Window (⌘N). Always something NEW — never "front the window
    /// you already have" — and what lands in it is the launcher.
    ///
    /// ⌘N used to create the window AND a session called `session-3`: a name
    /// the user never chose, in a directory nobody picked. Both halves of that
    /// are real intents, so they get a key each and both are honest — ⌘N opens
    /// a window and then asks what to put in it; ⌘⇧T says don't ask, give me a
    /// session now (docs/launcher-design.md §9).
    ///
    /// **It is no longer forced standalone.** `4f93e6b` made ⌘N ignore
    /// `newSessionPlacement` on the grounds that the preference answers "where
    /// does a new SESSION land" and pressing ⌘N had already answered it — which
    /// was true while ⌘N created a session outright. It doesn't now. What ⌘N
    /// produces is an empty window that is about to BECOME a session, so the
    /// preference applies to it exactly as it applies to every other route into
    /// a session; forcing a standalone window meant a tabs user got a stray
    /// window every time, and then their choice arrived in it rather than in
    /// the tab bar where they put everything else.
    public static func newSessionWindow() {
        openLauncherWindow()
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

    /// Lowest unused `session-N`. tmux is the real authority on the namespace,
    /// but these are the ones we have windows for, which is what avoids
    /// silently attaching to somebody else's session.
    static func nextSessionName() -> String {
        let open = openSessionKeys
        var n = max(open.count + 1, 2)
        var name = "session-\(n)"
        while open.contains(name) { n += 1; name = "session-\(n)" }
        return name
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

    /// Open a plain (no-tmux) tab running an arbitrary command (exec-style
    /// argv). Used by the first-run wizard to run agent install one-liners in
    /// a VISIBLE terminal — transparency over a hidden Process.
    public static func newCommandWindow(command: [String], title: String) {
        openPlain(title: title, command: command)
    }

    /// Where a new session lands: a tab in the existing group, or its own
    /// window. macOS already asks this question globally (System Settings →
    /// Desktop & Dock → "Prefer tabs when opening documents"), so the default
    /// is to follow it rather than invent a second answer; the override is for
    /// people who want Bento specifically different from the rest of their Mac.
    public enum NewSessionPlacement: String, CaseIterable, Sendable {
        case system, tab, window

        public var title: String {
            switch self {
            case .system: return "Follow System Setting"
            case .tab:    return "As a Tab"
            case .window: return "In a New Window"
            }
        }
    }

    public nonisolated static let newSessionPlacementKey = "mac_new_session_placement"

    public nonisolated static var newSessionPlacement: NewSessionPlacement {
        get {
            UserDefaults.standard.string(forKey: newSessionPlacementKey)
                .flatMap(NewSessionPlacement.init(rawValue:)) ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: newSessionPlacementKey) }
    }

    /// Whether the NEXT session should join the current tab group.
    ///
    /// A launcher window asks this too, and must: it is a session window whose
    /// session hasn't been chosen yet, so if sessions open as tabs then the
    /// question "what should I open?" belongs in a tab as well — otherwise
    /// answering it moves the answer from a window into the tab bar, or leaves
    /// a stray window behind.
    static var shouldOpenAsTab: Bool {
        switch newSessionPlacement {
        case .tab:    return true
        case .window: return false
        case .system: return NSWindow.userTabbingPreference == .always
        }
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
        closedEverythingByHand = false
        let m = TerminalWindowManager(tab: tab, adopting: shell)
        m.onEmpty = { [weak m] in
            managers.removeAll { $0 === m }
            // Closing a TAB says "I'm done with that session" and has to drop it
            // from the reopen list — otherwise names only ever accumulate and
            // every later click on the icon drags them all back.
            //
            // Closing the LAST window says "I'm done for now" and must NOT: that
            // list is the only record of what to reconnect, and writing it empty
            // would replace the user's session with a fresh default. Same for
            // ⌘Q, which closes every window in turn — the set at that moment is
            // exactly what should come back.
            // NOTE: the activation policy is NOT touched here. BentoTerm is an
            // ordinary app — it stays `.regular` with its Dock icon even with no
            // windows left, which is how you get back in. Dropping to
            // `.accessory` (what the menu-bar build did) would now leave a
            // process with no Dock icon, no menu-bar item and no window: alive,
            // invisible and unquittable.
            if !managers.isEmpty && !isTerminating { persistOpenSessions() }
            // Closing your way down to nothing, by hand, while the app keeps
            // running, is a decision — and it is a different decision from
            // quitting. Quitting and coming back says "I was in the middle of
            // something"; clearing the screen and then clicking the Dock icon
            // says "I tidied up, now show me what there is". So the reopen list
            // is kept (⌘Q still restores it on the next cold start) but this
            // run stops replaying it, and the Dock icon brings up the launcher
            // instead. Nothing is lost by asking: those sessions are still
            // running and the launcher lists them as its first section.
            if managers.isEmpty && !isTerminating { closedEverythingByHand = true }
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
        managers.first { $0.window.isKeyWindow } ?? managers.last
    }

    static func manager(for key: String) -> TerminalWindowManager? {
        managers.first { $0.tab.sessionKey == key }
    }

    private static func open(choice: TmuxStartChoice, server: TmuxServer, title: String,
                             adopting shell: TerminalSessionWindow? = nil) {
        let id = SessionTab.id(for: choice, on: server)
        if let existing = manager(for: id.key) {
            existing.bringToFront()
        } else {
            addWindow(for: SessionTab(choice: choice, server: server, title: title),
                      adopting: shell).bringToFront()
        }
        persistOpenSessions()
    }

    /// Turn a launcher window into a session window, in place.
    ///
    /// This is the one entry point that takes an existing window shell and
    /// gives it a session, and it exists because the launcher must not spawn:
    /// picking a session in a window that is asking you to pick one has to fill
    /// THAT window, or the act of choosing leaves two windows behind — the
    /// thing you chose, and the question you already answered.
    ///
    /// The session may nonetheless already be open in another window (you can
    /// press ⌘N and then pick a session that's up). Then there is nothing to
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
    static func fill(_ shell: TerminalSessionWindow, localSession name: String) -> Bool {
        fill(shell, choice: .createOrAttach(name: name), server: .local,
             title: titleFor(.local(name)))
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
            transport = LocalPtyTransport(
                command: ["ssh", "-t", sshHost, launch],
                isLocalLink: false,
                startsInTmuxControlMode: true)
        } else {
            transport = LocalPtyTransport(command: command)
        }
        let vm = TerminalViewModel(
            host: Host(name: server.sshHost ?? "Local"),
            transport: transport,
            environment: env)
        self.viewModel = vm
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
            let remote = PathPreviewContext.isRemoteShellCommand(command?.first)
            let sshBlock: @Sendable @MainActor () async -> String? = {
                "This is a remote (SSH) session — its files aren’t browsable here yet."
            }
            surface.pathPreviewContext = PathPreviewContext(
                source: LocalFileSource(),
                cwd: { [weak surface] in surface?.reportedPwd },
                hostLabel: "This Mac",
                isLocal: true,
                remoteBlock: remote ? sshBlock : nil)
            vm.onRawDataReceived = { [weak surface] data in
                DispatchQueue.main.async { surface?.feed(data) }
            }
            vm.onPredictionText = { [weak surface] text in surface?.setPredictedText(text) }
            self.plainSurface = surface
            self.paneHost = nil
        } else {
            self.paneHost = GhosttyTiledPaneHost(viewModel: vm, theme: theme)
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
    /// attached on exactly the same terms as a local one.
    static func remoteLaunchCommand(for choice: TmuxStartChoice, name: String) -> String {
        switch choice {
        case .createAgent(let spec):
            return TmuxControlMode.launchCommandLine(
                sessionName: name, path: spec.workingDir,
                command: spec.agentCommand.isEmpty ? nil : spec.agentCommand)
        case .shareWithDesktop(let target):
            return TmuxControlMode.launchCommandLine(
                sessionName: "\(target)-mobile", groupWith: target)
        case .createOrAttach, .noTmux:
            return TmuxControlMode.launchCommandLine(sessionName: name)
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
        sidebarItem = sidebar

        let contentVC = NSViewController()
        contentVC.view = contentRoot
        splitVC.addSplitViewItem(sidebar)
        splitVC.addSplitViewItem(NSSplitViewItem(viewController: contentVC))

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
        dock.maximumThickness = 720
        dock.isCollapsed = true
        dock.holdingPriority = NSLayoutConstraint.Priority(251)  // terminal flexes, dock holds
        dockItem = dock
        splitVC.addSplitViewItem(dock)
        // Inspector-style toolbar toggle (always present). The dock's first
        // tab is the focused pane's directory tree; the provider resolves the
        // CURRENT pane at load time, so the tree follows the user.
        toolbar.onTogglePreview = { [weak self] in self?.togglePreviewDock() }
        previewDock.treeContextProvider = { [weak self] in self?.activeTab?.previewContext }

        splitVC.splitView.autosaveName = "BentoSidebarSplit"
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
        // Open sessions raise their tab; a dormant one opens as a new tab.
        toolbar.onSelectSession = { key in BentoTerminalWindow.focusOrOpen(sessionKey: key) }
        toolbar.onOpenSearch = { [weak self] in
            guard let self else { return }
            self.tab.paneHost?.presentCommandPalette(from: self.toolbar.searchAnchor)
        }
        toolbar.onNewAgent = { BentoTerminalWindow.onNewAgentSession?() }
        toolbar.onNewTerminal = { BentoTerminalWindow.newSessionTab() }
        toolbar.onNewPlainShell = { BentoTerminalWindow.newWindowNoTmux() }
        toolbar.onNewSSHHost = { BentoTerminalWindow.newSSHWindow(host: $0) }
        toolbar.onNewRemoteTmuxHost = { BentoTerminalWindow.newTmuxWindow(host: $0) }
        toolbar.onOpenSettings = { BentoTerminalWindow.onOpenSettings?() }
        toolbar.onCloseWindow = { [weak self] in self?.activeTab?.viewModel.closeWindow() }
        toolbar.onSetSizingMode = { [weak self] mode in
            self?.activeTab?.viewModel.setSizingMode(mode)
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
        BentoTerminalWindow.persistOpenSessions()
    }

    /// The size a session window opens at when nothing is remembered.
    nonisolated static let defaultContentSize = NSSize(width: 980, height: 640)

    var activeTab: SessionTab? { tab }

    /// Open a preview in the side dock (expanding it) and bring the window front.
    func openPreview(path: String, line: Int?, context: PathPreviewContext) {
        previewDock.open(path: path, line: line, context: context)
        dockItem?.animator().isCollapsed = false
        window?.makeKeyAndOrderFront(nil)
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
        let bg = ThemeStore.shared.current.bg
        return NSColor(
            srgbRed: CGFloat((bg >> 16) & 0xff) / 255,
            green: CGFloat((bg >> 8) & 0xff) / 255,
            blue: CGFloat(bg & 0xff) / 255, alpha: 1)
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
            let switched = await vm.setMode(mode)
            guard !switched, let self else { return }
            let alert = NSAlert()
            alert.messageText = "Switch to Focus mode?"
            alert.informativeText = "This session contains a complex layout created "
                + "outside Bento. Switching will flatten every pane into its own window."
            alert.addButton(withTitle: "Flatten")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: self.window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    Task { await vm.setMode(mode, force: true) }
                } else {
                    // Snap the segmented control back to the real mode.
                    self?.toolbar.setSessionMode(vm.sessionMode)
                }
            }
        }
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
        toolbar.setSessionMode(tab.isPlain ? nil : tab.viewModel.sessionMode)
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
        let alert = NSAlert()
        alert.messageText = "Kill session “\(name)”?"
        alert.informativeText = "Every window and pane in this session is closed and its running processes are terminated. This can’t be undone."
        alert.alertStyle = .warning
        let killButton = alert.addButton(withTitle: "Kill Session")
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
        tab.viewModel.$windows
            .combineLatest(tab.viewModel.$activeWindowID)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _, _ in
                guard let self, let tab, tab === self.activeTab else { return }
                self.rebuildTabBar()
            }
            .store(in: &activeCancellables)
        // Mode drives the toolbar's Tiled|List switch and the sidebar (List
        // only). Plain tabs have no mode — the switch hides.
        tab.viewModel.$sessionMode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] mode in
                guard let self, let tab, tab === self.activeTab else { return }
                self.toolbar.setSessionMode(tab.isPlain ? nil : mode)
                self.updateSidebar()
            }
            .store(in: &activeCancellables)
        // The dock's directory tree follows the FOCUSED pane: switching window
        // (⌘1..9) or selecting another tiled pane changes activePaneID, so
        // re-root the tree on it (fires immediately for the newly-active tab
        // too — its initial value seeds the first load).
        tab.viewModel.$activePaneID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _ in
                guard let self, let tab, tab === self.activeTab else { return }
                self.previewDock.refreshTree()
            }
            .store(in: &activeCancellables)
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
        tabCancellables[ObjectIdentifier(tab)] = bag
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
        BentoTerminalWindow.persistOpenSessions()
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
                (key: id.key, label: id.displayName,
                 dot: dotImage(for: dot(forSession: id)), isOpen: openKeys.contains(id.key))
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
        // The centre is shared with the search field. A switcher for ONE window
        // says nothing, and in Focus the sidebar is already the window list — so
        // in both cases that space goes to search, which always has something to
        // offer.
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
        if vm.agentsWaiting > 0    { return .awaiting }
        if vm.agentsDoneUnseen > 0 { return .doneUnseen }
        if vm.agentsWorking > 0    { return .working }
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
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = tab.viewModel.activeTmuxSessionName ?? ""
        field.placeholderString = "session name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            tab.viewModel.renameSession(to: field.stringValue)
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
        let alert = NSAlert()
        alert.messageText = "Rename Window"
        alert.informativeText = "tmux stops auto-naming this window from what's running in it."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = vm.windowBodyName(id)
        field.placeholderString = "window name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            vm.renameWindow(id, to: field.stringValue)
        }
    }

    private func confirmCloseWindow(_ id: TmuxWindowID) {
        let vm = tab.viewModel
        let alert = NSAlert()
        alert.messageText = "Close “\(vm.windowDisplayName(id))”?"
        alert.informativeText = "Everything running in its panes stops."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            vm.closeWindow(id)
        }
    }

    private func promptMoveToNewSession(_ id: TmuxWindowID) {
        let alert = NSAlert()
        alert.messageText = "Move to New Session"
        alert.informativeText = "The window keeps running — it moves to the new session."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "session name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            // A typed name may match an EXISTING session, so this goes through
            // the same landing pipeline as a menu pick rather than assuming new.
            self?.moveWindow(id, to: field.stringValue)
        }
    }

    /// Run the move; a target session that hasn't settled into Parallel or Focus
    /// bounces back and asks where the window should land (same pipeline the
    /// sidebar uses — see `TerminalViewModel.moveWindow`).
    private func moveWindow(_ id: TmuxWindowID, to session: String,
                            landing: MoveLanding = .auto) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.tab.viewModel.moveWindow(id, toSession: session, landing: landing)
                == .needsLandingChoice else { return }
            let alert = NSAlert()
            alert.messageText = "Move to “\(session)”"
            alert.informativeText =
                "That session isn't settled into Parallel or Focus yet. Where should this land?"
            alert.addButton(withTitle: "Into Current Window (Parallel)")
            alert.addButton(withTitle: "As New Window (Focus)")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: self.window) { [weak self] response in
                switch response {
                case .alertFirstButtonReturn:
                    self?.moveWindow(id, to: session, landing: .joinCurrentWindow)
                case .alertSecondButtonReturn:
                    self?.moveWindow(id, to: session, landing: .newWindow)
                default: break
                }
            }
        }
    }

    // MARK: NSWindowDelegate

    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions)
        -> NSApplication.PresentationOptions {
        BentoTerminalWindow.autoHideToolbarInFullscreen
            ? proposedOptions.union(.autoHideToolbar)
            : proposedOptions
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
