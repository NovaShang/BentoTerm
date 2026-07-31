#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI

// MARK: - The window

/// A window that has no session yet and asks what to put in it.
///
/// **It is the same window that becomes the session.** Picking a row hands this
/// window's shell to `TerminalWindowManager`, which configures it in place —
/// same `NSWindow` object, same screen position, same z-order. That is the
/// whole reason the launcher is a window rather than a sheet or a panel: the
/// old flow created the window first and then had to express failure inside a
/// terminal that was already on screen (docs/launcher-design.md §4), and the
/// fix is to let the window exist *before* the session without pretending a
/// session is there.
///
/// **Filling it does not move or resize it.** It wears the frame the session
/// windows use, so picking something changes the content and nothing else. A
/// small fixed page was tried and rejected: it made ⌘N over a large terminal
/// pleasant to read, but every pick then jumped the window to the terminal's
/// remembered geometry, and a window that resizes as you choose reads as "a new
/// window appeared" — precisely what the in-place transition exists to avoid.
/// The empty page at a large size is the cheaper of the two costs.
///
/// The one case where the shell is not consumed is picking a session that is
/// already open in another window: there is nothing to fill, that window comes
/// forward, and this one closes rather than sitting behind it as a duplicate
/// question.
///
/// Launcher windows are always standalone — never joined to a tab group. ⌘N
/// means "one more window" (`4f93e6b`), and a window that has not yet decided
/// what it contains has no business appearing as a tab in a group of sessions.
@MainActor
final class LauncherWindowController: NSObject, NSWindowDelegate {
    private static var controllers: [LauncherWindowController] = []

    let window: TerminalSessionWindow
    let model: LauncherModel

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

    /// ⌘P over a launcher window focuses its filter field instead of opening a
    /// palette panel on top of it — the page already IS the palette (§2).
    /// Returns false when the key window isn't a launcher, so the caller falls
    /// through to the real palette.
    static func focusSearchFieldIfKey() -> Bool {
        guard let c = controllers.first(where: { $0.window.isKeyWindow }) else { return false }
        c.model.focusSearch()
        return true
    }

    /// The page's own size, not a session window's.
    ///
    /// Only used when session windows are already open, so their saved frame
    /// belongs to one of them and this page cannot borrow it.
    static let contentSize = NSSize(width: 820, height: 560)

    private override init() {
        model = LauncherModel()
        window = TerminalSessionWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        super.init()
        window.title = "BentoTerm"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        let host = NSHostingController(rootView: LauncherView(model: model, owner: self))
        window.contentViewController = host
        // Size AFTER the content view controller, never before: assigning one
        // resizes the window to the SwiftUI fitting size, which for this page
        // is its minimum.
        //
        // Wear the session windows' remembered frame when this launcher is going
        // to BE the first session window: filling it in place should change the
        // content, not the geometry. A window that resizes as you pick something
        // reads as "a new window appeared", which is exactly what the in-place
        // transition exists to avoid. With windows already open the saved frame
        // belongs to one of them, so this one just centres at its own size.
        if !BentoTerminalWindow.hasOpenWindows,
           window.setFrameUsingName(TerminalWindowManager.frameName) {
            return
        }
        window.setContentSize(Self.contentSize)
        window.center()
    }

    /// A row was activated. Everything routes through here so there is exactly
    /// one place that knows the window is consumed.
    func fill(_ body: (TerminalSessionWindow) -> Bool) {
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

    func windowWillClose(_ notification: Notification) {
        Self.controllers.removeAll { $0 === self }
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
        VStack(spacing: 0) {
            KeyDrivenSearchField(
                text: model.query,
                // Nothing to filter is worth saying out loud. A field promising
                // "type to filter" over three create rows and no lists invites
                // typing that can only fail.
                placeholder: model.isEmpty ? "Nothing running to filter" : "Type to filter…",
                fontSize: 16,
                onChange: { model.query = $0 },
                onMove: { model.moveSelection($0) },
                onActivate: { activateSelection() },
                // Esc clears the filter; at an empty filter it does nothing.
                // This is level 0 — there is no level to pop to, and closing
                // the window would throw away the thing the user just opened.
                onCancel: { model.query = "" },
                focusToken: model.focusToken)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider().opacity(0.6)

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
    /// legend is worth keeping, because the page opens with the field focused
    /// and nothing else says that ↑↓ reach the rows.
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

    private func activateSelection() {
        guard let row = model.selectedRow else { return }
        activate(row)
    }

    private func activate(_ row: LauncherModel.Row) {
        switch row.action {
        case .expandHosts:
            model.expandHosts()
        case .expandRecents:
            model.expandRecents()
        case .open(let target):
            owner.fill { OpenTargetProvider.shared.open(target, into: $0) }
        case .create(let action):
            // §7: the agent path leaves the page on purpose — its choices are
            // two-dimensional (a layout grid), which a linear list of rows
            // cannot draw — and because the wizard can be cancelled it does not
            // consume this window. The other two fill it in place.
            if action.consumesShell {
                owner.fill { OpenTargetProvider.shared.perform(action, into: $0) }
            } else {
                OpenTargetProvider.shared.perform(action)
            }
        }
    }
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
