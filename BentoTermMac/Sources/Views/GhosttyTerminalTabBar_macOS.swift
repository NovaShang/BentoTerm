import BentoSessionKit
import BentoFoundationKit
import BentoUISharedKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// The unified title-bar toolbar for a session window.
///
/// Each item is a stock bordered `NSButton` hosted in an `NSToolbarItem.view`,
/// so the icon and text sit side by side (a view-less item can only stack the
/// label below the icon) while macOS still styles the button per OS version
/// (borderless ≤14, bordered "glass" on 26+).
///
/// Layout (left → right):
///   [▢ <session> ⌄] [Parallel│Focus]  ⸺flex⸺  [ window tabs ]  ⸺flex⸺  [＋│▤]
///
/// The named left button carries the session (its switcher today, its actions
/// once sessions become native window tabs); the centre strip is the current
/// session's tmux WINDOWS, labelled `index:name` the way `list-windows` labels
/// them; New creates at every level (session / window / pane); ▤ toggles the
/// preview dock. Settings has no button here: it is opened once in a while,
/// and ⌘, plus the app menu are where every Mac app keeps it — a permanent
/// gear spent a toolbar slot on it.
@MainActor
final class TerminalToolbarController: NSObject, NSToolbarDelegate {
    /// New ⌄ → New Session…: the launcher, where every kind of session
    /// (agent, empty, plain shell, ssh host, a remembered launch) is offered.
    var onNewSession: (() -> Void)?
    var onRenameSession: (() -> Void)?
    var onDetach: (() -> Void)?
    var onKillSession: (() -> Void)?
    /// Session ⌄ → Release Size: back to tmux's default policy.
    var onReleaseSize: (() -> Void)?
    /// The active session's current sizing policy (whether Release shows).
    var sizingMode: TerminalSizingMode = .tracking
    /// Who owns the size under `.thisDevice`, and whether that's us — Release
    /// names the device it would take the size away from.
    var sizingOwner: TmuxSizingOwner?
    var sizingOwnerIsMe = false
    /// The take-over banner's state, or nil when this window's grid IS the
    /// session's. Settled by the view model (it only changes after the same
    /// answer has held for a couple of seconds), so this can be applied
    /// verbatim — nothing here debounces or second-guesses it.
    var sizeMismatch: SessionSizeMismatch? {
        didSet {
            guard sizeMismatch != oldValue else { return }
            applySizeMismatch()
        }
    }
    /// The banner was clicked and (where a named device is being dispossessed)
    /// confirmed: make this window the one that sets the session size.
    var onClaimSessionSize: (() -> Void)?
    var onCloseTab: (() -> Void)?
    /// The Tiled|List mode switch picked a mode (the manager runs `setMode`,
    /// warning first when a mixed external structure must be flattened).
    var onSelectMode: ((TmuxSessionMode) -> Void)?
    var onTogglePreview: (() -> Void)?

    /// The active tab is a plain (no-tmux) terminal — its menu is just "Close".
    var activeTabIsPlain = false

    /// False on a launcher window: this toolbar's window has no session YET.
    ///
    /// These items used to be DISABLED rather than removed, to keep every slot
    /// filled so that answering the launcher's question didn't shift the
    /// remaining controls sideways. That was reversed deliberately (user
    /// decision): the toolbar now shows only what the window can actually do, so
    /// the launcher does move its controls when a session arrives. A greyed
    /// control still has to be read and dismissed, and there were three of them
    /// on a screen whose whole job is to ask one question.
    var hasSession = true {
        didSet {
            guard hasSession != oldValue else { return }
            centerShowsTabs = hasSession
            applySessionAvailability()
        }
    }

    /// Where the active tab's session runs (`TerminalViewModel.launchHost`):
    /// nil = this Mac. The "+" menu's Recent Agents rows come from here, so a
    /// tab on a remote tmux offers what was launched THERE. Set by the window
    /// whenever it rebinds the toolbar to a tab.
    var launchHost: String?

    private func applySessionAvailability() {
        syncToolbarItems()
        setMenuText(sessionsButton, sessionsText)
        applyActionSegments()
    }

    /// Which items belong in the toolbar right now.
    ///
    /// - **Sessions** names the active session and lists the others: nothing to
    ///   name without one, and the launcher page below already IS that list.
    /// - **Parallel|Focus** reshapes a tmux session — meaningless on a launcher,
    ///   and on a plain terminal there are no panes to arrange.
    /// - **Preview** shows the focused pane's folder, so it needs a pane. A
    ///   PLAIN terminal keeps it: it has a real working directory (the shell's
    ///   OSC 7 report), which is exactly what the dock browses.
    /// - Search, New and Settings survive every state — searching, creating and
    ///   configuring are what a window with nothing in it is FOR.
    ///
    /// The window strip is not here: it is a variable-width list, and its slot
    /// is already shared with search by `setCenterShowsTabs`.
    private func syncToolbarItems() {
        guard let tb = toolbarRef else { return }
        setItem(Self.sessionsID, visible: hasSession, insertAt: 0)
        let afterSessions = tb.items.firstIndex { $0.itemIdentifier == Self.sessionsID }
            .map { $0 + 1 } ?? 0
        setItem(Self.modeID, visible: hasSession && wantsModeItem, insertAt: afterSessions)
        // The take-over banner rides in the toolbar rather than in a strip above
        // the panes, and that is deliberate: a strip would shrink the terminal,
        // which is the very grid the banner is comparing — it would keep
        // clearing its own condition and blink. The toolbar is chrome that was
        // already there, so it perturbs nothing.
        let afterMode = tb.items.firstIndex { $0.itemIdentifier == Self.modeID }
            .map { $0 + 1 } ?? afterSessions
        setItem(Self.sizeID, visible: hasSession && sizeMismatch != nil, insertAt: afterMode)
    }

