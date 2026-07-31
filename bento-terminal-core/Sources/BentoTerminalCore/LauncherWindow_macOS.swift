#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI

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
final class LauncherWindowController: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    private static var controllers: [LauncherWindowController] = []

    let window: TerminalSessionWindow
    let model: LauncherModel
    private let toolbar = TerminalToolbarController()
    /// The filter. It lives in the toolbar's search slot rather than on the
    /// page — see `makeFilterField`.
    private let filterField = NSSearchField()

    static func open() {
        // Two launcher windows say the same thing twice. A second ⌘N while one
        // is up and unanswered just brings that question forward.
        if let existing = controllers.last {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            existing.focusFilter()
            return
        }
        let c = LauncherWindowController()
        controllers.append(c)
        c.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        c.focusFilter()
    }

    /// The local session list changed under an open launcher — re-read it.
    /// Pushed rather than polled: the launcher's sources are all local, but
    /// re-reading them on a timer would re-rank rows under the user's cursor
    /// for no reason. This fires when something actually moved.
    static func serverSessionsChanged() {
        for c in controllers {
            c.model.refresh()
            c.syncPlaceholder()
        }
    }

    /// ⌘P over a launcher window focuses its filter field instead of opening a
    /// palette panel on top of it — the page already IS the palette (§2).
    /// Returns false when the key window isn't a launcher, so the caller falls
    /// through to the real palette.
    static func focusSearchFieldIfKey() -> Bool {
        guard let c = controllers.first(where: { $0.window.isKeyWindow }) else { return false }
        c.focusFilter()
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
        toolbar.customSearchView = makeFilterField()
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
        toolbar.onNewSSHHost = { [weak self] host in
            self?.fill { BentoTerminalWindow.fill($0, plainTitle: host, command: ["ssh", host]); return true }
        }
        toolbar.onNewRemoteTmuxHost = { [weak self] host in
            self?.fill { BentoTerminalWindow.fill($0, tmuxHost: host) }
        }
        toolbar.onOpenSettings = { BentoTerminalWindow.onOpenSettings?() }
        // The one item whose meaning is unchanged: it is where you go to type.
        // On a session window it opens the palette because the query has
        // nowhere else to live; here the query lives in this very slot, so it
        // puts the caret back in it.
        toolbar.onOpenSearch = { [weak self] in self?.focusFilter() }
        window.toolbar = toolbar.makeToolbar()
        window.toolbarStyle = .unified
    }

    /// The filter field, in the toolbar's search slot.
    ///
    /// It could have stayed on the page — it was there, focused on appear, and
    /// it drives ↑↓/⏎ over the rows below. Two things decided against it. A
    /// page field would sit roughly twelve points under the toolbar's own
    /// search slot, so the window would show two search fields, one of which
    /// does nothing here; and the whole point of this change is that the two
    /// windows differ as little as possible, which they cannot do while one
    /// puts its query in the title bar and the other puts it in the content.
    ///
    /// The cost is that a toolbar item has to hold first responder and hand
    /// arrow keys to a list it does not own. That is what
    /// `control(_:textView:doCommandBy:)` below does — the same four commands
    /// `KeyDrivenSearchField` handles for the palette, so the keyboard feels
    /// identical on both surfaces. Focus is taken on open and on ⌘P, so
    /// type-to-filter works with no click.
    private func makeFilterField() -> NSSearchField {
        filterField.delegate = self
        filterField.controlSize = .large
        filterField.sendsWholeSearchString = false
        filterField.sendsSearchStringImmediately = true
        filterField.focusRingType = .none
        filterField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filterField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            filterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        syncPlaceholder()
        window.initialFirstResponder = filterField
        return filterField
    }

    /// A field promising "type to filter" over three create rows and no lists
    /// invites typing that can only fail, so it says so instead.
    private func syncPlaceholder() {
        filterField.placeholderString =
            model.isEmpty ? "Nothing running to filter" : "Type to filter…"
    }

    private func focusFilter() {
        window.makeFirstResponder(filterField)
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
            // The filter field is about to leave the window with the toolbar;
            // nothing should still be pointing at it as the window's opening
            // focus.
            shell.initialFirstResponder = nil
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

    func windowWillClose(_ notification: Notification) {
        // Same bookkeeping a session window does on the way out: record the
        // geometry and give the name back. Without it, a launcher that owned
        // the name would take it to the grave and the next window would open
        // unowned — unable to restore, unable to record.
        BentoWindowFrame.release(window)
        Self.controllers.removeAll { $0 === self }
    }

    // MARK: Filter field key handling

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        model.query = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            model.moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)):
            model.moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if let row = model.selectedRow { activate(row) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc clears the filter; at an empty filter it does nothing. This
            // is level 0 — there is no level to pop to, and closing the window
            // would throw away the thing the user just opened.
            model.query = ""
            filterField.stringValue = ""
            return true
        default:
            return false
        }
    }

    /// Row activation, shared by the page's clicks and the field's ⏎.
    func activate(_ row: LauncherModel.Row) {
        switch row.action {
        case .expandHosts:
            model.expandHosts()
        case .expandRecents:
            model.expandRecents()
        case .open(let target):
            fill { OpenTargetProvider.shared.open(target, into: $0) }
        case .create(let action):
            // §7: the agent path leaves the page on purpose — its choices are
            // two-dimensional (a layout grid), which a linear list of rows
            // cannot draw — and because the wizard can be cancelled it does not
            // consume this window. The other two fill it in place.
            if action.consumesShell {
                fill { OpenTargetProvider.shared.perform(action, into: $0) }
            } else {
                OpenTargetProvider.shared.perform(action)
            }
        }
    }
}

