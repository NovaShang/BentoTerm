import BentoFilePreviewKit
import BentoUISharedKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI
import BentoSessionKit
import BentoFoundationKit

// MARK: - Controller

/// The one command palette for the app (⌘P). A borderless floating panel that
/// drops from the top of the focused window, à la Spotlight/Raycast: type to
/// filter, ↑↓ to move, ⏎ to act, Esc to close (or pop up a browse level).
@MainActor
public final class CommandPaletteController {
    public static let shared = CommandPaletteController()
    private init() {}

    private var panel: PalettePanel?
    private var model: PaletteViewModel?
    /// The control the palette was opened from, if any (see `present`).
    private weak var anchorView: NSView?

    /// Open the palette over the focused pane. `fileContext` is that pane's
    /// file source + cwd (nil = no file access); the File section roots itself at
    /// that pane's cwd (resolved lazily so the panel opens instantly). `staticSpecs`
    /// are the caller-wired Commands / New Pane / Recent sections.
    ///
    /// `anchorView` is the control that opened it (the toolbar's search field).
    /// The panel then drops from THAT control rather than the window's launcher
    /// position — a panel appearing somewhere other than what you just clicked
    /// reads as a different feature.
    /// `openingHost` starts the panel already inside an ssh host's session
    /// list — what "New Remote tmux Session → dev" now means, since picking the
    /// machine is only half the question.
    public func present(fileContext: PathPreviewContext?,
                        hostLabel: String, staticSpecs: [PaletteSectionSpec],
                        from anchorView: NSView? = nil,
                        openingHost: String? = nil) {
        // A second ⌘P while open just closes it (toggle) — but a request to
        // open a specific host is not a toggle, it is a different question.
        if panel != nil {
            guard openingHost != nil else { dismiss(); return }
            dismiss()
        }
        self.anchorView = anchorView

        let model = PaletteViewModel(
            fileContext: fileContext, hostLabel: hostLabel,
            staticSpecs: staticSpecs, openingHost: openingHost,
            onClose: { [weak self] in self?.dismiss() })
        self.model = model

        let host = NSHostingController(rootView: CommandPaletteView(model: model))
        host.sizingOptions = [.preferredContentSize]

        let panel = PalettePanel()
        panel.paletteDelegate = self
        panel.contentViewController = host
        self.panel = panel

        anchor(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.recompute()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        model = nil
        anchorView = nil
    }

    /// Keep the panel's top-center pinned as it grows/shrinks with the results.
    func anchor(_ panel: NSPanel) {
        guard let screen = (NSApp.keyWindow?.screen ?? NSScreen.main) else { return }
        let ref = NSApp.keyWindow?.frame ?? screen.visibleFrame
        let size = panel.frame.size

        let x: CGFloat
        let topY: CGFloat
        if let field = anchorView, let fieldWindow = field.window {
            // COVER the control rather than hang below it: top edges flush and
            // centred on it, so the panel's own input row lands where the search
            // field was and the field appears to become the palette. Dropping it
            // underneath left the field visible above a separate panel, which
            // reads as two things instead of one.
            let inWindow = field.convert(field.bounds, to: nil)
            let onScreen = fieldWindow.convertToScreen(inWindow)
            x = onScreen.midX - size.width / 2
            topY = onScreen.maxY
        } else {
            // ⌘P with no control behind it: the classic launcher position,
            // ~18% down from the window's top.
            x = ref.midX - size.width / 2
            topY = ref.maxY - ref.height * 0.18
        }
        var origin = NSPoint(x: x, y: topY - size.height)
        let vis = screen.visibleFrame
        origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)
        origin.y = min(max(origin.y, vis.minY + 8), vis.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }
}

/// Borderless key panel that closes on Esc and when it loses focus (click-away).
final class PalettePanel: NSPanel, NSWindowDelegate {
    weak var paletteDelegate: CommandPaletteController?
    private var anchoredTop: CGFloat?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 660, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .modalPanel
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        delegate = self
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { paletteDelegate?.dismiss() }

    func windowDidResignKey(_ notification: Notification) {
        paletteDelegate?.dismiss()
    }

    // Re-pin top-center as the content (and thus height) changes.
    func windowDidResize(_ notification: Notification) {
        paletteDelegate?.anchor(self)
    }
}

// MARK: - View model

@MainActor
final class PaletteViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var sections: [PaletteSection] = []
    @Published var selectedID: String?