    /// Add or remove the toolbar ITEM — not just its view.
    ///
    /// Setting `isHidden` on the view leaves the `NSToolbarItem` in place, and
    /// the item draws its own background: a plain terminal showed an empty
    /// switch-shaped capsule with no labels in it, the control gone but the
    /// thing it sat in still there. Removing the item is what the centre strip
    /// already does to swap tabs for search.
    private func setItem(_ id: NSToolbarItem.Identifier, visible: Bool, insertAt: Int) {
        guard let tb = toolbarRef else { return }
        let existing = tb.items.firstIndex { $0.itemIdentifier == id }
        if visible, existing == nil {
            tb.insertItem(withItemIdentifier: id, at: min(max(insertAt, 0), tb.items.count))
        } else if !visible, let existing {
            tb.removeItem(at: existing)
        }
    }

    /// A view to put in the search slot instead of the palette button.
    ///
    /// A session window has nothing to type INTO up there — the palette owns
    /// the query and the results — so its search item is a button that opens
    /// the palette. A launcher window is the opposite case: its query has
    /// nowhere else to live, and the page below it is the results. Same slot,
    /// same identifier, same position; the occupant differs because what the
    /// window can do with a keystroke differs.
    var customSearchView: NSView?
    /// EVERY tmux session on the machine, open here or not, with its dot.
    /// Native tabs can only switch between sessions that are already open, so
    /// without this list a session running on the machine but not loaded in
    /// Bento is unreachable — the tab bar has no row for it to appear in.
    /// `key` is the session's identity (`TmuxSessionID.key`) and `label` is what
    /// the row says. They differ for a session on an ssh host, whose row has to
    /// name the machine — showing the bare name would present it as a local
    /// session, and clicking it would then be a different session than it read.
    var sessions: [SessionRow] = []

    /// One row of the Sessions list.
    ///
    /// `key` is the session's identity (`TmuxSessionID.key`) and `label` is what
    /// the row says. They differ for a session on an ssh host, whose row has to
    /// name the machine.
    ///
    /// `info` is what the LOCAL `tmux ls` poll knows — and it is nil for a
    /// remote session on purpose, not by omission. Every per-session action
    /// below the row (rename, kill) is a `TmuxCLI` call against the local
    /// server; pointing one at a session on another machine is the exact bug
    /// `LocalTmuxSessionName` exists to prevent. A remote session's rename and
    /// kill live in its own window's toolbar, where they go over its own
    /// control channel.
    struct SessionRow {
        let key: String
        let label: String
        let dot: NSImage?
        /// Already loaded as a Bento tab — clicking focuses it rather than
        /// opening a second.
        let isOpen: Bool
        let local: LocalTmuxSessionName?
        let info: LocalSessionInfo?
    }
    var activeSessionKey: String?
    /// Go to that session in THIS window (or front the window it is open in).
    var onSelectSession: ((String) -> Void)?
    /// Keep this window, open that session in a new one — the row's "Open in
    /// New Window", or ⌥ held while picking.
    var onOpenSessionInNewWindow: ((String) -> Void)?

    private let sessionsButton = NSButton()
    /// Tiled|List — the session's structural mode, next to the session button.
    /// Reflects the active tab's `sessionMode`; hidden for plain (no-tmux) tabs.
    private let modeSwitch = NSSegmentedControl()
    /// New ⌄ and the preview toggle share one capsule — the two everyday
    /// right-hand actions read as one group rather than two loose buttons.
    private let actionsControl = NSSegmentedControl()
    /// Show/hide the preview dock (always present, like an inspector toggle).
    /// The take-over banner: present only while this window's grid differs from
    /// the session's (see `sizeMismatch`).
    private let sizeButton = NSButton()
    /// The sessions button's current label text — kept so its rasterized chevron
    /// can be rebuilt (with the same text) when the appearance changes.
    private var sessionsText = "Session"
    /// The session tabs, as a first-class segmented `NSToolbarItemGroup` (the way
    /// Finder builds its view-mode switcher) — NOT a control hosted in a view
    /// item, which macOS double-wraps in a group container. Rebuilt via the
    /// `titles:` convenience initializer (the same path Finder uses, which yields
    /// the real pill-selected segmented look) whenever the session set changes.
    private(set) var tabsGroup = NSToolbarItemGroup(itemIdentifier: TerminalToolbarController.centerID)
    var onSelectSegment: ((Int) -> Void)?
    /// Right-click on a window segment → that window's actions. The index is the
    /// segment the pointer is actually over; returning nil means "nothing there".
    var onWindowMenu: ((Int) -> [NSMenuItem]?)?