// MARK: - The page

/// The level-0 palette, rendered as a page.
///
/// Structure and weighting are `LauncherModel`'s; this file only draws it, and
/// draws it with the palette's own row, header and search field so the two
/// surfaces cannot drift apart visually. No hero art, no tagline, no
/// architecture diagram, no three-step guide — the page has one job, which is
/// to say "here is what you can open" (§5).
struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    /// Unowned: the controller owns the window that owns this view.
    unowned let owner: LauncherWindowController

    var body: some View {
        list
            .frame(minWidth: 480, minHeight: 380)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var list: some View {
        // No search field here: the filter is the toolbar's search item, which
        // is the same slot a session window puts search in (see
        // `LauncherWindowController.makeFilterField`). The page is purely the
        // results, which is also what it is under ⌘P.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // The verbs, first and unfiltered. Everything below them is
                    // "something that already exists"; these three are the only
                    // rows that are true on a machine with nothing on it, which
                    // is why they carry no section header and sit above the
                    // first divider the eye finds.
                    section(LauncherModel.Section.actions.title, model.actions)
                    if model.isEmpty {
                        nothingToOpen
                    } else {
                        Divider().opacity(0.4).padding(.horizontal, 20).padding(.vertical, 4)
                        section(LauncherModel.Section.sessions.title, model.sessions)
                        recentSection
                        hostSection
                        if model.sessions.isEmpty && model.recents.isEmpty && model.hosts.isEmpty {
                            Text("No matches")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }

            Divider().opacity(0.6)
            footer
        }
    }

    // MARK: Nothing to open

    /// No sessions, no recents, no `~/.ssh/config`. One sentence under the
    /// create rows — not a separate screen, and not three empty headers. The
    /// page still has its three real answers; this only explains why the rest of
    /// it is missing, and names the three things it looked for so the reader
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

    @ViewBuilder
    private func section(_ title: String, _ rows: [LauncherModel.Row]) -> some View {
        if !rows.isEmpty {
            if !title.isEmpty { PaletteSectionHeader(title: title) }
            ForEach(rows) { row in
                PaletteRowView(title: row.title, subtitle: row.subtitle,
                               systemImage: row.systemImage,
                               selected: row.id == model.selectedID) {
                    if isOpenSession(row) {
                        Text("open")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { activate(row) }
                .onHover { if $0 { model.select(row.id) } }
            }
        }
    }

    /// Recents: three rows and a "N more" once there are more than three. The
    /// same collapse idiom as the hosts, for the same reason — the tail is
    /// rarely the one you meant — but as a row rather than chips, because a
    /// recent launch needs its folder shown and a capsule cannot hold a path.
    @ViewBuilder
    private var recentSection: some View {
        section(LauncherModel.Section.recents.title, model.recents)
        if model.hasHiddenRecents {
            let row = model.recentsExpanderRow
            Button { model.expandRecents() } label: {
                HStack(spacing: 3) {
                    Text(row.title)
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(model.selectedID == row.id ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 44)
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
    }

    /// Hosts: a chip line plus a count while collapsed, full rows once you
    /// expand or type. Two shapes for one section because the two moods are
    /// different — scanning past them, versus having picked one (§5).
    @ViewBuilder
    private var hostSection: some View {
        if !model.hosts.isEmpty {
            if model.hostsCollapsed {
                HStack(alignment: .firstTextBaseline) {
                    PaletteSectionHeader(title: LauncherModel.Section.hosts.title)
                    Spacer(minLength: 0)
                    Button {
                        model.expandHosts()
                    } label: {
                        HStack(spacing: 2) {
                            Text(model.hostsExpanderRow.title)
                            Image(systemName: "chevron.right").font(.system(size: 9))
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(model.selectedID == model.hostsExpanderRow.id
                                         ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                    .padding(.top, 8)
                }
                chipRow
            } else {
                PaletteSectionHeader(title: LauncherModel.Section.hosts.title)
                ForEach(model.hosts) { row in
                    PaletteRowView(title: row.title, subtitle: nil,
                                   systemImage: row.systemImage,
                                   selected: row.id == model.selectedID) {
                        hostActions(row)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { activate(row) }
                    .onHover { if $0 { model.select(row.id) } }
                }
            }
        }
    }

    private var chipRow: some View {
        // Wrapping, not scrolling: a chip line that scrolls sideways hides
        // hosts behind a gesture, and the expander already answers "show me
        // all of them".
        FlowLayout(spacing: 6) {
            ForEach(model.hostChips) { row in
                Button { activate(row) } label: {
                    Text(row.title)
                        .font(.system(size: 11))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help("ssh \(row.title)")
            }
            if model.hasHiddenHostChips {
                Text("…").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    /// §6: two actions per host. `ssh` opens a plain shell with zero network
    /// wait and no enumeration. `tmux` opens the default session on that host.
    ///
    /// The design spells the second one `tmux ▸` — a drill into a live list of
    /// that host's sessions (§3 level 1). That list does not exist yet: it
    /// needs a cancellable ssh round trip and somewhere to show its failure,
    /// which is the next piece of work. Until then the button is the action the
    /// toolbar's New ▸ menu already offers, and it deliberately does NOT wear
    /// the ▸ — the triangle is a promise of a step, and there is no step yet.
    private func hostActions(_ row: LauncherModel.Row) -> some View {
        HStack(spacing: 6) {
            smallAction("ssh") { activate(row) }
            smallAction("tmux") {
                guard case .open(let target) = row.action,
                      case .sshHost(let alias) = target.kind else { return }
                owner.fill { BentoTerminalWindow.fill($0, tmuxHost: alias) }
            }
        }
    }

    private func smallAction(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(title, action: run)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
    }

    // MARK: Footer

    /// The footer used to hold the two create buttons. They are rows at the top
    /// of the page now (§5), so what is left is the keyboard legend — and the
    /// legend earns its keep twice over now that the filter is up in the title
    /// bar: the caret is somewhere the eye isn't, and nothing else on the page
    /// says that ↑↓ reach these rows.
    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Text("↑↓ to move · ⏎ to open")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Actions

    private func isOpenSession(_ row: LauncherModel.Row) -> Bool {
        guard case .open(let target) = row.action,
              case .tmuxSession(let name) = target.kind else { return false }
        return BentoTerminalWindow.openSessionKeys.contains(TmuxSessionID.local(name).key)
    }

    /// Clicking a row and pressing ⏎ on it have to be the same act, so both go
    /// through the controller's one implementation.
    private func activate(_ row: LauncherModel.Row) { owner.activate(row) }
}

// MARK: - Chip flow

/// A minimal wrapping row layout for the host chips. `Layout` rather than a
/// hand-computed grid because the chips are text-sized and the window resizes.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map { $0.width }.max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for index in row.range {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var range: Range<Int>
        var y: CGFloat
        var height: CGFloat
        var width: CGFloat
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var start = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                rows.append(Row(range: start..<i, y: y, height: lineHeight, width: x - spacing))
                start = i
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        if start < subviews.count {
            rows.append(Row(range: start..<subviews.count, y: y, height: lineHeight, width: x - spacing))
        }
        return rows
    }
}
#endif
