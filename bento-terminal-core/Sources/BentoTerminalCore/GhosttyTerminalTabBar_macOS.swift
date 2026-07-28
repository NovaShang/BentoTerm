#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftTmux

/// The unified title-bar toolbar for a session window.
///
/// Each item is a stock bordered `NSButton` hosted in an `NSToolbarItem.view`,
/// so the icon and text sit side by side (a view-less item can only stack the
/// label below the icon) while macOS still styles the button per OS version
/// (borderless ≤14, bordered "glass" on 26+).
///
/// Layout (left → right):
///   [▢ <session> ⌄] [Parallel│Focus]  ⸺flex⸺  [ window tabs ]  ⸺flex⸺  [＋ New ⌄] [⚙] [▤]
///
/// The named left button carries the session (its switcher today, its actions
/// once sessions become native window tabs); the centre strip is the current
/// session's tmux WINDOWS, labelled `index:name` the way `list-windows` labels
/// them; New creates at every level (session / window / pane) plus the two
/// non-tmux things; ⚙ opens Settings; ▤ toggles the preview dock.
@MainActor
final class TerminalToolbarController: NSObject, NSToolbarDelegate {
    var onNewAgent: (() -> Void)?
    var onNewTerminal: (() -> Void)?
    var onNewPlainShell: (() -> Void)?
    var onNewSSHHost: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onCloseWindow: (() -> Void)?
    var onRenameSession: (() -> Void)?
    var onDetach: (() -> Void)?
    var onKillSession: (() -> Void)?
    var onSetSizingMode: ((TerminalSizingMode) -> Void)?
    /// The active session's current sizing policy (drives the checkmark).
    var sizingMode: TerminalSizingMode = .tracking
    var onCloseTab: (() -> Void)?
    /// The Tiled|List mode switch picked a mode (the manager runs `setMode`,
    /// warning first when a mixed external structure must be flattened).
    var onSelectMode: ((TmuxSessionMode) -> Void)?
    var onTogglePreview: (() -> Void)?

    /// Every session Bento knows about, with its status dot — the left button's
    /// menu is the session switcher (the centre strip belongs to windows).
    var sessions: [(key: String, dot: NSImage?)] = []
    var activeSessionKey: String?
    var onSelectSession: ((String) -> Void)?
    /// The active tab is a plain (no-tmux) terminal — its menu is just "Close".
    var activeTabIsPlain = false