    /// The segmented control AppKit builds for the expanded item group. Found by
    /// traversal because `NSToolbarItemGroup` publishes no accessor — see
    /// `attachWindowMenu`.
    private weak var segmentedRef: NSSegmentedControl?
    /// The window this toolbar belongs to. Load-bearing, not a convenience:
    /// sessions are native tabs, so several windows carry an identical toolbar
    /// at once and a search that could wander into another one would hand this
    /// window's menu that window's tmux windows. Every lookup is fenced by it.
    weak var hostWindow: NSWindow? {
        didSet { observeHostWidth(old: oldValue) }
    }
    /// The toolbar that owns `tabsGroup` — so we can swap the group in place.
    private weak var toolbarRef: NSToolbar?
    /// Signature (title + dot) of the current segments. A group swap is needed
    /// whenever this changes — including a dot-only change, because mutating a
    /// live group's subitem images doesn't reliably re-render. Selection-only
    /// changes keep the same signature and just move `selectedIndex` in place.
    private var currentSig: [String] = []

    fileprivate static let sessionsID = NSToolbarItem.Identifier("bento.sessions")
    fileprivate static let modeID = NSToolbarItem.Identifier("bento.mode")
    fileprivate static let newID = NSToolbarItem.Identifier("bento.new")
    fileprivate static let centerID = NSToolbarItem.Identifier("bento.center")
    fileprivate static let sizeID = NSToolbarItem.Identifier("bento.size")
    fileprivate static let searchID = NSToolbarItem.Identifier("bento.search")
    fileprivate static let searchCompactID = NSToolbarItem.Identifier("bento.searchCompact")

    /// Opens the palette — the toolbar's search field is an ENTRY POINT, not a
    /// results view: the palette already knows how to search files, commands,
    /// sessions, windows and panes, so clicking here drops it open the way
    /// ⌘P does.
    var onOpenSearch: (() -> Void)?
    /// Wide, field-styled button shown in the centre when the window strip
    /// isn't needed; `searchCompact` is the magnifier that replaces it when the
    /// strip takes the centre.
    private let searchField = NSButton()
    private let searchCompact = NSButton()
    /// A SESSION window's centre at rest: where the focused pane is
    /// (`claude · ~/proj`), as quiet title text that opens the palette.
    ///
    /// It replaced the search-field button there (owner's call): a field-shaped
    /// control in the middle of every window was the loudest thing on screen
    /// and said nothing about the window. A title says where you are, and the
    /// palette is still one click (or ⌘P) away. The launcher keeps the field —
    /// it has no location to name and its whole job is the search.
    ///
    /// A stock toolbar button: the glass capsule and the leading magnifier are
    /// what say "this is clickable" (a borderless title read as a label).
    private let locationButton = NSButton()
    /// ~40% of the window: the location is the one variable-length item, and a
    /// deep path must truncate rather than shove the side items around.
    private var locationWidthCap: NSLayoutConstraint?
    private var centerShowsTabs = true

