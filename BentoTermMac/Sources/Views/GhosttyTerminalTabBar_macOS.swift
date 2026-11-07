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
/// (bordered "glass").
///
/// Layout (left → right):
///   [▢ <session> ⌄] [Parallel│Focus]  ⸺flex⸺  [ window tabs ]  ⸺flex⸺  [＋ ▤]
///
/// A plain (no-tmux) terminal gets the minimal version, decided at
/// construction (`isPlain`): its name button (Close + the app's rows) and ＋.
/// No mode switch, no window strip, no file panel, no size banner.
///
/// The named left button carries the session (its switcher today, its actions
/// once sessions become native window tabs); the centre strip is the current
/// session's tmux WINDOWS, labelled `index:name` the way `list-windows` labels
/// them; New creates at every level (session / window / pane); ▤ toggles the
/// preview dock. Settings has no button here: it is opened once in a while,
/// and ⌘, plus the app menu are where every Mac app keeps it — a permanent
/// gear spent a toolbar slot on it.
@MainActor
final class TerminalToolbarController: NSObject, NSToolbarDelegate, NSMenuItemValidation {
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

    /// This toolbar belongs to a plain (no-tmux) terminal: the minimal set of
    /// items, and its name button's menu is just Close plus the app's rows.
    let isPlain: Bool

    /// Which items belong in the toolbar right now.
    ///
    /// - **Sessions** names the active session and lists the others.
    /// - **Parallel|Focus** reshapes the session, once there is something to
    ///   arrange.
    /// - New survives every state — creating is what a window with nothing in
    ///   it is FOR.
    ///
    /// The window strip is not here: it is a variable-width list, and its slot
    /// is already shared with the location by `setCenterShowsTabs`. A plain
    /// toolbar's items are fixed (`toolbarDefaultItemIdentifiers`).
    private func syncToolbarItems() {
        guard !isPlain, let tb = toolbarRef else { return }
        setItem(Self.sessionsID, visible: true, insertAt: 0)
        let afterSessions = tb.items.firstIndex { $0.itemIdentifier == Self.sessionsID }
            .map { $0 + 1 } ?? 0
        setItem(Self.modeID, visible: wantsModeItem, insertAt: afterSessions)
        // The take-over banner rides in the toolbar rather than in a strip above
        // the panes, and that is deliberate: a strip would shrink the terminal,
        // which is the very grid the banner is comparing — it would keep
        // clearing its own condition and blink. The toolbar is chrome that was
        // already there, so it perturbs nothing.
        let afterMode = tb.items.firstIndex { $0.itemIdentifier == Self.modeID }
            .map { $0 + 1 } ?? afterSessions
        setItem(Self.sizeID, visible: sizeMismatch != nil, insertAt: afterMode)
    }

    /// Add or remove the toolbar ITEM — not just its view.
    ///
    /// Setting `isHidden` on the view leaves the `NSToolbarItem` in place, and
    /// the item draws its own background: a plain terminal showed an empty
    /// switch-shaped capsule with no labels in it, the control gone but the
    /// thing it sat in still there. Removing the item is what the centre strip
    /// already does to swap tabs for the location.
    private func setItem(_ id: NSToolbarItem.Identifier, visible: Bool, insertAt: Int) {
        guard let tb = toolbarRef else { return }
        let existing = tb.items.firstIndex { $0.itemIdentifier == id }
        if visible, existing == nil {
            tb.insertItem(withItemIdentifier: id, at: min(max(insertAt, 0), tb.items.count))
        } else if !visible, let existing {
            tb.removeItem(at: existing)
        }
    }

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

    let sessionsButton = NSButton()
    /// Tiled|List — the session's structural mode, next to the session button.
    /// Reflects the active tab's `sessionMode`; hidden for plain (no-tmux) tabs.
    private let modeSwitch = NSSegmentedControl()
    /// New ⌄ and the preview toggle: two plain toolbar buttons in adjacent
    /// items with no space between, which macOS 26+ draws as one glass capsule.
    /// Not a segmented control — that always draws a divider between segments.
    let newButton = NSButton()
    /// Show/hide the preview dock (always present, like an inspector toggle).
    private let previewButton = NSButton()
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
    var tabsGroup = NSToolbarItemGroup(itemIdentifier: TerminalToolbarController.centerID)
    var onSelectSegment: ((Int) -> Void)?
    /// Right-click on a window segment → that window's actions. The index is the
    /// segment the pointer is actually over; returning nil means "nothing there".
    var onWindowMenu: ((Int) -> [NSMenuItem]?)?

    /// The segmented control AppKit builds for the expanded item group. Found by
    /// traversal because `NSToolbarItemGroup` publishes no accessor — see
    /// `attachWindowMenu`.
    weak var segmentedRef: NSSegmentedControl?
    /// The window this toolbar belongs to. Load-bearing, not a convenience:
    /// sessions are native tabs, so several windows carry an identical toolbar
    /// at once and a search that could wander into another one would hand this
    /// window's menu that window's tmux windows. Every lookup is fenced by it.
    weak var hostWindow: NSWindow? {
        didSet { observeHostWidth(old: oldValue) }
    }
    /// The toolbar that owns `tabsGroup` — so we can swap the group in place.
    private(set) weak var toolbarRef: NSToolbar?
    /// Signature (title + dot) of the current segments. A group swap is needed
    /// whenever this changes — including a dot-only change, because mutating a
    /// live group's subitem images doesn't reliably re-render. Selection-only
    /// changes keep the same signature and just move `selectedIndex` in place.
    var currentSig: [String] = []