    private let sessionsButton = NSButton()
    /// Tiled|List — the session's structural mode, next to the session button.
    /// Reflects the active tab's `sessionMode`; hidden for plain (no-tmux) tabs.
    private let modeSwitch = NSSegmentedControl()
    private let newButton = NSButton()
    private let moreButton = NSButton()
    /// Show/hide the preview dock (always present, like an inspector toggle).
    private let previewButton = NSButton()
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
    fileprivate static let moreID = NSToolbarItem.Identifier("bento.more")
    fileprivate static let centerID = NSToolbarItem.Identifier("bento.center")
    fileprivate static let previewID = NSToolbarItem.Identifier("bento.preview")
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
        configureMenu(newButton, symbol: "plus", text: "New", action: #selector(newTapped))
        // A plain gear that opens Settings directly (session actions moved to the
        // named session button on the left).
        configure(moreButton, symbol: "gearshape", title: "", action: #selector(settingsAction))
        moreButton.toolTip = "Settings"
        // Inspector-style toggle for the preview dock (file tree + previews).
        configure(previewButton, symbol: "sidebar.trailing", title: "",
                  action: #selector(previewTapped))
        previewButton.toolTip = "Show/hide the file panel (⌥⌘P)"
        configureSearchField()
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
            self.setMenuText(self.newButton, "New")
        }
    }

    /// Update the left button to name the active session (keeps its icon/chevron).
    func setSessionTitle(_ name: String) {
        sessionsText = name.isEmpty ? "Session" : name
        setMenuText(sessionsButton, sessionsText)
    }

    /// Reflect the active tab's mode on the Tiled|List switch. nil = the tab
    /// has no tmux session (plain terminal) — the switch is meaningless there,
    /// so it hides.
    func setSessionMode(_ mode: TmuxSessionMode?) {
        modeSwitch.isHidden = (mode == nil)
        guard let mode else { return }
        modeSwitch.selectedSegment = (mode == .tiled) ? 0 : 1
    }

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
        searchField.title = "Search commands, files, sessions…"
        searchField.alignment = .left
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

    /// The centre of the toolbar is shared: the window strip when the session
    /// has more than one window, the search field when it doesn't.
    ///
    /// A single-window session is the common case, and a one-item switcher is
    /// chrome that says nothing — so that space goes to the thing that always
    /// has something to offer. When the strip does take over, search shrinks to
    /// the magnifier beside New rather than disappearing.
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
        // Pin the session strip to the WINDOW's center, independent of the side
        // items' widths — so the session-name button can size to its text without
        // ever nudging the tabs (the native alternative to hardcoding widths).
        tb.centeredItemIdentifiers = [Self.centerID]
        toolbarRef = tb
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
        let title = NSMutableAttributedString(
            string: text + "  ",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if let chevron = Self.chevronImage(pointSize: font.pointSize * 0.8,
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
    private static func chevronImage(pointSize: CGFloat, appearance: NSAppearance) -> NSImage? {
        var label = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
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
        // ◧ | Sessions ⌄ | Tiled|List | ⸺flex⸺ | [session tabs] | ⸺flex⸺ | New ⌄ | ⋯ | ◨
        [Self.sessionsID, Self.modeID, .flexibleSpace, Self.centerID,
         .flexibleSpace, Self.newID, Self.moreID, Self.previewID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The centre swaps between the window strip and the search field, and
        // the compact magnifier comes and goes with it, so both must be
        // ALLOWED even though only one of each pair is in the default set.
        toolbarDefaultItemIdentifiers(toolbar) + [Self.searchID, Self.searchCompactID]
    }

    @objc private func previewTapped() { onTogglePreview?() }

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
        case Self.newID:      item.view = newButton;      item.label = "New"
        case Self.moreID:     item.view = moreButton;     item.label = "Settings"
        case Self.previewID:  item.view = previewButton;  item.label = "Preview"
        case Self.searchID:   item.view = searchField;    item.label = "Search"
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
        // Every session, the current one checkmarked. This is the switcher
        // until sessions become native window tabs; then it goes away and only
        // the actions below remain.
        sessionSwitchSection(menu)
        // A plain (no-tmux) terminal has no session/windows — just close it.
        if activeTabIsPlain {
            add(menu, "Close Terminal", #selector(closeTabAction))
            return menu
        }
        add(menu, "Rename Session…", #selector(renameAction))
        menu.addItem(sizingMenuItem())
        menu.addItem(.separator())
        add(menu, "Detach (keep running)", #selector(detachAction))  // unload; session survives
        // Destructive, and one row away from Detach — which is its harmless
        // twin — so a separator keeps them from being adjacent targets.
        menu.addItem(.separator())
        add(menu, "Kill Session", #selector(killAction))
        menu.addItem(.separator())
        add(menu, "Close Window", #selector(closeWindowAction))
        // No window SWITCH list here any more: windows own the centre strip, so
        // duplicating them in this menu would give the same thing two homes and
        // leave the user unsure which one is authoritative.
        return menu
    }

    /// Sessions live behind the named button on the left: switching between
    /// them is a project-level move (rarer than switching windows) and the
    /// centre strip now belongs to the current session's windows.
    private func sessionSwitchSection(_ menu: NSMenu) {
        guard !sessions.isEmpty else { return }
        let header = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for session in sessions {
            let item = NSMenuItem(title: session.key,
                                  action: #selector(selectSessionAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = session.key
            item.image = session.dot
            item.state = (session.key == activeSessionKey) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    @objc private func selectSessionAction(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        onSelectSession?(key)
    }

    /// Who governs the window size — a checked pair, not a "do it now" button.
    /// The old single "Fit Session to This Window" was a one-shot that tmux
    /// undid as soon as any other client was used (see `TerminalSizingMode`).
    private func sizingMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Session Size", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                             accessibilityDescription: "Session Size")
        let sub = NSMenu()
        for mode in TerminalSizingMode.allCases {
            let it = NSMenuItem(title: mode.title, action: #selector(sizingAction(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode.rawValue
            it.state = (mode == sizingMode) ? .on : .off
            it.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.title)
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let note = NSMenuItem(
            title: sizingMode == .tracking
                ? "This window's size drives the session."
                : "Frozen — other clients can't reflow it either.",
            action: nil, keyEquivalent: "")
        note.isEnabled = false
        sub.addItem(note)
        root.submenu = sub
        return root
    }

    @objc private func sizingAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = TerminalSizingMode(rawValue: raw) else { return }
        onSetSizingMode?(mode)
    }

    /// Everything you can create, grouped by which level of tmux it lands on —
    /// session, then window, then pane — with the two non-tmux things last.
    ///
    /// The old list mixed levels and named them by adjective: "New Multi Pane
    /// Session" and "New Persistent Session" are both just tmux sessions
    /// ("multi pane" is a layout, not a kind; EVERY tmux session is
    /// persistent), and neither said anything about windows or panes, which
    /// you could only create from elsewhere entirely.
    @objc private func newTapped() {
        let menu = NSMenu()

        section(menu, "Session")
        menu.addItem(richItem(
            symbol: "sparkles", title: "New Session with Agent…",
            note: "Set up an agent (Claude, Codex…) in a fresh tmux session, optionally split into panes.",
            action: #selector(newAgentAction)))
        menu.addItem(richItem(
            symbol: "clock.arrow.circlepath", title: "New Empty Session",
            note: "A blank tmux session on the host — it keeps running after you disconnect.",
            action: #selector(newTerminalAction)))

        // Window and Pane offer the SAME two seeds — they differ only in where
        // the new thing lands, so making them differ in how you create it would
        // be an accident of history, not a distinction.
        section(menu, "Window")
        menu.addItem(richItem(
            symbol: "plus.rectangle.on.folder", title: "Duplicate Current",
            note: "A tmux window with the current pane's folder and command.",
            action: #selector(newWindowDuplicateAction)))
        menu.addItem(richItem(
            symbol: "rectangle.badge.plus", title: "Path & Command…",
            note: "A tmux window, choosing the folder and what to run in it.",
            action: #selector(newWindowPathCommandAction)))

        section(menu, "Pane")
        menu.addItem(richItem(
            symbol: "plus.square.on.square", title: "Duplicate Current",
            note: "Split off a pane with the same folder and command.",
            action: #selector(newPaneDuplicateAction)))
        menu.addItem(richItem(
            symbol: "terminal", title: "Path & Command…",
            note: "Split off a pane, choosing the folder and what to run in it.",
            action: #selector(newPanePathCommandAction)))

        section(menu, "Other")
        menu.addItem(richItem(
            symbol: "macwindow", title: "New Terminal (no tmux)",
            note: "A quick local shell. Closing it discards it for good.",
            action: #selector(newPlainShellAction)))
        let ssh = richItem(
            symbol: "network", title: "New SSH Connection",
            note: "Open a terminal connected to a host from your ~/.ssh/config.",
            action: nil)
        ssh.submenu = sshHostsSubmenu()
        menu.addItem(ssh)

        pop(menu, from: newButton)
    }

    /// A disabled header row, preceded by a separator except at the top.
    private func section(_ menu: NSMenu, _ title: String) {
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
    }

    /// One item per concrete host in ~/.ssh/config (re-read on every open, so
    /// config edits show up immediately); a disabled hint when there are none —
    /// including a missing or unreadable config.
    private func sshHostsSubmenu() -> NSMenu {
        let menu = NSMenu()
        let hosts = SSHConfigHosts.hosts()
        if hosts.isEmpty {
            menu.addItem(NSMenuItem(title: "No hosts in ~/.ssh/config", action: nil, keyEquivalent: ""))
            return menu
        }
        for host in hosts {
            let item = NSMenuItem(title: host, action: #selector(newSSHHostAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = host
            menu.addItem(item)
        }
        return menu
    }

    /// A menu item with a larger SF Symbol, a bold title, and a smaller grey note
    /// balanced onto two lines (an NSMenu sizes to the widest line, so the note is
    /// split in half rather than left as one long line that blows the menu out).
    private func richItem(symbol: String, title: String, note: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        let cfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(cfg)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ])
        text.append(NSAttributedString(string: "\n" + balancedTwoLines(note), attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]))
        item.attributedTitle = text
        return item
    }

    /// Split `text` into exactly two lines at the word boundary that makes the two
    /// lines the most even — keeps every note to two lines and the menu narrow.
    private func balancedTwoLines(_ text: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return text }
        let total = words.reduce(0) { $0 + $1.count } + (words.count - 1)
        var bestSplit = 1, bestDiff = Int.max
        for split in 1..<words.count {
            let line1 = words[0..<split].joined(separator: " ").count
            let diff = abs(line1 - (total - line1 - 1))
            if diff < bestDiff { bestDiff = diff; bestSplit = split }
        }
        return words[0..<bestSplit].joined(separator: " ") + "\n"
             + words[bestSplit...].joined(separator: " ")
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

    @objc private func newAgentAction() { onNewAgent?() }
    @objc private func newTerminalAction() { onNewTerminal?() }
    @objc private func closeWindowAction() { onCloseWindow?() }
    @objc private func closeTabAction() { onCloseTab?() }
    @objc private func newPlainShellAction() { onNewPlainShell?() }
    // Window / pane creation goes through the responder chain, the same route
    // the menu bar and the pane menu use, so it always lands on the pane host
    // of whichever tab is active.
    @objc private func newWindowDuplicateAction() { BentoPaneAction.dispatch(BentoPaneAction.newWindowDuplicate) }
    @objc private func newWindowPathCommandAction() { BentoPaneAction.dispatch(BentoPaneAction.newWindowPathCommand) }
    @objc private func newPaneDuplicateAction() { BentoPaneAction.dispatch(BentoPaneAction.splitDuplicate) }
    @objc private func newPanePathCommandAction() { BentoPaneAction.dispatch(BentoPaneAction.splitPathCommand) }
    @objc private func newSSHHostAction(_ sender: NSMenuItem) {
        if let host = sender.representedObject as? String { onNewSSHHost?(host) }
    }
    @objc private func settingsAction() { onOpenSettings?() }
    @objc private func renameAction() { onRenameSession?() }
    @objc private func detachAction() { onDetach?() }
    @objc private func killAction() { onKillSession?() }
}

#endif
