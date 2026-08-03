#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI
import BentoSessionKit
import BentoFoundationKit
import BentoUISharedKit

// MARK: - Brand

/// The one place the launcher's logo and name are named.
///
/// A new app icon is being drawn separately, so the source is deliberately a
/// single indirection: today it is whatever the bundle's asset catalogue holds
/// (`BentoTermMac/Resources/Assets.xcassets/AppIcon.appiconset`, generated from
/// `docs/bento-icon.svg`), and swapping it later is a one-line change here
/// rather than a hunt through the view.
enum LauncherBrand {
    /// The app's name as it is written everywhere else — window titles, the
    /// About box, Homebrew. One word, two capitals.
    static let wordmark = "BentoTerm"

    static var logo: NSImage? { NSApp.applicationIconImage }
}

// MARK: - Layout

/// How wide the launcher's content block is, and when it stops being two
/// columns.
///
/// A centred block needs a ceiling. Bento windows are terminal windows and get
/// dragged out to whatever the screen allows; without a maximum the two columns
/// would drift a metre apart on a 2500pt window and the page would read as two
/// unrelated lists rather than one block. Without a minimum they would crush
/// into two unreadable slivers on a window someone narrowed to a code column.
/// So the block has a maximum, is centred inside whatever is left, and folds to
/// one column below the point where the right-hand side would start truncating
/// session names.
///
/// **The numbers.** The left column is fixed at `leftColumnWidth` because its
/// content is fixed: three create rows whose explanatory sentences need room to
/// wrap to two lines, and one `SSH` row. The right column is elastic between
/// `rightColumnMin` and `rightColumnMax` — its rows are session names and
/// `~/`-abbreviated paths, which look wrong short and gain nothing past 400pt.
///
/// **The breakpoint** falls out of those: two columns need
/// `leftColumnWidth + gutter + rightColumnMin` of content, plus `outerPadding`
/// on each side, so the fold happens at a window content width of
/// **764pt**. Below it everything stacks in one column — the right column's
/// sections fall in directly under the left column's rows, in the same order
/// the wide layout reads them, so nothing is reordered or hidden by the fold,
/// only rewrapped. That column is itself capped at `oneColumnMaxWidth`, and
/// below that it simply shrinks with the window; the terminal window's own
/// 480pt minimum is the floor, and at that width the block is 416pt wide and
/// still whole.
///
/// Vertically the block is centred while it fits and scrolls when it does not
/// (`LauncherView.body`), so a window shortened to a strip clips nothing.
enum LauncherLayout {
    static let outerPadding: CGFloat = 32
    static let leftColumnWidth: CGFloat = 360
    static let gutter: CGFloat = 40
    static let rightColumnMin: CGFloat = 300
    static let rightColumnMax: CGFloat = 400
    static let oneColumnMaxWidth: CGFloat = 420

    static var twoColumnMinWidth: CGFloat { leftColumnWidth + gutter + rightColumnMin }
    static var twoColumnMaxWidth: CGFloat { leftColumnWidth + gutter + rightColumnMax }

    /// The window content width at which the page folds to one column.
    static var foldWidth: CGFloat { twoColumnMinWidth + 2 * outerPadding }

    /// Pure so the structure dump can ask it about window sizes that are not
    /// on screen.
    static func isTwoColumn(contentWidth: CGFloat, hasRightColumn: Bool) -> Bool {
        hasRightColumn && contentWidth >= foldWidth
    }

    static func blockWidth(contentWidth: CGFloat, twoColumn: Bool) -> CGFloat {
        let available = max(0, contentWidth - 2 * outerPadding)
        return min(available, twoColumn ? twoColumnMaxWidth : oneColumnMaxWidth)
    }

    /// Where the block sits in a window of this size — centred, so the origin
    /// is whatever is left over halved. Height is content-driven and therefore
    /// not part of this: see `LauncherView.body` for the centre-or-scroll rule.
    static func blockOriginX(contentWidth: CGFloat, blockWidth: CGFloat) -> CGFloat {
        max(outerPadding, (contentWidth - blockWidth) / 2)
    }

