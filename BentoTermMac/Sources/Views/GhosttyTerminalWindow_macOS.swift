import BentoTmuxKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftUI
import BentoSessionKit
import BentoUISharedKit

// MARK: - TerminalWindowManager (one window, the sessions open in it)

@MainActor
final class TerminalWindowManager: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow!
    /// The session this window is showing, one of `tabs`.
    private(set) var tab: SessionTab
    /// Every session and plain terminal open in this window, the one last shown
    /// at the end. Each keeps its own connection while another is on show, so
    /// the sidebar's states stay live and going back is instant; it ends when
    /// it is closed, detached or killed.
    private(set) var tabs: [SessionTab] = []
    /// Every tmux session on the LOCAL machine (pushed from the app's `tmux ls`
    /// poll). Only the dormant-session list for the strip — it says nothing
    /// about whether THIS window's session is alive when this window is remote.
    var localServerSessions: [LocalTmuxSessionName] = []
    private static let absentPollsToClose = 4
    /// The tmux windows currently shown as segments (a subset when they
    /// overflow the strip). Sessions moved to the named button on the left.
    var visibleWindows: [TmuxWindowID] = []

    let toolbar: TerminalToolbarController
    /// The window's content is the SYSTEM sidebar arrangement — an
    /// `NSSplitViewController` whose first item is a real sidebar split item.
    /// Material, full-height layout, animated collapse, drag-to-resize, and
    /// width persistence are all AppKit's. It hosts the shared SwiftUI
    /// `SessionSidebar`, and whether it shows is the user's (see
    /// `TerminalWindowManager+Sidebar`).
    private let splitVC = NSSplitViewController()
    private var sidebarHosting: NSHostingController<AnyView>?
    /// Trailing "pin previews here" dock — a collapsed split item that expands
    /// on the first pin. One model per window, persists across tab switches.
    let previewDock = PreviewDockModel()
    private var dockItem: NSSplitViewItem?
    /// Content column root. With `.fullSizeContentView` the column extends
    /// under the toolbar, so the terminal container is pinned below the chrome
    /// (see `installContentConstraints`).
    let contentRoot = NSView()
    private let container = NSView()
    /// Opaque theme-colored filler under the toolbar band. The unified
    /// toolbar's material samples the content BENEATH it — with the terminal
    /// inset below the safe area, that band would otherwise be undefined
    /// chrome, and the toolbar's frosting could never match the terminal.
    /// Frosting the theme color itself is the system-correct unified look
    /// (what Safari's toolbar does over page content).
    private let topFill = NSView()
    /// What the sidebar lists (filled by `rebuildSidebar`).
    let sidebarModel = SessionSidebarModel()
    /// Follows the sidebar being shown or put away, from any of its controls.
    private var sidebarCollapseObservation: NSKeyValueObservation?
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
    // the session's actions live on its sidebar row and in the Session menu.

    /// Toolbar bindings to the *active* tab's VM (re-subscribed on switch).
    var activeCancellables = Set<AnyCancellable>()
    /// The auth sheet currently up, if any. One at a time: ssh asks its next
    /// question only after this one is answered.
    var authPromptAlert: NSAlert?
    /// Per-tab subscriptions (status dots + tab titles), keyed by tab identity.
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

    /// `connect: false` for a session already up, moved here from another window.
    init(tab: SessionTab, connect: Bool = true) {
        self.tab = tab
        self.toolbar = TerminalToolbarController()
        super.init()
        let win = TerminalSessionWindow.makeShell()
        win.delegate = self

        contentRoot.autoresizesSubviews = false
        topFill.wantsLayer = true
        contentRoot.addSubview(topFill)
        contentRoot.addSubview(container)

        let contentVC = NSViewController()
        contentVC.view = contentRoot
        installColumns(around: contentVC, in: win)
        applyWindowBackground(to: win)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: .terminalThemeChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(surfaceBackgroundChanged(_:)),
            name: .ghosttySurfaceBackgroundChanged, object: nil)

        toolbar.hostWindow = win
        wireSessionToolbar(in: win)
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

        add(tab, connect: connect)
    }

    /// The window's columns: the system sidebar arrangement — an
    /// `NSSplitViewController` whose first item is a real sidebar split item
    /// (native material, full-height layout, animated collapse, divider drag,
    /// width autosave) — plus the trailing preview dock.
    private func installColumns(around contentVC: NSViewController, in win: NSWindow) {
        let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        sidebarHosting = hosting
        let sidebar = NSSplitViewItem(sidebarWithViewController: hosting)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 340
        sidebar.allowsFullHeightLayout = true
        sidebar.canCollapse = true
        sidebar.isCollapsed = !Self.sidebarPreferred
        // The item's first-layout thickness comes from its view's frame — set
        // it to the new 50%-wider default (1.5× the 180 minimum) BEFORE the
        // split view ever lays out, or the window opens with the stale width.
        hosting.view.frame = NSRect(x: 0, y: 0, width: 270, height: 640)

        let contentItem = NSSplitViewItem(viewController: contentVC)
        // The terminal's floor. The dock has no ceiling (see below), so this is
        // what stops a dock drag from squeezing the terminal to nothing and
        // resizing tmux to a pathological column count.
        contentItem.minimumThickness = 400
        // The title bar and what's under it are one surface. Per item: the
        // window's own setting doesn't reach a split view's columns.
        sidebar.titlebarSeparatorStyle = .none
        contentItem.titlebarSeparatorStyle = .none
        splitVC.addSplitViewItem(sidebar)
        splitVC.addSplitViewItem(contentItem)
        addPreviewDock()

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
        dockItem?.isCollapsed = true
        // The same restoration would bring back the sidebar as that split view
        // last had it; the user's last choice is the app-wide preference.
        sidebar.isCollapsed = !Self.sidebarPreferred
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dockItem?.isCollapsed = self.previewDock.tabs.isEmpty
        }
        wireSidebar()
        sidebarCollapseObservation = sidebar.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            let shown = !item.isCollapsed
            MainActor.assumeIsolated {
                UserDefaults.standard.set(shown, forKey: Self.sidebarShownKey)
                // The window strip's room changes with the column's width.
                DispatchQueue.main.async { self?.rebuildTabBar() }
            }
        }
    }

    /// The trailing column.
    private func addPreviewDock() {
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
        dock.titlebarSeparatorStyle = .none
        dock.isCollapsed = true
        dock.holdingPriority = NSLayoutConstraint.Priority(251)  // terminal flexes, dock holds
        dockItem = dock
        splitVC.addSplitViewItem(dock)
        // Inspector-style toolbar toggle (always present). The dock's first
        // tab is the focused pane's directory tree; the provider resolves the
        // CURRENT pane at load time, so the tree follows the user.
        toolbar.onTogglePreview = { [weak self] in self?.togglePreviewDock() }
        previewDock.treeContextProvider = { [weak self] in self?.activeTab?.previewContext }
    }

    /// Toolbar: [window tabs or location] | ＋ ▤ — the centre hosts the current
    /// session's tmux WINDOWS as a Finder-style segmented `NSToolbarItemGroup`.
    /// Sessions are the sidebar's, and their actions the Session menu's.
    private func wireSessionToolbar(in win: TerminalSessionWindow) {
        toolbar.onSelectSegment = { [weak self] idx in self?.segmentPicked(idx) }
        toolbar.onClaimSessionSize = { [weak self] in
            self?.activeTab?.viewModel.claimSessionSize()
            self?.rebuildTabBar()
        }
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

    /// Show/hide the dock without touching its tabs. A plain terminal has none.
    func togglePreviewDock() {
        guard !tab.isPlain else { return }
        dockItem?.animator().isCollapsed.toggle()
    }

    // MARK: Window chrome colour

    /// The window chrome wears the terminal's background, so the transparent
    /// title bar and any uncovered chrome read as one surface with the
    /// terminal (the ghostty look). The color of record is what the ENGINE
    /// says it renders (`reportedChromeColor`, from GHOSTTY_ACTION_COLOR_CHANGE
    /// — it reflects the user's own ghostty config and runtime OSC 11); the
    /// configured theme is only the pre-first-report fallback.
    private func applyWindowBackground(to win: NSWindow) {
        // With panes as cards the chrome is the desk they lie on.
        let color = tab.paneHost?.deskColor ?? reportedChromeColor ?? themeBackgroundColor()
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
              view.window === window, view.isDescendant(of: tab.contentView),
              let color = view.reportedBackgroundColor else { return }
        reportedChromeColor = color
        applyWindowBackground(to: window)
    }

    /// Bring the sidebar up to date. Its visibility is the user's alone now —
    /// it used to be pinned open in Focus and absent in Parallel, which left
    /// Parallel with no list at all and Focus with no way to put it away.
    func updateSidebar() {
        rebuildSidebar()
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

    // MARK: Split ⇄ alone (Tiled ⇄ List)

    /// The sidebar asked for the session split (a session row) or a pane alone
    /// (a pane row). Structure changes are lossless and unconfirmed by design,
    /// with one exception: flattening a mixed external structure into List
    /// can't be exactly restored, so `setMode` declines and we warn before
    /// forcing.
    func requestMode(_ mode: TmuxSessionMode) {
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

    /// `tab`'s OWN tmux server answered `list-sessions`. When its session isn't
    /// in it, it was killed from somewhere else (another client, a
    /// `tmux kill-session`) and it closes here rather than sit on a dead client — the same rule as before, now asked of the right machine.
    func sessionListChanged(of tab: SessionTab, generation: Int, names: [String]) {
        guard generation != tab.lastSessionListGeneration else { return }
        tab.lastSessionListGeneration = generation
        guard !names.isEmpty else { return }
        if !names.contains(tab.id.name) {
            tab.absentPolls += 1
            // One transient miss must not close a live tab — a busy server can
            // drop a session from one listing.
            if tab.absentPolls >= Self.absentPollsToClose { close(tab) }
        } else {
            tab.absentPolls = 0
        }
        rebuildTabBar()
    }

    /// Open `tab` in this window and show it.
    func add(_ tab: SessionTab, connect: Bool = true) {
        tabs.append(tab)
        let content = tab.contentView
        content.isHidden = true
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        tab.plainHost?.onClose = { [weak self, weak tab] in
            if let tab { self?.close(tab) }
        }
        tab.paneHost?.onDeskChanged = { [weak self, weak tab] in
            guard let self, let window = self.window, tab === self.tab else { return }
            self.applyWindowBackground(to: window)
        }
        if tab.isPlain {
            var bag = Set<AnyCancellable>()
            subscribeFailure(tab, into: &bag)
            tabCancellables[ObjectIdentifier(tab)] = bag
        } else {
            subscribe(tab)
        }
        if connect { tab.connect() }
        show(tab)
    }

    /// Show one of `tabs`; the others stay connected, out of sight.
    func show(_ tab: SessionTab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.append(tabs.remove(at: i))
        self.tab = tab
        for other in tabs {
            let onShow = other === tab
            other.contentView.isHidden = !onShow
            if onShow { other.viewModel.noteShown() } else { other.viewModel.isOnScreen = false }
        }
        tab.contentView.frame = container.bounds
        queriedDirectory = nil
        reportedChromeColor = tab.reportedBackground
        sidebarHosting?.rootView = AnyView(SessionSidebar(model: sidebarModel, viewModel: tab.viewModel))
        toolbar.isPlain = tab.isPlain
        if tab.isPlain {
            activeCancellables.removeAll()
            toolbar.setLocation("")
            toolbar.setSessionMode(nil)
            if let dockItem, !dockItem.isCollapsed {
                dockWasOpen = true
                dockItem.isCollapsed = true
            }
            localServerSessions = BentoTerminalWindow.knownServerSessions
        } else {
            rebindActiveToolbar(tab)
            toolbar.setSessionMode(toolbarMode(for: tab))
            if dockWasOpen { dockItem?.isCollapsed = false; dockWasOpen = false }
            previewDock.refreshTree()
            if window.isKeyWindow || window.isMainWindow || !window.isVisible {
                BentoTerminalWindow.recordSessionInUse(tab.id)
            }
        }
        applyWindowBackground(to: window)
        rebuildTabBar()
        window.makeFirstResponder(tab.initialResponder)
        tab.paneHost?.updateActiveBorders()
        BentoTerminalWindow.tabsChanged(from: self)
    }

    /// The file panel was open when a plain terminal, which has none, came on
    /// show.
    private var dockWasOpen = false

    /// Close one of `tabs`: its connection ends (a tmux session keeps running
    /// on its server) and the one shown before it comes back. The last one
    /// takes the window with it.
    func close(_ tab: SessionTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        guard tabs.count > 1 else { window.close(); return }
        remove(tab)
        tab.teardown()
    }

    /// Take `tab` out of this window without ending it. Never the last one.
    func remove(_ tab: SessionTab) {
        tabCancellables[ObjectIdentifier(tab)] = nil
        tabs.removeAll { $0 === tab }
        if tab === self.tab, let previous = tabs.last { show(previous) }
        tab.contentView.removeFromSuperview()
        tab.plainHost?.onClose = nil
        tab.paneHost?.onDeskChanged = nil
        rebuildTabBar()
        BentoTerminalWindow.tabsChanged(from: self)
    }

    /// The session `key` names, when it is open in this window.
    func sessionTab(_ key: String) -> SessionTab? {
        tabs.first { !$0.isPlain && $0.sessionKey == key }
    }

    /// Detach: end this window's connection to the session, which keeps
    /// running on the server.
    func detachActiveSession() { close(tab) }

    /// Hand the session's size back to tmux's default policy.
    func releaseSize() {
        tab.viewModel.releaseSessionSize()
        rebuildTabBar()
    }

    /// Kill the active tmux session (destroys it) and drop its tab.
    func killActiveSession() {
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

    func performKillSession(tab: SessionTab) {
        // Kill over the session's own control channel.
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
            if id.isLocal { self.localServerSessions.removeAll { $0.rawValue == id.name } }
            self.close(tab)
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
        BentoTerminalWindow.refreshMenuItems()
    }

    func windowWillClose(_ notification: Notification) {
        BentoWindowFrame.release(window)
        // Free every session's surfaces BEFORE AppKit tears the window down.
        activeCancellables.removeAll()
        tabCancellables.removeAll()
        // Drop the sidebar's SwiftUI observation before the VMs are torn down.
        sidebarCollapseObservation = nil
        sidebarHosting?.rootView = AnyView(EmptyView())
        for tab in tabs {
            tab.contentView.removeFromSuperview()
            tab.teardown()
        }
        window.toolbar = nil
        window.delegate = nil
        onEmpty?()
    }
}
#endif