    fileprivate static let sessionsID = NSToolbarItem.Identifier("bento.sessions")
    fileprivate static let modeID = NSToolbarItem.Identifier("bento.mode")
    fileprivate static let newID = NSToolbarItem.Identifier("bento.new")
    fileprivate static let previewID = NSToolbarItem.Identifier("bento.preview")
    static let centerID = NSToolbarItem.Identifier("bento.center")
    fileprivate static let sizeID = NSToolbarItem.Identifier("bento.size")
    static let locationID = NSToolbarItem.Identifier("bento.location")

    /// The centre at rest: where the focused pane is (`claude · ~/proj`), as
    /// quiet status text. Not a control — it says where you are and does
    /// nothing when clicked.
    ///
    /// A borderless button with no action, because that is what renders as
    /// plain text in a macOS 26 toolbar: a BORDERED button there is drawn in
    /// the item's glass capsule whatever `showsBorderOnlyWhileMouseInside` or
    /// `NSToolbarItem.isBordered` say.
    private let locationLabel = NSButton()
    /// ~40% of the window: the location is the one variable-length item, and a
    /// deep path must truncate rather than shove the side items around.
    private var locationWidthCap: NSLayoutConstraint?
    var centerShowsTabs = true

    init(isPlain: Bool) {
        self.isPlain = isPlain
        super.init()
        // The left button is the CURRENT session's menu (named with the session,
        // like a document-title menu) — the discoverable home for per-session
        // actions. Its text is updated by the manager via `setSessionTitle`.
        configureMenu(sessionsButton, symbol: isPlain ? "terminal" : "macwindow", text: "Session",
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
        // [＋ ▤]: New (a menu) and the inspector-style preview dock toggle.
        configure(newButton, symbol: "plus", title: "", action: #selector(newTapped))
        newButton.setAccessibilityLabel("New")
        newButton.toolTip = "New pane, window or session"
        configure(previewButton, symbol: "sidebar.trailing", title: "",
                  action: #selector(previewTapped))
        previewButton.setAccessibilityLabel("Preview")
        previewButton.toolTip = "Show/hide the file panel (⌥⌘P)"
        configure(sizeButton, symbol: TerminalSizingMode.thisDevice.symbol, title: "",
                  action: #selector(sizeBannerTapped))
        configureLocationLabel()
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

    /// Reflect the active tab's mode on the Tiled|List switch. nil = nothing to
    /// arrange (a single pane), so the switch goes away entirely.
    func setSessionMode(_ mode: TmuxSessionMode?) {
        sessionMode = mode
        wantsModeItem = (mode != nil)
        syncToolbarItems()
        guard let mode else { return }
        modeSwitch.selectedSegment = (mode == .tiled) ? 0 : 1
    }

    /// Whether the Layout item belongs in the toolbar at all. Kept as state
    /// because `setSessionMode` can run before `makeToolbar`, and the answer has
    /// to survive until there is a toolbar to apply it to.
    private var wantsModeItem = true
    /// The active tab's mode (nil = no switch shown) — the ＋ menu's first row
    /// says "New Pane" or "New tmux Window" after it.
    private(set) var sessionMode: TmuxSessionMode?

    @objc private func modeSwitched() {
        onSelectMode?(modeSwitch.selectedSegment == 1 ? .list : .tiled)
    }

    private func configureLocationLabel() {
        let b = locationLabel
        b.isBordered = false
        b.imagePosition = .noImage
        b.controlSize = .regular
        b.refusesFirstResponder = true
        // No press flash: there is nothing to press.
        (b.cell as? NSButtonCell)?.highlightsBy = []
        (b.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
        (b.cell as? NSButtonCell)?.truncatesLastVisibleLine = true
        b.setAccessibilityRole(.staticText)
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
        // A point under the toolbar's own text: status, not a title to read first.
        let size = NSFont.systemFontSize - 1
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        para.alignment = .center
        locationLabel.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para,
            ])
        locationLabel.setAccessibilityValue(text)
        locationLabel.invalidateIntrinsicContentSize()
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
        tb.allowsDisplayModeCustomization = false
        // Pin the session strip to the WINDOW's center, independent of the side
        // items' widths — so the session-name button can size to its text without
        // ever nudging the tabs (the native alternative to hardcoding widths).
        if !isPlain { tb.centeredItemIdentifiers = [Self.centerID] }
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
        // Plain: <name> ⌄ | ⸺flex⸺ | ＋
        if isPlain { return [Self.sessionsID, .flexibleSpace, Self.newID] }
        // ◧ | Sessions ⌄ | Tiled|List | ⸺flex⸺ | [session tabs] | ⸺flex⸺ | ＋ ▤
        // ＋ and ▤ are adjacent items with nothing between them, so the system
        // groups them into one capsule.
        return [Self.sessionsID, Self.modeID, .flexibleSpace, Self.centerID,
                .flexibleSpace, Self.newID, Self.previewID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The centre swaps between the window strip and the location, so both
        // must be ALLOWED even though only one is in the default set.
        // The size banner is never in the DEFAULT set — it exists only while the
        // canvas is someone else's — but an item can't be inserted unless it is
        // allowed.
        if isPlain { return toolbarDefaultItemIdentifiers(toolbar) }
        return toolbarDefaultItemIdentifiers(toolbar) + [Self.locationID, Self.sizeID]
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
        case Self.previewID:  item.view = previewButton;  item.label = "Preview"
        case Self.sizeID:     item.view = sizeButton;     item.label = "Session Size"
        case Self.locationID: item.view = locationLabel;  item.label = "Location"
        default: return nil
        }
        return item
    }

    // MARK: - Session size banner

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
}

#endif