    /// A one-line description of the computed frame, for the structure dump.
    static func describe(contentWidth: CGFloat, hasRightColumn: Bool) -> String {
        let two = isTwoColumn(contentWidth: contentWidth, hasRightColumn: hasRightColumn)
        let w = blockWidth(contentWidth: contentWidth, twoColumn: two)
        let x = blockOriginX(contentWidth: contentWidth, blockWidth: w)
        if two {
            let right = w - leftColumnWidth - gutter
            return "columns=2 block x=\(Int(x)) w=\(Int(w)) "
                 + "(left=\(Int(leftColumnWidth)) gutter=\(Int(gutter)) right=\(Int(right)))"
        }
        return "columns=1 block x=\(Int(x)) w=\(Int(w))"
    }
}

// MARK: - The window

/// A terminal window that has no session yet and asks what to put in it.
///
/// **It is not a different kind of window.** It is built by
/// `TerminalSessionWindow.makeShell`, the same function that builds a session
/// window: same style mask, same full-size content and hidden title, same
/// tabbing identifier, same toolbar, same shared frame. Only the CONTENT
/// differs, and only the toolbar items with nothing to refer to are disabled.
/// It was written as its own bare window once — no toolbar, no tab group, no
/// frame autosave — and each of those read to the user as a separate bug when
/// they were one: a window with no session was being treated as a window of
/// another kind.
///
/// **It is the same window that becomes the session.** Picking a row hands this
/// window's shell to `TerminalWindowManager`, which configures it in place —
/// same `NSWindow` object, same screen position, same z-order, same frame
/// autosave claim. That is the whole reason the launcher is a window rather
/// than a sheet or a panel: the old flow created the window first and then had
/// to express failure inside a terminal that was already on screen
/// (docs/launcher-design.md §4), and the fix is to let the window exist
/// *before* the session without pretending a session is there.
///
/// **Filling it does not move or resize it.** It opens at the geometry every
/// Bento window shares and it RECORDS changes to that geometry, so the size you
/// settle on here is the size the next window gets. Picking something changes
/// the content and nothing else.
///
/// The one case where the shell is not consumed is picking a session that is
/// already open in another window: there is nothing to fill, that window comes
/// forward, and this one closes rather than sitting behind it as a duplicate
/// question.
@MainActor
final class LauncherWindowController: NSObject, NSWindowDelegate {
    private static var controllers: [LauncherWindowController] = []

    let window: TerminalSessionWindow
    let model: LauncherModel
    private let toolbar = TerminalToolbarController()
    /// Where the `SSH` row is, in the hosting view's (flipped) coordinates, so
    /// the menu drops from the row rather than from the pointer.
    private var sshRowFrame: CGRect = .zero

