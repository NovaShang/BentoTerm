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
///   [◧]  ⸺flex⸺  [ window tabs, or session · program · path ]  ⸺flex⸺  [＋ ▤]
///
/// There is no Parallel / Focus switch: the sidebar's session row shows the
/// panes split, a pane row shows one alone.
///
/// While the window shows a plain (no-tmux) terminal (`isPlain`): the sidebar
/// button, its name and ＋.
///
/// Sessions are the sidebar's, and their actions its rows' and the Session
/// menu's. The centre strip is the current session's tmux WINDOWS, labelled `index:name` the way `list-windows` labels
/// them; New creates at every level (session / window / pane); ▤ toggles the
/// preview dock. Settings has no button here: it is opened once in a while,
/// and ⌘, plus the app menu are where every Mac app keeps it — a permanent
/// gear spent a toolbar slot on it.
@MainActor
final class TerminalToolbarController: NSObject, NSToolbarDelegate {
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
    var onTogglePreview: (() -> Void)?

    /// The window is showing a plain (no-tmux) terminal: no window strip, no
    /// file panel, no size banner.
    var isPlain = false {
        didSet {
            guard oldValue != isPlain else { return }
            if isPlain { sizeMismatch = nil; setCenterShowsTabs(false) }
            syncToolbarItems()
        }
    }

    /// Which items belong in the toolbar right now, in order — the same
    /// whether the sidebar is shown or not.
    ///
    /// - The system sidebar button and its tracking separator always lead,
    ///   so the button sits over the sidebar (by the traffic lights when it
    ///   is away).
    /// - The centre (window strip or location), ＋ and ▤.
    /// - The take-over banner, only while the canvas is someone else's. It rides in the toolbar rather than in a strip above
    ///   the panes deliberately: a strip would shrink the terminal, which is
    ///   the very grid the banner is comparing — it would keep clearing its
    ///   own condition and blink.
    private var desiredItems: [NSToolbarItem.Identifier] {
        var ids: [NSToolbarItem.Identifier] = [.toggleSidebar, .sidebarTrackingSeparator]
        if sizeMismatch != nil { ids.append(Self.sizeID) }
        ids += [.flexibleSpace, centerShowsTabs ? Self.centerID : Self.locationID,
                .flexibleSpace, Self.newID]
        if !isPlain { ids.append(Self.previewID) }
        return ids
    }

    /// Bring the toolbar's items to `desiredItems`: what they share from the
    /// start stays put (so the sidebar button never blinks), the rest is
    /// replaced. Items are removed, not hidden — a hidden view leaves its
    /// item's capsule behind.
    func syncToolbarItems() {
        guard let tb = toolbarRef else { return }
        let want = desiredItems
        let have = tb.items.map(\.itemIdentifier)
        guard have != want else { return }
        var keep = 0
        while keep < min(have.count, want.count), have[keep] == want[keep] { keep += 1 }
        while tb.items.count > keep { tb.removeItem(at: tb.items.count - 1) }
        for (i, id) in want.enumerated().dropFirst(keep) { tb.insertItem(withItemIdentifier: id, at: i) }
        let center = want.first { $0 == Self.centerID || $0 == Self.locationID }
        tb.centeredItemIdentifiers = center.map { [$0] } ?? []
    }

    /// New ⌄ and the preview toggle: two plain toolbar buttons in adjacent
    /// items with no space between, which macOS 26+ draws as one glass capsule.
    /// Not a segmented control — that always draws a divider between segments.
    let newButton = NSButton()
    /// Show/hide the preview dock (always present, like an inspector toggle).
    private let previewButton = NSButton()
    /// The take-over banner: present only while this window's grid differs from
    /// the session's (see `sizeMismatch`).
    private let sizeButton = NSButton()
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
    private var sessionName = ""
    private var locationText = ""
    var centerShowsTabs = true

    override init() {
        super.init()
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
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// The active tab's mode (nil = a single pane) — the ＋ menu's first row
    /// says "New Pane" (split) or "New tmux Window" (one pane shown alone).
    func setSessionMode(_ mode: TmuxSessionMode?) {
        sessionMode = mode
    }

    private(set) var sessionMode: TmuxSessionMode?

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

    /// The session's name (a plain terminal's own), leading the centre title.
    func setSessionTitle(_ name: String) {
        guard name != sessionName else { return }
        sessionName = name
        applyCentreTitle()
    }

    /// What follows it — `<program> · <path>`, already composed by the window
    /// (it knows the pane, the host and the shell rule).
    func setLocation(_ text: String) {
        locationText = text
        applyCentreTitle()
    }

    private func applyCentreTitle() {
        let text = [sessionName, locationText].filter { !$0.isEmpty }.joined(separator: " · ")
        // A point under the toolbar's own text: status, not a title to read first.
        let size = NSFont.systemFontSize - 1
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        para.alignment = .center
        let title = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para,
            ])
        title.addAttribute(.foregroundColor, value: NSColor.labelColor,
                           range: NSRange(location: 0, length: (sessionName as NSString).length))
        locationLabel.attributedTitle = title
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
        // One identifier per toolbar, never shared. AppKit treats toolbars
        // with the same identifier as one family and mirrors every
        // insert/remove into all of them, but each window wants its own items
        // (window strip or location, size banner or not): a new window's sync
        // removed items from the others by index and AppKit threw, killing
        // the app (opening a new ssh session from ＋).
        let tb = NSToolbar(identifier: "BentoTerminalToolbar-\(UUID().uuidString)")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        // Kill the stock title-bar context menu. `allowsUserCustomization = false`
        // only drops "Customize Toolbar…"; the Icon Only / Icon and Text display
        // options are governed separately and kept showing up on right-click.
        // They are meaningless here — every item is deliberately icon-only, and a
        // toolbar this small has no display mode worth choosing.
        tb.allowsDisplayModeCustomization = false
        // The centre is pinned to the WINDOW's center, independent of the side
        // items' widths (`syncToolbarItems`).
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

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        desiredItems
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Everything `desiredItems` can ask for, in any state — an item can't
        // be inserted unless it is allowed.
        return [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace,
                Self.centerID, Self.locationID, Self.sizeID, Self.newID, Self.previewID]
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