    override init() {
        super.init()
        // The left button is the CURRENT session's menu (named with the session,
        // like a document-title menu) — the discoverable home for per-session
        // actions. Its text is updated by the manager via `setSessionTitle`.
        configureMenu(sessionsButton, symbol: "macwindow", text: "Session",
                      action: #selector(sessionMenuTapped))
        // Tiled|List: the structure IS the mode, so this reads as a view switch
        // (lossless, instant) — the manager confirms only the mixed→List case.
        modeSwitch.segmentCount = 2
        modeSwitch.setLabel("Parallel", forSegment: 0)
        modeSwitch.setLabel("Focus", forSegment: 1)
        modeSwitch.trackingMode = .selectOne
        modeSwitch.controlSize = .large   // match the neighboring buttons
        modeSwitch.target = self
        modeSwitch.action = #selector(modeSwitched)
        modeSwitch.setToolTip("One window, tiled panes", forSegment: 0)
        modeSwitch.setToolTip("One pane per window, listed in the sidebar", forSegment: 1)
        modeSwitch.sizeToFit()
        // [＋ | ▤]: New (a menu) and the inspector-style preview dock toggle.
        actionsControl.trackingMode = .momentary
        actionsControl.controlSize = .large
        actionsControl.target = self
        actionsControl.action = #selector(actionSegmentTapped)
        applyActionSegments()
        configure(sizeButton, symbol: TerminalSizingMode.thisDevice.symbol, title: "",
                  action: #selector(sizeBannerTapped))
        configureSearchField()
        configureLocationButton()
        configure(searchCompact, symbol: "magnifyingglass", title: "", action: #selector(searchTapped))
        searchCompact.toolTip = "Search commands, files, sessions, windows, panes (⌘P)"
        configureGroup(tabsGroup)   // placeholder until the first updateTabs
        // The menu chevrons are rasterized (non-template) images — unlike the
        // dynamic `.labelColor` text they sit beside, they can't re-resolve on
        // an appearance change and would keep their baked color (white from a
        // dark launch, wrong on a light title bar). Rebuild them when the theme
        // / system light-dark flips. Fires on appearanceMode change AND system flip.
        NotificationCenter.default.addObserver(
            self, selector: #selector(chromeAppearanceChanged),
            name: .terminalThemeChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func chromeAppearanceChanged() {
        // Defer one runloop tick so the buttons' effectiveAppearance has settled
        // (a system light/dark flip updates it just after the notification).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setMenuText(self.sessionsButton, self.sessionsText)
        }
    }

    /// Update the left button to name the active session (keeps its icon/chevron).
    func setSessionTitle(_ name: String) {
        sessionsText = name.isEmpty ? "Session" : name
        setMenuText(sessionsButton, sessionsText)
    }

    /// Reflect the active tab's mode on the Tiled|List switch. nil = the tab
    /// has no tmux session (plain terminal) — the switch is meaningless there,
    /// so it goes away entirely.
    func setSessionMode(_ mode: TmuxSessionMode?) {
        wantsModeItem = (mode != nil)
        syncToolbarItems()
        guard let mode else { return }
        modeSwitch.selectedSegment = (mode == .tiled) ? 0 : 1
    }

    /// Whether the Layout item belongs in the toolbar at all. Kept as state
    /// because `setSessionMode` can run before `makeToolbar`, and the answer has
    /// to survive until there is a toolbar to apply it to.
    private var wantsModeItem = true

    @objc private func modeSwitched() {
        onSelectMode?(modeSwitch.selectedSegment == 1 ? .list : .tiled)
    }

    /// A button dressed as a search field: magnifier + placeholder, left
    /// aligned, wide enough to read as somewhere you type. It isn't an
    /// NSSearchField because there is nothing to type INTO — the palette owns
    /// both the query and the results, and two text fields for one query would
    /// be a state to keep in sync for no gain.
    private func configureSearchField() {
        searchField.bezelStyle = .roundRect
        searchField.controlSize = .large
        searchField.imagePosition = .imageLeading
        searchField.image = NSImage(systemSymbolName: "magnifyingglass",
                                    accessibilityDescription: "Search")
        searchField.alignment = .left
        // The magnifier and the placeholder are PROMPTS, not content, and the
        // button draws both at full label strength — the loudest thing in the
        // toolbar on the one item that has nothing to say yet.
        //
        // Two mechanisms, because one does not cover both: `contentTintColor`
        // colors the template image, but a BORDERED button (`.roundRect`) draws
        // its title with its own style and ignores the tint there — setting only
        // the tint left the text at full `labelColor`, i.e. near-black on light.
        // The title's color can only be set through `attributedTitle`.
        searchField.contentTintColor = .tertiaryLabelColor
        searchField.attributedTitle = NSAttributedString(
            string: "Search commands, files, sessions…",
            attributes: [
                .foregroundColor: NSColor.placeholderTextColor,
                // The button's own font: an attributed title with no font
                // attribute does not reliably inherit the control's, so leaving
                // it out would resize the text while recoloring it.
                .font: searchField.font
                    ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large)),
            ])
        searchField.target = self
        searchField.action = #selector(searchTapped)
        searchField.toolTip = "⌘P"
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
    }

    @objc private func searchTapped() { onOpenSearch?() }

    private func configureLocationButton() {
        let b = locationButton
        // A stock bordered toolbar button, like its neighbours: the capsule
        // plus the magnifier is what makes it read as something to click. A
        // borderless title was tried and read as a plain label nobody would
        // think to press. Quieter than the old search field anyway: it is only
        // as wide as its text and the text is the secondary colour.
        b.bezelStyle = .texturedRounded
        b.controlSize = .large
        b.image = NSImage(systemSymbolName: "magnifyingglass",
                          accessibilityDescription: "Search")
        b.imagePosition = .imageLeading
        b.contentTintColor = .secondaryLabelColor
        b.target = self
        b.action = #selector(searchTapped)
        b.toolTip = "Search commands, files, sessions (⌘P)"
        b.setAccessibilityLabel("Search commands, files, sessions")
        (b.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
        (b.cell as? NSButtonCell)?.truncatesLastVisibleLine = true
        // Size to the text, but give way (truncate) before anything else does.
        b.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.translatesAutoresizingMaskIntoConstraints = false
        let cap = b.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        cap.isActive = true
        locationWidthCap = cap
        setLocation("")
    }

    /// What the centre title says — `<program> · <path>`, already composed by
    /// the window (it knows the pane, the host and the shell rule).
    func setLocation(_ text: String) {
        let size = NSFont.systemFontSize
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        para.alignment = .center
        locationButton.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para,
            ])
        locationButton.invalidateIntrinsicContentSize()
    }

    private func observeHostWidth(old: NSWindow?) {
        let center = NotificationCenter.default
        if let old { center.removeObserver(self, name: NSWindow.didResizeNotification, object: old) }
        guard let hostWindow else { return }
        center.addObserver(self, selector: #selector(applyLocationWidthCap),
                           name: NSWindow.didResizeNotification, object: hostWindow)
        applyLocationWidthCap()
    }

    @objc private func applyLocationWidthCap() {
        guard let width = hostWindow?.frame.width, width > 0 else { return }
        locationWidthCap?.constant = (width * 0.4).rounded()
    }

    /// The centre occupant when the window strip isn't showing.
    private var centerSearchView: NSView {
        customSearchView ?? (hasSession ? locationButton : searchField)
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

    /// Whichever search control is currently on screen — the panel hangs off it.
    var searchAnchor: NSView {
        centerShowsTabs ? searchCompact : centerSearchView
    }

    /// The centre of the toolbar is shared: the window strip when the session
    /// has more than one window, otherwise the focused pane's location title
    /// (the search field on a launcher), which opens the palette.
    ///
    /// A single-window session is the common case, and a one-item switcher is
    /// chrome that says nothing. When the strip does take over, the palette
    /// entry shrinks to the magnifier beside New rather than disappearing.
    func setCenterShowsTabs(_ showTabs: Bool) {
        guard let tb = toolbarRef, showTabs != centerShowsTabs || tb.items.isEmpty else { return }
        centerShowsTabs = showTabs
        let want = showTabs ? Self.centerID : Self.searchID
        if let idx = tb.items.firstIndex(where: {
            $0.itemIdentifier == Self.centerID || $0.itemIdentifier == Self.searchID
        }), tb.items[idx].itemIdentifier != want {
            tb.removeItem(at: idx)
            tb.insertItem(withItemIdentifier: want, at: idx)
            tb.centeredItemIdentifiers = [want]
        }
        let compactIdx = tb.items.firstIndex { $0.itemIdentifier == Self.searchCompactID }
        if showTabs, compactIdx == nil,
           let newIdx = tb.items.firstIndex(where: { $0.itemIdentifier == Self.newID }) {
            tb.insertItem(withItemIdentifier: Self.searchCompactID, at: newIdx)
        } else if !showTabs, let compactIdx {
            tb.removeItem(at: compactIdx)
        }
    }

    private func configureGroup(_ g: NSToolbarItemGroup) {
        g.selectionMode = .selectOne
        g.controlRepresentation = .expanded
        g.target = self
        g.action = #selector(tabsGroupAction)
        g.label = "Windows"
    }

    /// Refresh the session segments (titles + agent dots) and the selection. The
    /// segmented control is rebuilt (via the `titles:` convenience initializer —
    /// the same path Finder uses, which renders the proper pill-selected segments)
    /// whenever a title OR a dot changes; a selection-only change just moves the
    /// `selectedIndex` in place.
    func updateTabs(_ items: [(title: String, key: String, image: NSImage?)], selected: Int) {
        let sig = items.map { "\($0.title)\u{1}\($0.key)" }
        if sig != currentSig {
            currentSig = sig
            swapGroup(titles: items.map(\.title))
        }
        for (i, sub) in tabsGroup.subitems.enumerated() where i < items.count {
            // Dot images are memoized upstream (same dot + appearance → same
            // instance), so an identity match means nothing to update — skip the
            // assignment rather than dirty the toolbar item every refresh. A
            // fresh group after swapGroup has nil images and always assigns.
            if sub.image !== items[i].image { sub.image = items[i].image }
        }
        if tabsGroup.subitems.indices.contains(selected) { tabsGroup.selectedIndex = selected }
        // The control is rebuilt with the group, so re-find it after AppKit has
        // laid the new one out. Cheap and idempotent (see attachWindowMenu).
        DispatchQueue.main.async { [weak self] in self?.attachWindowMenu() }
    }

    // MARK: - Window segment context menu

    /// Cache the segmented control AppKit renders for the expanded item group.
    ///
    /// It has to be found by walking the title bar's views: `NSToolbarItemGroup`
    /// has no accessor for the control it builds, and the group is swapped
    /// wholesale on every title/dot change. Idempotent; a miss just means no
    /// context menu until the next refresh.
    private func attachWindowMenu() {
        guard centerShowsTabs, let host = hostWindow else { return }
        if let seg = segmentedRef, seg.window === host,
           seg.segmentCount == tabsGroup.subitems.count { return }
        // The theme frame, so the search covers the title bar as well as content.
        guard let root = host.contentView?.superview,
              let seg = Self.findSegmented(in: root, count: tabsGroup.subitems.count)
        else { return }
        segmentedRef = seg
    }

    /// Right-click at `point` (window coordinates) — show that window tab's menu
    /// if the click landed on one. Returns true when handled, so the window can
    /// swallow the event.
    ///
    /// This is driven from `NSWindow.sendEvent` rather than the view's `menu`
    /// property, which looks like the obvious hook and does not work: the
    /// expanded group's control is SwiftUI-backed internally and consumes
    /// `rightMouseDown` without ever consulting `.menu` (measured — an
    /// NSEvent posted into the app's own queue never reached the delegate).
    /// `sendEvent` sees events before dispatch, and `self` is by construction
    /// the window that received the click — so unlike the global monitor this
    /// replaces, there is no way to attribute it to another window.
    func handleRightClick(atWindowPoint point: NSPoint) -> Bool {
        attachWindowMenu()
        guard centerShowsTabs, let seg = segmentedRef, seg.window === hostWindow else { return false }
        guard seg.convert(seg.bounds, to: nil).contains(point) else { return false }
        guard let host = hostWindow else { return false }
        guard let index = segmentIndex(in: seg, screenPoint: host.convertPoint(toScreen: point)),
              let items = onWindowMenu?(index), !items.isEmpty
        else {
            // Landed on the strip but not on a window (the overflow "…", or a
            // strip mid-rebuild). Swallow it: the stock toolbar menu is not
            // something to fall back to, and acting on a neighbouring window
            // would be worse than doing nothing.
            return true
        }
        let menu = NSMenu()
        for item in items { menu.addItem(item) }
        menu.popUp(positioning: nil, at: seg.convert(point, from: nil), in: seg)
        return true
    }

    private static func findSegmented(in view: NSView, count: Int) -> NSSegmentedControl? {
        if let s = view as? NSSegmentedControl, s.segmentCount == count, count > 1 { return s }
        for sub in view.subviews {
            if let found = findSegmented(in: sub, count: count) { return found }
        }
        return nil
    }

    /// Which segment the pointer is over, in screen coordinates.
    ///
    /// `NSSegmentedControl` publishes no point→segment API, and the three
    /// obvious substitutes are all dead ends here (measured, not assumed):
    /// `width(forSegment:)` reports 0 because the control is SwiftUI-backed
    /// internally, the view's `accessibilityChildren` is just its cell, and
    /// there is no `rectForSegment:`. The CELL, though, publishes one
    /// `NSAccessibilitySegment` per segment carrying a real screen frame, in
    /// order and non-overlapping — AppKit's own geometry rather than a
    /// reconstruction of it.
    ///
    /// Every assumption is rechecked on each call and any mismatch returns nil.
    /// This menu can close a window, and the last time something in the title
    /// bar acted on a target the user hadn't pointed at, it killed a live
    /// session — so guessing is not on the table.
    private func segmentIndex(in seg: NSSegmentedControl, screenPoint: NSPoint) -> Int? {
        guard let cell = seg.cell else { return nil }
        let kids = (cell as AnyObject).accessibilityChildren?() ?? []
        guard kids.count == seg.segmentCount else { return nil }
        for (i, kid) in kids.enumerated() {
            guard let frame = (kid as AnyObject).accessibilityFrame?() else { continue }
            if frame.contains(screenPoint) { return i }
        }
        return nil
    }

    /// Rebuild the group with the convenience initializer and re-insert it into
    /// the toolbar (the only way to get Finder's exact segmented appearance — a
    /// hand-built `subitems` array renders as faint plain text instead).
    private func swapGroup(titles: [String]) {
        let g = NSToolbarItemGroup(
            itemIdentifier: Self.centerID,
            titles: titles.isEmpty ? [""] : titles,
            selectionMode: .selectOne,
            labels: nil,
            target: self,
            action: #selector(tabsGroupAction))
        g.controlRepresentation = .expanded
        g.label = "Windows"
        tabsGroup = g
        guard centerShowsTabs, let tb = toolbarRef,
              let idx = tb.items.firstIndex(where: { $0.itemIdentifier == Self.centerID })
        else { return }
        tb.removeItem(at: idx)
        tb.insertItem(withItemIdentifier: Self.centerID, at: idx)
    }

    @objc private func tabsGroupAction() { onSelectSegment?(tabsGroup.selectedIndex) }

    func makeToolbar() -> NSToolbar {
        let tb = NSToolbar(identifier: "BentoTerminalToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        // Kill the stock title-bar context menu. `allowsUserCustomization = false`
        // only drops "Customize Toolbar…"; the Icon Only / Icon and Text display
        // options are governed separately and kept showing up on right-click.
        // They are meaningless here — every item is deliberately icon-only, and a
        // toolbar this small has no display mode worth choosing.
        if #available(macOS 15.0, *) { tb.allowsDisplayModeCustomization = false }
        // Pin the session strip to the WINDOW's center, independent of the side
        // items' widths — so the session-name button can size to its text without
        // ever nudging the tabs (the native alternative to hardcoding widths).
        tb.centeredItemIdentifiers = [hasSession ? Self.centerID : Self.searchID]
        toolbarRef = tb
        // State decided before the toolbar existed still has to land.
        syncToolbarItems()
        return tb
    }

    /// A plain action/icon button (no dropdown chevron).
    private func configure(_ b: NSButton, symbol: String, title: String, action: Selector) {
        b.bezelStyle = .texturedRounded
        b.controlSize = .large   // match the .large segmented tab strip's height
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? "More" : title)
        b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        b.title = title
        b.target = self
        b.action = action
        b.sizeToFit()
    }

    /// A menu button: leading icon (native image slot) + text + a vertically
    /// centered trailing `chevron.down` (a sized SF Symbol image embedded in the
    /// title, so it sits at the trailing edge instead of a misplaced "⌄" glyph).
    private func configureMenu(_ b: NSButton, symbol: String, text: String, action: Selector) {
        b.bezelStyle = .texturedRounded
        b.controlSize = .large   // match the .large segmented tab strip's height
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        b.imagePosition = .imageLeading
        b.target = self
        b.action = action
        setMenuText(b, text)
    }

    private func setMenuText(_ b: NSButton, _ text: String) {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let color: NSColor = b.isEnabled ? .labelColor : .disabledControlTextColor
        let title = NSMutableAttributedString(
            string: text + "  ",
            attributes: [.font: font, .foregroundColor: color])
        if let chevron = Self.chevronImage(pointSize: font.pointSize * 0.8,
                                           color: color,
                                           appearance: b.effectiveAppearance) {
            let att = NSTextAttachment()
            att.image = chevron
            att.bounds = CGRect(x: 0, y: (font.capHeight - chevron.size.height) / 2,
                                width: chevron.size.width, height: chevron.size.height)
            title.append(NSAttributedString(attachment: att))
        }
        b.attributedTitle = title
        b.sizeToFit()
    }

    /// `chevron.down` rendered in the label color (non-template so it keeps that
    /// color inside an attributed title). Because it's baked, the dynamic
    /// `.labelColor` must be resolved to a CONCRETE color for the CURRENT
    /// appearance — otherwise it keeps whatever it resolved to at build time
    /// (e.g. dark-mode white) and looks wrong on a light title bar. The menu
    /// buttons rebuild it via `chromeAppearanceChanged` when the theme flips.
    private static func chevronImage(pointSize: CGFloat, color: NSColor,
                                     appearance: NSAppearance) -> NSImage? {
        var label = color
        appearance.performAsCurrentDrawingAppearance {
            label = color.usingColorSpace(.sRGB) ?? color
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [label]))
        let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = false
        return img
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // ◧ | Sessions ⌄ | Tiled|List | ⸺flex⸺ | [session tabs] | ⸺flex⸺ | ＋│▤
        //
        // Same slots with no session — only the centre differs, and only
        // because a window strip with no windows in it is not a control that
        // can be disabled. Search takes the centre there, which is where a
        // one-window session puts it too.
        [Self.sessionsID, Self.modeID, .flexibleSpace,
         hasSession ? Self.centerID : Self.searchID,
         .flexibleSpace, Self.newID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The centre swaps between the window strip and the search field, and
        // the compact magnifier comes and goes with it, so both must be
        // ALLOWED even though only one of each pair is in the default set.
        // The size banner is never in the DEFAULT set — it exists only while the
        // canvas is someone else's — but an item can't be inserted unless it is
        // allowed.
        toolbarDefaultItemIdentifiers(toolbar) + [Self.searchID, Self.searchCompactID, Self.sizeID]
    }

    /// Segment 0 is always New; segment 1 (only with a session — a launcher
    /// has no panes to preview from) toggles the preview dock.
    private func applyActionSegments() {
        let count = hasSession ? 2 : 1
        if actionsControl.segmentCount != count { actionsControl.segmentCount = count }
        actionsControl.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "New"),
                                forSegment: 0)
        actionsControl.setToolTip("New pane, window or session", forSegment: 0)
        if count > 1 {
            actionsControl.setImage(NSImage(systemSymbolName: "sidebar.trailing",
                                            accessibilityDescription: "Preview"),
                                    forSegment: 1)
            actionsControl.setToolTip("Show/hide the file panel (⌥⌘P)", forSegment: 1)
        }
        actionsControl.sizeToFit()
    }

    @objc private func actionSegmentTapped() {
        switch actionsControl.selectedSegment {
        case 0: newTapped()
        case 1: onTogglePreview?()
        default: break
        }
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // The session tabs ARE a group item (Finder-style) — return it directly,
        // not wrapped in a view item, so macOS doesn't double-nest a container.
        if id == Self.centerID { return tabsGroup }
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.sessionsID: item.view = sessionsButton; item.label = "Session"
        case Self.modeID:     item.view = modeSwitch;     item.label = "Layout"
        case Self.newID:      item.view = actionsControl; item.label = "New"
        case Self.sizeID:     item.view = sizeButton;     item.label = "Session Size"
        case Self.searchID:   item.view = centerSearchView; item.label = "Search"
        case Self.searchCompactID: item.view = searchCompact; item.label = "Search"
        default: return nil
        }
        return item
    }