    static func open() {
        // Two launcher windows say the same thing twice. A second ⌘N while one
        // is up and unanswered just brings that question forward.
        if let existing = controllers.last {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let c = LauncherWindowController()
        controllers.append(c)
        c.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The local session list changed under an open launcher — re-read it.
    /// Pushed rather than polled: the launcher's sources are all local, but
    /// re-reading them on a timer would re-rank rows under the user's cursor
    /// for no reason. This fires when something actually moved.
    static func serverSessionsChanged() {
        for c in controllers { c.model.refresh() }
    }

    /// ⌘P over a launcher window.
    ///
    /// It opens the palette, the same as it does anywhere else. This used to
    /// put the caret in a filter field on this page instead, back when the page
    /// was described as the palette's level 0 and the toolbar's search slot
    /// filtered these very rows. That was a second, weaker search: it could
    /// only find the dozen things this page draws, while the palette's own
    /// level-0 content comes from the same `OpenTargets` provider and reaches
    /// every session, every recent launch and every ssh host. Search belongs in
    /// one place and this is not it.
    ///
    /// Returns false when the key window isn't a launcher, so the caller falls
    /// through to the pane-host route.
    static func presentPaletteIfKey() -> Bool {
        guard let c = controllers.first(where: { $0.window.isKeyWindow }) else { return false }
        c.presentPalette()
        return true
    }

    private override init() {
        model = LauncherModel()
        window = TerminalSessionWindow.makeShell()
        super.init()
        // Session windows title themselves `BentoTerm · <the session>`; this
        // one holds nothing yet, so it names the gesture that made it. The
        // string is load-bearing in two places even though the title bar hides
        // it: the Window menu, and — now that a launcher can be a tab — the tab
        // label, where "BentoTerm" alone would be indistinguishable from the
        // default session sitting next to it.
        window.title = "BentoTerm · New Window"
        window.delegate = self
        window.contentViewController =
            NSHostingController(rootView: LauncherView(model: model, owner: self))

        installToolbar()
        place()
    }

    // MARK: Chrome

    private func installToolbar() {
        toolbar.hasSession = false
        toolbar.hostWindow = window
        toolbar.setSessionTitle("No Session")
        // Everything New ⌄ offers here fills THIS window, exactly as the page's
        // own create rows do. A New menu that opened a second window while the
        // first one sat behind it still asking would be the bug this whole
        // window exists to remove.
        toolbar.onNewAgent = { OpenTargetProvider.shared.perform(.agentSession) }
        toolbar.onNewTerminal = { [weak self] in
            self?.fill { OpenTargetProvider.shared.perform(.emptySession, into: $0) }
        }
        toolbar.onNewPlainShell = { [weak self] in
            self?.fill { OpenTargetProvider.shared.perform(.plainTerminal, into: $0) }
        }
        toolbar.onNewSSHHost = { [weak self] host in self?.openSSH(host) }
        toolbar.onNewRemoteTmuxHost = { [weak self] host in self?.openRemoteTmux(host) }
        toolbar.onOpenSettings = { BentoTerminalWindow.onOpenSettings?() }
        // No `customSearchView`: the search slot keeps the button a session
        // window has, meaning the same thing it means there. See
        // `presentPalette`.
        toolbar.onOpenSearch = { [weak self] in self?.presentPalette() }
        window.toolbar = toolbar.makeToolbar()
        window.toolbarStyle = .unified
    }

    /// Where the window opens.
    ///
    /// Joining the tab group comes FIRST, because a window that is about to be
    /// added to a group must not first be moved to a frame of its own — and
    /// because a tab has no frame to restore: the group has one. Standing
    /// alone, it claims the shared frame name, which is the fix for a launcher
    /// whose resizes used to be discarded: it read the saved frame and never
    /// wrote one back. The claim survives being filled (`BentoWindowFrame`),
    /// so there is no moment where nobody is recording.
    private func place() {
        if BentoTerminalWindow.shouldOpenAsTab, let host = BentoTerminalWindow.tabGroupHost {
            host.addTabbedWindow(window, ordered: .above)
            return
        }
        if BentoWindowFrame.claim(window), window.setFrameUsingName(BentoWindowFrame.name) {
            return
        }
        window.setContentSize(TerminalWindowManager.defaultContentSize)
        window.center()
    }

    // MARK: The palette

    /// The command palette over a launcher window.
    ///
    /// A session window routes ⌘P and the toolbar's search button through its
    /// pane host, because the palette's File / Command / Pane sections are
    /// about the focused pane. A launcher has no pane host, so it builds the
    /// sections that are still true with nothing open — everything you can
    /// open, plus the three ways to make something — and hands them to the same
    /// controller, anchored to the same toolbar control. The panel that drops
    /// is the panel a session window drops, in the same place.
    private func presentPalette() {
        CommandPaletteController.shared.present(
            fileContext: nil, hostLabel: "This Mac",
            staticSpecs: Self.paletteSpecs(
                .shared,
                open: { [weak self] in self?.open($0) },
                perform: { [weak self] in self?.perform($0) }),
            from: toolbar.searchAnchor)
    }

    /// What the palette shows over an empty window.
    ///
    /// Deliberately the same three groups the page draws plus the hosts the
    /// page keeps in a menu — this is where a typed hostname is found, which is
    /// why the page does not need a filter of its own. Every row fills THIS
    /// window rather than opening another, for the same reason the New ⌄ menu's
    /// rows do: the question this window is asking is the one being answered.
    ///
    /// Static and closure-driven so the structure can be built — and asserted —
    /// without a window on screen.
    static func paletteSpecs(_ targets: OpenTargetProvider,
                             open: @escaping @MainActor (OpenTarget) -> Void,
                             perform: @escaping @MainActor (LaunchAction) -> Void)
        -> [PaletteSectionSpec] {
        func row(_ target: OpenTarget) -> PaletteItem {
            PaletteItem(id: target.id, title: target.title, subtitle: target.subtitle,
                        systemImage: target.systemImage, matchText: target.matchText,
                        action: .run { open(target) })
        }
        var specs: [PaletteSectionSpec] = []
        let sessions = targets.sessionTargets().map(row)
        if !sessions.isEmpty {
            specs.append(PaletteSectionSpec(id: "sessions", title: "Sessions",
                                            items: sessions, limit: 8))
        }
        let launches = targets.recentTargets().map(row)
        if !launches.isEmpty {
            specs.append(PaletteSectionSpec(id: "launches", title: "Recent Launches",
                                            items: launches, limit: 6))
        }
        let hosts = targets.sshTargets().map(row)
        if !hosts.isEmpty {
            specs.append(PaletteSectionSpec(id: "sshHosts", title: "SSH Hosts",
                                            items: hosts, limit: 8))
        }
        let commands = LaunchAction.displayOrder.map { action in
            PaletteItem(id: action.id, title: action.title, subtitle: action.detail,
                        systemImage: action.systemImage, matchText: action.matchText,
                        action: .run { perform(action) })
        }
        specs.append(PaletteSectionSpec(id: "commands", title: "Commands",
                                        items: commands, limit: 10))
        return specs
    }

    // MARK: Row actions

    /// A row was activated. Everything routes through here so there is exactly
    /// one place that knows the window is consumed.
    func fill(_ body: (TerminalSessionWindow) -> Bool) {
        // Keep this controller alive across the handover. Dropping it from
        // `controllers` below releases the last reference to it, and it owns
        // the toolbar controller that is still this window's toolbar delegate
        // until the manager installs its own a few lines later.
        withExtendedLifetime(self) {
            // Detach BEFORE handing the shell over: the manager makes itself the
            // window's delegate, and this controller must not still be holding a
            // reference that would later close a live session window.
            let shell = window
            Self.controllers.removeAll { $0 === self }
            if body(shell) {
                // Consumed — the manager owns the window now.
            } else {
                // Nothing to fill (the session was already open and got fronted).
                shell.delegate = nil
                shell.close()
            }
        }
    }

    func perform(_ action: LaunchAction) {
        // §7: the agent path leaves the page on purpose — its choices are
        // two-dimensional (a layout grid), which a list of rows cannot draw —
        // and because the wizard can be cancelled it does not consume this
        // window. The other two fill it in place.
        if action.consumesShell {
            fill { OpenTargetProvider.shared.perform(action, into: $0) }
        } else {
            OpenTargetProvider.shared.perform(action)
        }
    }

    func open(_ target: OpenTarget) {
        fill { OpenTargetProvider.shared.open(target, into: $0) }
    }

    private func openSSH(_ host: String) {
        fill { BentoTerminalWindow.fill($0, plainTitle: host, command: ["ssh", host]); return true }
    }

    private func openRemoteTmux(_ host: String) {
        fill { BentoTerminalWindow.fill($0, tmuxHost: host) }
    }

    // MARK: The SSH menu

    /// Remember where the `SSH` row landed so the menu can drop from it.
    /// `NSHostingView` is flipped, so SwiftUI's own coordinates go straight to
    /// `NSMenu.popUp(positioning:at:in:)` with no conversion.
    func recordSSHRowFrame(_ frame: CGRect) { sshRowFrame = frame }

    /// The launcher's `SSH` row opens the toolbar's menu, not a third
    /// vocabulary: the same two rows, the same tooltips, the same host list,
    /// built by `SSHHostMenu`. The page's row is therefore a shortcut to a menu
    /// the user can also reach from `New ⌄` — one concept, one name, and no
    /// question of which of them is authoritative.
    func showSSHMenu() {
        let menu = SSHHostMenu.menu(target: self,
                                    connect: #selector(sshConnectAction(_:)),
                                    remoteTmux: #selector(sshRemoteTmuxAction(_:)))
        if let view = window.contentView, sshRowFrame != .zero {
            menu.popUp(positioning: nil,
                       at: CGPoint(x: sshRowFrame.minX, y: sshRowFrame.maxY),
                       in: view)
        } else if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: window.contentView ?? NSView())
        }
    }

    @objc private func sshConnectAction(_ sender: NSMenuItem) {
        if let host = sender.representedObject as? String { openSSH(host) }
    }

    @objc private func sshRemoteTmuxAction(_ sender: NSMenuItem) {
        if let host = sender.representedObject as? String { openRemoteTmux(host) }
    }

    func windowWillClose(_ notification: Notification) {
        // Same bookkeeping a session window does on the way out: record the
        // geometry and give the name back. Without it, a launcher that owned
        // the name would take it to the grave and the next window would open
        // unowned — unable to restore, unable to record.
        BentoWindowFrame.release(window)
        Self.controllers.removeAll { $0 === self }
    }
}

// MARK: - The page

/// What a window with no session yet draws: one centred block, two columns.
///
/// **Why centred.** The page has about a dozen short rows and the window it
/// lives in is a terminal window, which people keep large. Left-aligned at the
/// top, that content sat in one corner of a mostly empty screen and read as a
/// list that had failed to finish loading. A centred block with a ceiling
/// (`LauncherLayout`) reads as a page that is the size it means to be.
///
/// **Why two columns.** The rows are two different questions — "make me
/// something" and "take me back to something" — and stacking them made the
/// second one look like a continuation of the first. Side by side they are
/// visibly a choice between two, and the block gets a shape instead of being a
/// tall thin ribbon down the middle.
///
/// **The logo is not the deleted onboarding coming back.** The design's
/// standing prohibition on hero art exists to stop a three-step getting-started
/// sequence from regrowing here; it was written when the failure mode was "this
/// page will accumulate marketing". This page's failure mode is the opposite —
/// too little on too much screen — and a logo with the app's name is what
/// anchors the block and tells you which app you are looking at when the window
/// is otherwise empty. A tagline or a first-run sequence would still be wrong.
/// See docs/launcher-design.md §5.
///
/// **Nothing here filters.** The toolbar's search field is the app's search and
/// means the same thing here as in a session window; this page is static
/// content (see `LauncherModel`).
struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    /// Unowned: the controller owns the window that owns this view.
    unowned let owner: LauncherWindowController

