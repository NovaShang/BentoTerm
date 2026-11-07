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
    var localServerSessions: [LocalTmuxSessionName] = []
    /// Consecutive self-polls in which this window's session was missing from
    /// its OWN server's session list.
    var absentPolls = 0
    private static let absentPollsToClose = 4
    /// The last `sessionListGeneration` acted on, so a Combine republish that
    /// isn't a fresh list can't be counted as a miss.
    private var lastSessionListGeneration = 0
    /// The tmux windows currently shown as segments (a subset when they
    /// overflow the strip). Sessions moved to the named button on the left.
    var visibleWindows: [TmuxWindowID] = []

    let toolbar: TerminalToolbarController
    /// The window's content is the SYSTEM sidebar arrangement — an
    /// `NSSplitViewController` whose first item is a real sidebar split item.
    /// Material, full-height layout, animated collapse, drag-to-resize, and
    /// width persistence are all AppKit's; we only decide WHEN it shows
    /// (Focus mode) and WHAT it hosts (the shared SwiftUI `WindowSidebar`).
    ///
    /// A plain terminal's window has neither the sidebar nor the dock: both
    /// items are nil there, and everything that would open them belongs to
    /// the session toolbar, which a plain window doesn't build.
    private let splitVC = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem?
    private var sidebarHosting: NSHostingController<AnyView>?
    /// Trailing "pin previews here" dock — a collapsed split item that expands
    /// on the first pin. One model per window, persists across tab switches.
    let previewDock = PreviewDockModel()
    private var dockItem: NSSplitViewItem?
    /// Content column root. With `.fullSizeContentView` the column extends
    /// under the toolbar, so the terminal container is pinned below the chrome
    /// (see `installContentConstraints`).
    private let contentRoot = NSView()
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
    var hasOverflow = false
    // A local right-click monitor used to pop the session menu anywhere in the
    // titlebar band. It was written when the centre strip held SESSIONS, so
    // right-clicking a session showed that session's actions. The strip holds
    // WINDOWS now and sessions are native tabs with their own system menu, so
    // it had become: right-click anywhere up there, get the ACTIVE session's
    // actions — including Kill Session — while the user was pointing at a
    // different tab. Destructive action, wrong target, no way to tell. Removed;
    // the session's actions live in the named button on the left.

    /// Toolbar bindings to the *active* tab's VM (re-subscribed on switch).
    var activeCancellables = Set<AnyCancellable>()
    /// One failure alert per window — the view model can re-publish `showError`
    /// and the sheet must not stack.
    var failureAlertShown = false

    /// The auth sheet currently up, if any. One at a time: ssh asks its next
    /// question only after this one is answered.
    var authPromptAlert: NSAlert?
    /// Per-tab subscriptions (agent dots + tab titles), keyed by tab identity.
    var tabCancellables: [ObjectIdentifier: Set<AnyCancellable>] = [:]
    /// Directory answered by the one-shot query, for the pane that was asked
    /// about — used only until the subscription reports that pane.
    var queriedDirectory: (pane: TmuxPaneID, path: String)?
    /// Rendered dot images keyed by (dot, appearance). `rebuildTabBar` runs on
    /// every poll tick / VM publish — re-rasterizing identical NSImages each time
    /// is wasted work, and the stable instances also let `updateTabs` skip
    /// re-assigning unchanged segment images. Appearance is in the key because
    /// the neutral dots resolve semantic label colors at draw time.
    var dotImageCache: [String: NSImage] = [:]

    var onEmpty: (() -> Void)?

    init(tab: SessionTab) {
        self.tab = tab
        self.toolbar = TerminalToolbarController(isPlain: tab.isPlain)
        super.init()
        let win = TerminalSessionWindow.makeShell()
        win.delegate = self

        contentRoot.autoresizesSubviews = false
        topFill.wantsLayer = true
        contentRoot.addSubview(topFill)
        contentRoot.addSubview(container)

        let contentVC = NSViewController()
        contentVC.view = contentRoot
        if tab.isPlain {
            // One surface, nothing beside it: no sidebar, no dock.
            win.contentViewController = contentVC
            win.setContentSize(Self.defaultContentSize)
        } else {
            installSessionColumns(around: contentVC, in: win)
        }
        applyWindowBackground(to: win)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: .terminalThemeChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(surfaceBackgroundChanged(_:)),
            name: .ghosttySurfaceBackgroundChanged, object: nil)

        // A plain tab vanishes with its window — there's nothing to reconnect.
        toolbar.onCloseTab = { [weak self] in self?.window.close() }
        toolbar.hostWindow = win
        if !tab.isPlain { wireSessionToolbar(in: win) }
        win.toolbar = toolbar.makeToolbar()
        win.toolbarStyle = .unified
        // Restore size + position, but only for the window that opens into an
        // empty screen — the rest join its tab group (which shares one frame) or
        // cascade beside it, and AppKit refuses a duplicate autosave name anyway.
        if !BentoTerminalWindow.hasOpenWindows, BentoWindowFrame.claim(win) {
            if !win.setFrameUsingName(BentoWindowFrame.name) { win.center() }
        }
        self.window = win
        installContentConstraints(in: win)

        // Bring the session up. This used to live in `loadTab`, which ran when a
        // tab was added to the old multi-tab window; with one session per window
        // it belongs to construction — a window without these is a titled box
        // with nothing connected behind it.
        if tab.isPlain {
            var bag = Set<AnyCancellable>()
            subscribeFailure(tab, into: &bag)
            tabCancellables[ObjectIdentifier(tab)] = bag
        } else {
            subscribe(tab)
        }
        tab.connect()
        show(tab)
        if !tab.isPlain { BentoTerminalWindow.recordSessionInUse(tab.id) }
    }

    /// The session window's columns: the system sidebar arrangement — an
    /// `NSSplitViewController` whose first item is a real sidebar split item
    /// (native material, full-height layout, animated collapse, divider drag,
    /// width autosave) — plus the trailing preview dock.
    private func installSessionColumns(around contentVC: NSViewController, in win: NSWindow) {
        let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        sidebarHosting = hosting
        let sidebar = NSSplitViewItem(sidebarWithViewController: hosting)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 340
        sidebar.allowsFullHeightLayout = true
        sidebar.isCollapsed = true
        // The item's first-layout thickness comes from its view's frame — set
        // it to the new 50%-wider default (1.5× the 180 minimum) BEFORE the
        // split view ever lays out, or the window opens with the stale width.
        hosting.view.frame = NSRect(x: 0, y: 0, width: 270, height: 640)
        sidebarItem = sidebar

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
        // controller's fitting size (500 × 500 for this split view), so the
        // real size is set right after.
        win.contentViewController = splitVC
        win.setContentSize(Self.defaultContentSize)
        // The splitView autosave (kept for the sidebar width) also remembers
        // the dock's expanded state across window incarnations — a fresh
        // window would restore yesterday's EXPANDED dock with a brand-new,
        // empty, uncloseable model behind it. Dock visibility is model-driven
        // only: re-assert emptiness after the restoration that the
        // contentViewController assignment just applied (and once more next
        // runloop turn, in case restoration lands on first display).
        dock.isCollapsed = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dockItem?.isCollapsed = self.previewDock.tabs.isEmpty
        }
    }

    /// Toolbar: <session> ⌄ | [window tabs] | New ⌄ | ⋯ — the centre hosts the
    /// current session's tmux WINDOWS as a Finder-style segmented
    /// `NSToolbarItemGroup`; sessions live in the named button's menu on the
    /// left. That gives tmux's three levels three fixed places (session /
    /// window / pane) instead of leaving the middle one homeless.
    private func wireSessionToolbar(in win: TerminalSessionWindow) {
        toolbar.onSelectSegment = { [weak self] idx in self?.segmentPicked(idx) }
        // Picking a session moves THIS window onto it (switch-client); one
        // already up in another window comes forward instead. ⌥ / the row's
        // "Open in New Window" keeps this window and opens that one beside it.
        toolbar.onSelectSession = { key in BentoTerminalWindow.focusOrOpen(sessionKey: key) }
        toolbar.onOpenSessionInNewWindow = { key in
            if let id = TmuxSessionID(key: key) { BentoTerminalWindow.openInNewWindow(id) }
        }
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
        toolbar.onRenameSession = { [weak self] in self?.presentRenameSheet() }
        toolbar.onWindowMenu = { [weak self] index in self?.windowMenuItems(forSegment: index) }
        win.onRightClick = { [weak toolbar] point in
            toolbar?.handleRightClick(atWindowPoint: point) ?? false
        }
    }

    /// The size a session window opens at when nothing is remembered.
    nonisolated static let defaultContentSize = NSSize(width: 980, height: 640)

    var activeTab: SessionTab? { tab }

    /// Open a preview in the side dock (expanding it) and bring the window front.
    func openPreview(path: String, line: Int?, context: PathPreviewContext) {
        guard dockItem != nil else { return }
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
        dockItem?.animator().isCollapsed.toggle()
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
    /// management surface) and hides in Parallel.
    private var shouldShowSidebar: Bool {
        activeTab?.viewModel.sessionMode == .list
    }

    /// Create / swap / remove the hosted `WindowSidebar` to match the active
    /// tab and its mode, then re-derive the two content frames. Called on tab
    /// switch, mode change, and the toolbar toggle.
    func updateSidebar() {
        guard let sidebarItem, let sidebarHosting else { return }
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
        guard let tab = activeTab else { return }
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
    func sessionListChanged(generation: Int, names: [String]) {
        guard generation != lastSessionListGeneration else { return }
        lastSessionListGeneration = generation
        guard !names.isEmpty else { return }
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
        window.makeFirstResponder(tab.initialResponder)
        if tab.isPlain {
            window.title = tab.windowTitle
            toolbar.setSessionTitle(tab.windowTitle)
            return
        }
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
        killButton.hasDestructiveAction = true
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

    // MARK: NSWindowDelegate

    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions)
        -> NSApplication.PresentationOptions {
        proposedOptions.union(.autoHideToolbar)
    }

    /// The window you are in is the session in use — the one launch and the
    /// Dock icon bring back — and its mode decides what ⌘N is called.
    func windowDidBecomeKey(_ notification: Notification) {
        if !tab.isPlain { BentoTerminalWindow.recordSessionInUse(tab.id) }
        BentoTerminalWindow.refreshNewItemTitle()
    }

    func windowWillClose(_ notification: Notification) {
        BentoWindowFrame.release(window)
        // Free every session's surfaces BEFORE AppKit tears the window down.
        activeCancellables.removeAll()
        tabCancellables.removeAll()
        // Drop the sidebar's SwiftUI observation before the VMs are torn down.
        sidebarHosting?.rootView = AnyView(EmptyView())
        sidebarHostKey = nil
        tab.contentView.removeFromSuperview()
        tab.teardown()
        window.toolbar = nil
        window.delegate = nil
        onEmpty?()
    }
}
#endif