    /// Scroll is driven ONLY by keyboard navigation (and result refreshes), never
    /// by hover. `scrollTick` bumps to request a scroll to `scrollTargetID`;
    /// coupling scroll to hover caused a feedback loop (hover → select → scroll →
    /// a new row slides under the stationary cursor → hover → …). Hover only
    /// highlights, and is briefly suppressed right after a keyboard move so the
    /// rows sliding past don't yank the selection to wherever the mouse rests.
    @Published private(set) var scrollTick = 0
    private(set) var scrollTargetID: String?
    private var suppressHover = false

    let fileContext: PathPreviewContext?
    let hostLabel: String
    private let staticSpecs: [PaletteSectionSpec]
    private let onClose: () -> Void

    /// Where a drill can take the palette. Files browse a directory tree; an
    /// ssh host shows the tmux sessions on it. One stack, because the back
    /// gesture (Esc, backspace on an empty query, the `..` row) has to mean the
    /// same thing wherever you are.
    enum Scope: Equatable {
        case directory(String)
        case sshHost(String)
    }

    /// Pushed by drilling; last = where we are now.
    private var stack: [Scope] = []
    /// True when the panel was opened directly into a host scope — see the
    /// initializer. Popping out of that scope closes rather than empties.
    private var openedAtHostScope = false
    private var seq = 0

    /// The directory being browsed, or nil when a host scope owns the panel.
    private var browseRoot: String? {
        if case .directory(let dir) = stack.last { return dir }
        return stack.isEmpty ? nil : nil
    }

    private var hostScope: String? {
        if case .sshHost(let alias) = stack.last { return alias }
        return nil
    }

    /// The pane cwd, resolved once (one tmux round trip) and memoized so the
    /// panel can open before it lands.
    private var resolvedBase: String?
    private var baseTask: Task<String?, Never>?
    /// The in-flight file-section walk — cancelled on the next keystroke so a
    /// slow search never lags the box (the walker checks cancellation per
    /// wave; a stale result is discarded by the seq guard anyway).
    private var fileSearchTask: Task<PaletteFileResult, Never>?

    init(fileContext: PathPreviewContext?, hostLabel: String,
         staticSpecs: [PaletteSectionSpec], openingHost: String? = nil,
         onClose: @escaping () -> Void) {
        self.fileContext = fileContext
        self.hostLabel = hostLabel
        self.staticSpecs = staticSpecs
        self.onClose = onClose
        if let openingHost {
            stack = [.sshHost(openingHost)]
            // Opened straight into a host, so there is no level below it: the
            // menu that asked for it did not want a general palette, and popping
            // to one would leave an empty panel where the answer used to be.
            openedAtHostScope = true
        }
    }

    var canPop: Bool { !stack.isEmpty }

    private var flatItems: [PaletteItem] { sections.flatMap(\.items) }

    private func base() async -> String? {
        if let resolvedBase { return resolvedBase }
        if let baseTask { return await baseTask.value }
        guard let ctx = fileContext else { return nil }
        let t = Task { await ctx.cwd() }
        baseTask = t
        let v = await t.value
        resolvedBase = v
        return v
    }

    // MARK: Query → sections

    func recompute() {
        seq += 1
        let mySeq = seq
        let q = query
        fileSearchTask?.cancel()

        Task { @MainActor in
            var built: [PaletteSection] = []

            // Inside an ssh host the panel is that host's sessions and nothing
            // else. Files here would be this Mac's files, and Commands would
            // act on this Mac — both read as belonging to the host you just
            // drilled into, and neither does.
            if let alias = hostScope {
                let section = await hostSection(alias: alias, query: q, seq: mySeq)
                guard mySeq == seq else { return }
                if let section { built.append(section) }
                self.sections = built
                if selectedID == nil || !flatItems.contains(where: { $0.id == selectedID }) {
                    selectedID = flatItems.first?.id
                    requestScroll(to: selectedID)
                }
                return
            }

            // Recent Files spec first (empty-state only), then New Pane, so the
            // most "resume where I was" rows sit at the top when idle.
            for spec in staticSpecs where spec.emptyStateOnly {
                if let s = spec.resolved(query: q) { built.append(s) }
            }

            // Live File section (browse current root / fuzzy over its subtree).
            let root: String?
            if let drilled = browseRoot { root = drilled } else { root = await base() }
            if let ctx = fileContext, let root {
                // The walk runs in its own task so the next keystroke can
                // cancel it; the seq guard below still discards stale results.
                let fileTask = Task { @MainActor in
                    await PaletteFileBrowser.items(query: q, root: root, context: ctx)
                }
                fileSearchTask = fileTask
                let result = await fileTask.value
                guard mySeq == seq else { return }
                if canPop || !result.items.isEmpty {
                    var rows = result.items
                    if canPop {
                        rows.insert(parentRow(from: root), at: 0)
                    }
                    if result.partial {
                        // Honest cut-off footer: the fuzzy walk ran out of
                        // budget before the tree was exhausted.
                        rows.append(PaletteItem(
                            id: "files:searched",
                            title: "Searched \(result.dirsSearched) folders without finding everything — refine or drill in",
                            subtitle: nil,
                            systemImage: "magnifyingglass",
                            matchText: "",
                            action: .run {}))
                    }
                    let title = "Files · \(abbreviate(root))"
                    built.append(PaletteSection(id: "files", title: title, items: rows))
                }
            }

            // Non-empty-state static sections (Commands / New Pane).
            for spec in staticSpecs where !spec.emptyStateOnly {
                if let s = spec.resolved(query: q) { built.append(s) }
            }

            guard mySeq == seq else { return }
            self.sections = built
            // Keep the current selection if still present, else select the top.
            if selectedID == nil || !flatItems.contains(where: { $0.id == selectedID }) {
                selectedID = flatItems.first?.id
                requestScroll(to: selectedID)   // new results → back to the top
            }
        }
    }