    // MARK: - Menus

    @objc private func sessionMenuTapped() {
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
        // No "Close Window" here: next to ⇧⌘W (which closes the MAC window and
        // leaves the session running) a row that killed the tmux window read
        // as the same thing. Killing a window lives on the strip and the
        // sidebar, beside the window it kills.
        //
        // No window SWITCH list here any more: windows own the centre strip, so
        // duplicating them in this menu would give the same thing two homes and
        // leave the user unsure which one is authoritative.
        return menu
    }


    /// Put the banner's copy on the button and add or drop its toolbar item.
    /// The button carries WHY the canvas looks wrong; the tooltip carries the
    /// two grids and what clicking will do, since a toolbar has no room for a
    /// second line.
    private func applySizeMismatch() {
        if let mismatch = sizeMismatch {
            // The button says what CLICKING does, not what is currently true.
            // It used to carry `title` — "Sized by the device used most
            // recently" — which reads on a control as though clicking would
            // make that happen, and is a sentence where there is room for a
            // label. The state it was reporting is in the tooltip below.
            sizeButton.title = mismatch.actionTitle
            sizeButton.imagePosition = .imageLeading
            // Tinted, because this is the one item that appears in order to be
            // noticed — everything else up here is permanent chrome.
            sizeButton.contentTintColor = .controlAccentColor
            // The state the button no longer says, plus the numbers behind it.
            sizeButton.toolTip = "\(mismatch.title) — \(mismatch.detail)."
            sizeButton.sizeToFit()
        }
        syncToolbarItems()
    }