    var body: some View {
        GeometryReader { geo in
            let twoColumn = LauncherLayout.isTwoColumn(contentWidth: geo.size.width,
                                                       hasRightColumn: model.hasRightColumn)
            let width = LauncherLayout.blockWidth(contentWidth: geo.size.width,
                                                  twoColumn: twoColumn)
            ScrollView(.vertical) {
                block(twoColumn: twoColumn)
                    .frame(width: width, alignment: .leading)
                    .padding(LauncherLayout.outerPadding)
                    // Centred while it fits; once the content is taller than
                    // the window this frame stops shrinking and the ScrollView
                    // takes over, so a window dragged down to a strip scrolls
                    // instead of clipping.
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func block(twoColumn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if twoColumn {
                HStack(alignment: .top, spacing: LauncherLayout.gutter) {
                    leftColumn(compact: false)
                        .frame(width: LauncherLayout.leftColumnWidth, alignment: .leading)
                    rightColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    leftColumn(compact: true)
                    // Folded, the right column falls in underneath rather than
                    // disappearing — same sections, same order.
                    if model.hasRightColumn { rightColumn }
                }
            }
        }
    }

    // MARK: Left column

    @ViewBuilder
    private func leftColumn(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            brand(compact: compact)
            ForEach(model.actions) { row in
                createRow(row)
            }
            if model.hasHosts { sshRow }
            if model.isEmpty { nothingToOpen }
        }
    }

    /// Logo over wordmark, left-aligned with the rows below it.
    ///
    /// Vertical rather than a side-by-side lockup because the logo is meant to
    /// be large — it is doing the work of filling a window — and a 64pt icon
    /// beside 28pt text is a lockup with a hole in it. The 20pt inset matches
    /// `PaletteRowView`'s own (8 outer + 12 inner), so the icon column and the
    /// wordmark share a left edge.
    private func brand(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let logo = LauncherBrand.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: compact ? 48 : 64, height: compact ? 48 : 64)
            }
            Text(LauncherBrand.wordmark)
                .font(.system(size: compact ? 22 : 26, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.leading, 20)
        .padding(.bottom, 18)
    }