    private func requestScroll(to id: String?) {
        scrollTargetID = id
        scrollTick &+= 1
    }

    /// Hover highlights the row — unless we just moved by keyboard, in which case
    /// the rows sliding under a parked cursor must not steal the selection.
    func hoverSelect(_ id: String) {
        guard !suppressHover else { return }
        selectedID = id
    }

    // MARK: An ssh host's sessions

    /// The rows for a host scope: what is running there, then the ways in.
    ///
    /// The list is fetched, so this section can be slow in a way no other
    /// section is. It shows a row saying so rather than an empty panel, and the
    /// two "open something" rows are present from the first frame — a host you
    /// cannot list is still a host you can connect to.
    private func hostSection(alias: String, query q: String, seq mySeq: Int) async -> PaletteSection? {
        var rows: [PaletteItem] = [backRow(label: alias)]

        let cached = RemoteTmuxSessions.cached(alias)
        if cached == nil {
            // Show the pending state immediately, then fill in.
            self.sections = [PaletteSection(id: "host", title: "On \(alias)", items: rows + [
                PaletteItem(id: "host:loading", title: "Listing sessions on \(alias)…",
                            systemImage: "ellipsis", matchText: "", action: .run {}),
            ] + openRows(alias: alias))]
        }
        let result: Result<[RemoteTmuxSessions.Session], RemoteTmuxSessions.Failure>
        if let cached {
            result = cached
        } else {
            result = await RemoteTmuxSessions.list(alias: alias)
        }
        guard mySeq == seq else { return nil }

        switch result {
        case .success(let sessions):
            rows += sessions.map { session in
                let windows = session.windows == 1 ? "1 window" : "\(session.windows) windows"
                return PaletteItem(
                    id: "host:\(alias):session:\(session.name)",
                    title: session.name,
                    subtitle: session.attached ? "\(windows) · attached" : windows,
                    systemImage: session.attached ? "record.circle" : "rectangle.stack",
                    matchText: session.name,
                    action: .run { [onClose] in
                        onClose()
                        RemoteTmuxSessions.invalidate(alias)
                        BentoTerminalWindow.focusOrOpen(
                            TmuxSessionID(server: .ssh(host: alias), name: session.name))
                    })
            }
        case .failure(let why):
            rows.append(PaletteItem(id: "host:\(alias):why", title: why.message,
                                    systemImage: "exclamationmark.triangle",
                                    matchText: "", action: .run {}))
        }
        rows += openRows(alias: alias)

        // Rank only the session rows: the back row and the two verbs are
        // navigation, and a list that loses its exit when you type is a trap.
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            return PaletteSection(id: "host", title: "On \(alias)", items: rows)
        }
        let fixedIDs = Set(rows.map(\.id).filter {
            $0.hasSuffix(":new") || $0.hasSuffix(":shell") || $0 == "host:back"
        })
        let fixed = rows.filter { fixedIDs.contains($0.id) }
        let ranked = PaletteFuzzy.rank(query: q,
                                       items: rows.filter { !fixedIDs.contains($0.id) },
                                       limit: 12)
        return PaletteSection(id: "host", title: "On \(alias)", items: ranked + fixed)
    }

    /// The two things you can always do with a host, listed or not.
    private func openRows(alias: String) -> [PaletteItem] {
        [
            PaletteItem(id: "host:\(alias):new", title: "New session…",
                        subtitle: "Create a tmux session on \(alias)",
                        systemImage: "plus.rectangle.on.rectangle", matchText: "new session",
                        action: .run { [onClose] in
                            onClose()
                            RemoteTmuxSessions.invalidate(alias)
                            BentoTerminalWindow.focusOrOpen(
                                TmuxSessionID(server: .ssh(host: alias),
                                              name: BentoTerminalWindow.nextSessionName()))
                        }),
            PaletteItem(id: "host:\(alias):shell", title: "Shell (no tmux)",
                        subtitle: "ssh \(alias)",
                        systemImage: "terminal", matchText: "shell ssh no tmux",
                        action: .run { [onClose] in
                            onClose()
                            BentoTerminalWindow.newSSHWindow(host: alias)
                        }),
        ]
    }

    private func backRow(label: String) -> PaletteItem {
        PaletteItem(id: "host:back", title: "..", subtitle: "Back",
                    systemImage: "arrow.up.left", matchText: "..",
                    action: .popScope)
    }

    /// Pop one level. `.run` closes the panel first, which is why the back row
    /// has its own action instead.
    private func popScope() {
        guard canPop else { return }
        if openedAtHostScope, stack.count == 1 { onClose(); return }
        stack.removeLast()
        query = ""
        selectedID = nil
        recompute()
    }

    private func parentRow(from root: String) -> PaletteItem {
        let parent = (root as NSString).deletingLastPathComponent
        return PaletteItem(id: "file:..", title: "..", subtitle: abbreviate(parent),
                           systemImage: "arrow.up.left", matchText: "..",
                           action: .drill(dir: parent))
    }

    // MARK: Navigation

    func moveSelection(_ delta: Int) {
        let items = flatItems
        guard !items.isEmpty else { return }
        let idx = items.firstIndex { $0.id == selectedID } ?? 0
        let next = (idx + delta + items.count) % items.count
        selectedID = items[next].id
        requestScroll(to: selectedID)
        suppressHoverBriefly()
    }

    private func suppressHoverBriefly() {
        suppressHover = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            suppressHover = false
        }
    }

    func activateSelected() {
        guard let id = selectedID, let item = flatItems.first(where: { $0.id == id }) else { return }
        activate(item)
    }

    func activate(_ item: PaletteItem) {
        switch item.action {
        case .run(let fn):
            onClose()
            fn()
        case .drill(let dir):
            stack.append(.directory(dir))
            query = ""
            selectedID = nil
            recompute()
        case .drillHost(let alias):
            stack.append(.sshHost(alias))
            query = ""
            selectedID = nil
            recompute()
        case .popScope:
            popScope()
        case .preview(let path, let line):
            onClose()
            preview(path: path, line: line)
        }
    }

    private func preview(path: String, line: Int?) {
        guard let ctx = fileContext else { return }
        BentoTerminalWindow.openPreview(path: path, line: line, context: ctx)
        PaletteRecents.shared.recordFile(path: path, host: hostLabel)
    }

    /// Esc / backspace-on-empty: pop a level, or close at the top.
    func escapeOrPop() {
        if canPop {
            popScope()
        } else {
            onClose()
        }
    }

    func backspaceOnEmpty() -> Bool {
        guard query.isEmpty, canPop else { return false }
        escapeOrPop()
        return true
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - SwiftUI view

struct CommandPaletteView: View {
    @ObservedObject var model: PaletteViewModel

    var body: some View {
        VStack(spacing: 0) {
            KeyDrivenSearchField(
                text: model.query,
                placeholder: "Search files and commands…",
                onChange: { model.query = $0; model.recompute() },
                onMove: { model.moveSelection($0) },
                onActivate: { model.activateSelected() },
                onCancel: { model.escapeOrPop() },
                onBackspaceOnEmpty: { model.backspaceOnEmpty() })
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider().opacity(0.6)
            results
        }
        .frame(width: 660)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder private var results: some View {
        if model.sections.isEmpty {
            Text(model.query.isEmpty ? "Type to search files and commands" : "No matches")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.sections) { section in
                            Section {
                                ForEach(section.items) { item in
                                    PaletteRowView(title: item.title, subtitle: item.subtitle,
                                                   systemImage: item.systemImage,
                                                   selected: item.id == model.selectedID)
                                        .id(item.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture { model.activate(item) }
                                        .onHover { if $0 { model.hoverSelect(item.id) } }
                                }
                            } header: {
                                PaletteSectionHeader(title: section.title)
                                    .background(.regularMaterial)
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 380)
                // Keyboard-driven scroll only (see PaletteViewModel.scrollTick).
                // No anchor → scroll the minimum to reveal the row, so an
                // already-visible selection doesn't jump.
                .onChange(of: model.scrollTick) { _, _ in
                    guard let id = model.scrollTargetID else { return }
                    withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo(id) }
                }
            }
        }
    }
}

/// A section label ("SESSIONS"). Shared with the launcher for the same reason
/// the row is: one list, two sizes. The caller supplies the background, since
/// the palette pins its headers over a material and the page does not.
struct PaletteSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row of a launcher list: symbol, title, dimmed second line, selection
/// fill. Shared verbatim by the ⌘P palette and the empty-state launcher — those
/// two are the same list rendered at different sizes (docs/launcher-design.md
/// §2), and a row that looked different in one of them would say they were
/// different features.
///
/// `accessory` is the only thing the launcher adds: the host row's trailing
/// [ssh] [tmux] buttons (§6). Nothing else about the row is parameterised,
/// because nothing else is allowed to diverge.
struct PaletteRowView<Accessory: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let selected: Bool
    /// How many lines the second line may take. One everywhere except the
    /// launcher's three create rows: those explain themselves in a full
    /// sentence, and the launcher's left column is a third of a window rather
    /// than the width of a palette, so a sentence cut through the middle would
    /// be the only place on either surface where the explanation stops
    /// explaining. Wrapping is the smaller divergence.
    var subtitleLineLimit: Int = 1
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(selected ? Color.white : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.white : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(selected ? Color.white.opacity(0.75) : .secondary)
                        .lineLimit(subtitleLineLimit)
                        // A wrapped sentence loses nothing at the tail; a
                        // one-line path loses its meaning there, which is why
                        // the single-line case keeps eliding the middle.
                        .truncationMode(subtitleLineLimit > 1 ? .tail : .middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor : .clear))
        .padding(.horizontal, 8)
    }
}