    /// Click = make this window the size owner. Confirm ONLY when a named
    /// device is losing control it explicitly claimed; under the client-derived
    /// policies nobody claimed anything, so a sheet there is friction with
    /// no one on the other end.
    @objc private func sizeBannerTapped() {
        guard let mismatch = sizeMismatch else { return }
        guard mismatch.needsConfirmation else {
            onClaimSessionSize?()
            return
        }
        let alert = NSAlert()
        alert.messageText = mismatch.confirmTitle
        alert.informativeText = mismatch.confirmMessage
        alert.addButton(withTitle: mismatch.actionTitle)
        alert.addButton(withTitle: "Cancel")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onClaimSessionSize?()
        }
        if let window = hostWindow {
            alert.beginSheetModal(for: window, completionHandler: run)
        } else {
            run(alert.runModal())
        }
    }

    /// The quick creates, by tmux level: a session (via the launcher), a
    /// window, a pane, and the agents you already had open.
    ///
    /// The kinds of SESSION — agent, empty, a shell without tmux, an ssh host —
    /// live on the launcher page and nowhere else. This menu used to repeat all
    /// of them plus two "…at a Path…" rows, which made it the longest menu in
    /// the app for the rarest choices. Picking a folder and command stays where
    /// it's in context: the pane menu (splits) and the Focus sidebar (windows).
    ///
    /// The level is spelled out in each title ("New tmux Window", "Split
    /// Pane"): a bare "Window" reads as a Mac window everywhere else in the OS.
    @objc private func newTapped() {
        let menu = NSMenu()

        // One row for every kind of session: the launcher already lists them
        // (agent, empty, plain shell, ssh hosts, remembered launches), so
        // repeating them here was a second, longer copy of that page.
        menu.addItem(plainItem(
            symbol: "plus.rectangle", title: "New Session…",
            tip: "Choose what to open: an agent, an empty session, a shell or an ssh host.",
            action: #selector(newSessionAction)))

        // The window and pane levels need a session to create INSIDE. On a
        // launcher there isn't one, and these are dropped rather than disabled:
        // a menu is opened, read and closed, so its width and its rows are not
        // geometry anyone is relying on staying put — unlike the toolbar behind
        // it, where four greyed rows would just be a longer list to read past.
        // Rows from the shared catalog (PaneMenuLayout.macNewMenuSessionRows).
        // Creation goes through the responder chain, the same route the menu
        // bar and the pane menu use, so it lands on the pane host of whichever
        // tab is active.
        for row in PaneMenuLayout.macNewMenuSessionRows(hasSession: hasSession) {
            switch row {
            case .command(let command):
                menu.addItem(plainItem(
                    symbol: command.symbol(on: .macNewMenu),
                    title: command.title(on: .macNewMenu),
                    tip: command.tip(on: .macNewMenu) ?? "",
                    action: #selector(paneCommandAction(_:))))
                menu.items.last?.representedObject = command.rawValue
            case .separator:
                menu.addItem(.separator())
            case .recentAgents:
                // The middle ground between "whatever this pane is running"
                // and "type it all out": the agent you already had open in that
                // repo. Rows carry their record and are dispatched through the
                // responder chain like every other pane action here.
                let recents = GhosttyTiledPaneHost.recentAgentItems(
                    host: launchHost, target: self, action: #selector(splitRecentAction(_:)))
                if !recents.isEmpty {
                    menu.addItem(.separator())
                    let header = NSMenuItem(title: "Recent Agents", action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                    recents.forEach { menu.addItem($0) }
                }
            case .layouts, .moveToSession, .paste:
                break   // not New-menu rows
            }
        }

        pop(menu, from: actionsControl)
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

    @objc private func newSessionAction() { onNewSession?() }
    @objc private func closeTabAction() { onCloseTab?() }
    /// A catalog row from the New menu, dispatched through the responder chain
    /// to the active tab's pane host.
    @objc private func paneCommandAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = PaneCommand(rawValue: raw),
              let action = GhosttyTiledPaneHost.paneMenuSelector(command) else { return }
        BentoPaneAction.dispatch(action)
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

// MARK: - The ~/.ssh/config menu

/// The two ways to reach an ssh host, and the host list under each.
///
/// The launcher page's `SSH` row pops this. (The toolbar's `New ⌄` used to
/// carry the same two rows; it now sends you to the launcher instead.)
///
/// Hosts are re-read from `~/.ssh/config` on every open, so edits to the file
/// show up without a relaunch, and the read is a single small local file — the
/// launcher's "never block on the network" rule holds here too. Nothing
/// enumerates sessions on the far end.
enum SSHHostMenu {
    static let connectTitle = "New SSH Connection"
    static let connectTip = "A terminal connected to a host from your ~/.ssh/config."
    /// The same host list, but attaching a tmux session on the far end instead
    /// of dropping into its shell — the remote equivalent of "New Terminal",
    /// tiled panes and all. Its own row rather than a modifier on the one above
    /// because the two differ in what SURVIVES: the plain connection dies with
    /// the tab, the session doesn't.
    static let remoteTmuxTitle = "New Remote tmux Session"
    static let remoteTmuxTip = "A tiled tmux session running on a host from your ~/.ssh/config."

    /// The two rows, each with a host submenu. `representedObject` on the leaf
    /// items is the host alias.
    private static func items(target: AnyObject, connect: Selector, remoteTmux: Selector) -> [NSMenuItem] {
        let hosts = SSHConfigHosts.hosts()
        let ssh = row(symbol: "network", title: connectTitle, tip: connectTip)
        ssh.submenu = hostSubmenu(hosts: hosts, target: target, action: connect)
        // `nil` symbol on the second row: the icon marks where the group
        // starts, and repeating it says nothing the eye did not already get.
        let tmux = row(symbol: nil, title: remoteTmuxTitle, tip: remoteTmuxTip)
        tmux.submenu = hostSubmenu(hosts: hosts, target: target, action: remoteTmux)
        return [ssh, tmux]
    }

    /// The two rows as a standalone menu — what the launcher's `SSH` row pops.
    static func menu(target: AnyObject, connect: Selector, remoteTmux: Selector) -> NSMenu {
        let menu = NSMenu()
        for item in items(target: target, connect: connect, remoteTmux: remoteTmux) {
            menu.addItem(item)
        }
        return menu
    }

    private static func row(symbol: String?, title: String, tip: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
        item.toolTip = tip
        return item
    }

    /// One item per concrete host; a disabled hint when there are none —
    /// including a missing or unreadable config.
    private static func hostSubmenu(hosts: [String], target: AnyObject,
                                    action: Selector) -> NSMenu {
        let menu = NSMenu()
        guard !hosts.isEmpty else {
            menu.addItem(NSMenuItem(title: "No hosts in ~/.ssh/config",
                                    action: nil, keyEquivalent: ""))
            return menu
        }
        for host in hosts {
            let item = NSMenuItem(title: host, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = host
            menu.addItem(item)
        }
        return menu
    }
}

#endif