    /// A create row. The first one also answers ⏎.
    ///
    /// There is no selection cursor on this page any more, so ⏎ has nothing to
    /// follow — but ⌘N ⏎ meaning "give me a shell" is worth keeping and costs
    /// exactly one modifier here: SwiftUI's default-action shortcut, with no
    /// list navigation behind it. The row says `⏎` so the key is not a secret.
    @ViewBuilder
    private func createRow(_ row: LauncherModel.Row) -> some View {
        let isDefault = row.id == LaunchAction.plainTerminal.id
        Button {
            activate(row)
        } label: {
            PaletteRowView(title: row.title, subtitle: row.subtitle,
                           systemImage: row.systemImage, selected: false,
                           subtitleLineLimit: 2) {
                if isDefault {
                    Text("⏎")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
        .modifier(DefaultActionIf(isDefault))
    }

    /// One row for every ssh host, opening the toolbar's own menu (§6 / §5's
    /// "one concept one name"). It replaced a wrapping line of chips plus a
    /// "16 ▸" expander: chips were a reminder that hosts exist, but they were
    /// also the widest thing on the page and the first casualty of a narrow
    /// column, and a menu says the same thing in one row at any width.
    private var sshRow: some View {
        Button {
            owner.showSSHMenu()
        } label: {
            PaletteRowView(title: model.sshMenuRow.title,
                           subtitle: model.sshMenuRow.subtitle,
                           systemImage: model.sshMenuRow.systemImage,
                           selected: false) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
        .background(
            GeometryReader { geo in
                Color.clear.onAppear {
                    owner.recordSSHRowFrame(geo.frame(in: .global))
                }
                .onChange(of: geo.frame(in: .global)) { _, new in
                    owner.recordSSHRowFrame(new)
                }
            })
    }

    /// No sessions, no recents, no `~/.ssh/config`. One sentence under the
    /// create rows — not a separate screen, and not a set of bare headers. The
    /// page still has its three real answers; this only explains why the rest
    /// of it is missing, and names the three things it looked for so the reader
    /// knows it looked.
    private var nothingToOpen: some View {
        Text("Nothing running to open — no tmux sessions, no recent launches, "
             + "no hosts in ~/.ssh/config.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.top, 14)
    }

    // MARK: Right column

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            section(LauncherModel.Section.sessions.title, model.sessions)
            recentSection
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [LauncherModel.Row]) -> some View {
        if !rows.isEmpty {
            PaletteSectionHeader(title: title)
            ForEach(rows) { row in
                Button {
                    activate(row)
                } label: {
                    PaletteRowView(title: row.title, subtitle: row.subtitle,
                                   systemImage: row.systemImage, selected: false) {
                        if isOpenSession(row) {
                            Text("open")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverRowButtonStyle())
            }
        }
    }

    /// Recents: three rows and a "N more" once there are more than three. The
    /// tail of that list decays fast — the fourth-newest launch is already a
    /// rare pick — so it costs one click rather than four rows.
    @ViewBuilder
    private var recentSection: some View {
        section(LauncherModel.Section.recents.title, model.recents)
        if model.hasHiddenRecents {
            Button { model.expandRecents() } label: {
                HStack(spacing: 3) {
                    Text(model.recentsExpanderRow.title)
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 44)
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
    }

    // MARK: Actions

    private func isOpenSession(_ row: LauncherModel.Row) -> Bool {
        guard case .open(let target) = row.action,
              case .tmuxSession(let name) = target.kind else { return false }
        return BentoTerminalWindow.openSessionKeys.contains(TmuxSessionID.local(name).key)
    }

    private func activate(_ row: LauncherModel.Row) {
        switch row.action {
        case .sshMenu:        owner.showSSHMenu()
        case .expandRecents:  model.expandRecents()
        case .open(let t):    owner.open(t)
        case .create(let a):  owner.perform(a)
        }
    }
}

// MARK: - Row chrome

/// A row that lights up under the pointer and presses in when clicked.
///
/// `PaletteRowView` draws its own selection fill for the palette's keyboard
/// cursor; this page has no cursor, so the only state a row has is "the mouse
/// is on it". Kept as a button style rather than an `onTapGesture` so the row
/// is a real control: it gets the pressed state, the accessibility role and the
/// keyboard activation for free.
private struct HoverRowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12
                                                : (hovering ? 0.06 : 0)))
                    .padding(.horizontal, 8))
            .onHover { hovering = $0 }
    }
}

/// `.keyboardShortcut(.defaultAction)` applied conditionally. A `ViewModifier`
/// because attaching the shortcut inside an `if` would give SwiftUI two
/// different view types for one row and reset its state on every rebuild.
private struct DefaultActionIf: ViewModifier {
    let active: Bool
    init(_ active: Bool) { self.active = active }

    func body(content: Content) -> some View {
        if active {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}
#endif