extension PaletteRowView where Accessory == EmptyView {
    init(title: String, subtitle: String?, systemImage: String, selected: Bool,
         subtitleLineLimit: Int = 1) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage,
                  selected: selected, subtitleLineLimit: subtitleLineLimit,
                  accessory: { EmptyView() })
    }
}

// MARK: - Search field (AppKit, for reliable ↑↓/⏎/Esc handling)

/// An `NSTextField` whose field-editor commands drive a list: typing filters,
/// ↑↓ moves the selection, ⏎ activates, Esc closes (or pops a level), and ⌫ on
/// an empty query pops a level. SwiftUI's `TextField` can't intercept these
/// while focused, so the input is AppKit.
///
/// Closures rather than a concrete model, because both launcher surfaces need
/// exactly these keys and they must feel identical: the empty state IS the
/// palette (docs/launcher-design.md §2), and "the arrow keys work differently
/// over there" is precisely how two renderings of one list stop reading as one
/// list. It also focuses itself on appear — the field is the page's first
/// responder, so you can type without clicking.
struct KeyDrivenSearchField: NSViewRepresentable {
    let text: String
    var placeholder: String
    var fontSize: CGFloat = 18
    var onChange: (String) -> Void
    var onMove: (Int) -> Void
    var onActivate: () -> Void
    var onCancel: () -> Void
    /// Return true to swallow ⌫ (a level was popped); false to let it edit.
    var onBackspaceOnEmpty: () -> Bool = { false }
    /// Bump to demand focus. ⌘P over the empty state focuses the field rather
    /// than opening a panel over it (§2: the muscle memory must not miss).
    var focusToken: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize, weight: .regular)
        field.placeholderString = placeholder
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.owner = self
        field.placeholderString = placeholder
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var owner: KeyDrivenSearchField
        var lastFocusToken: Int
        init(_ owner: KeyDrivenSearchField) {
            self.owner = owner
            self.lastFocusToken = owner.focusToken
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            owner.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                owner.onMove(1); return true
            case #selector(NSResponder.moveUp(_:)):
                owner.onMove(-1); return true
            case #selector(NSResponder.insertNewline(_:)):
                owner.onActivate(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                owner.onCancel(); return true
            case #selector(NSResponder.deleteBackward(_:)):
                return owner.onBackspaceOnEmpty()
            default:
                return false
            }
        }
    }
}
#endif
