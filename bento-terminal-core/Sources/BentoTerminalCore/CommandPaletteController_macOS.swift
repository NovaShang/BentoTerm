#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI

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
    public func present(fileContext: PathPreviewContext?,
                        hostLabel: String, staticSpecs: [PaletteSectionSpec],
                        from anchorView: NSView? = nil) {
        // A second ⌘P while open just closes it (toggle).
        if panel != nil { dismiss(); return }
        self.anchorView = anchorView

        let model = PaletteViewModel(
            fileContext: fileContext, hostLabel: hostLabel,
            staticSpecs: staticSpecs, onClose: { [weak self] in self?.dismiss() })
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

    /// Browse roots pushed by drilling into directories; last = current root.
    private var rootStack: [String] = []
    private var seq = 0

    /// The pane cwd, resolved once (one tmux round trip) and memoized so the
    /// panel can open before it lands.
    private var resolvedBase: String?
    private var baseTask: Task<String?, Never>?

    init(fileContext: PathPreviewContext?, hostLabel: String,
         staticSpecs: [PaletteSectionSpec], onClose: @escaping () -> Void) {
        self.fileContext = fileContext
        self.hostLabel = hostLabel
        self.staticSpecs = staticSpecs
        self.onClose = onClose
    }

    var canPop: Bool { !rootStack.isEmpty }

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

        Task { @MainActor in
            var built: [PaletteSection] = []

            // Recent Files spec first (empty-state only), then New Pane, so the
            // most "resume where I was" rows sit at the top when idle.
            for spec in staticSpecs where spec.emptyStateOnly {
                if let s = spec.resolved(query: q) { built.append(s) }
            }

            // Live File section (browse current root / fuzzy over its subtree).
            let root: String?
            if let drilled = rootStack.last { root = drilled } else { root = await base() }
            if let ctx = fileContext, let root {
                let items = await PaletteFileBrowser.items(query: q, root: root, context: ctx)
                guard mySeq == seq else { return }
                if canPop || !items.isEmpty {
                    var rows = items
                    if canPop {
                        rows.insert(parentRow(from: root), at: 0)
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
            rootStack.append(dir)
            query = ""
            selectedID = nil
            recompute()
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

    /// Esc / backspace-on-empty: pop a browse level, or close at the top.
    func escapeOrPop() {
        if canPop {
            rootStack.removeLast()
            query = ""
            selectedID = nil
            recompute()
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
            PaletteSearchField(model: model)
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
                                    PaletteRow(item: item, selected: item.id == model.selectedID)
                                        .id(item.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture { model.activate(item) }
                                        .onHover { if $0 { model.hoverSelect(item.id) } }
                                }
                            } header: {
                                Text(section.title.uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 8)
                                    .padding(.bottom, 3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
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

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(selected ? Color.white : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.white : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sub = item.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(selected ? Color.white.opacity(0.75) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor : .clear))
        .padding(.horizontal, 8)
    }
}

// MARK: - Search field (AppKit, for reliable ↑↓/⏎/Esc handling)

/// An `NSTextField` whose field-editor commands drive the model: typing filters,
/// ↑↓ moves the selection, ⏎ activates, Esc pops/closes, and ⌫ on an empty
/// query pops a browse level. SwiftUI's `TextField` can't intercept these while
/// focused, so the input is AppKit.
private struct PaletteSearchField: NSViewRepresentable {
    @ObservedObject var model: PaletteViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.placeholderString = "Search files and commands…"
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.model = model
        if field.stringValue != model.query { field.stringValue = model.query }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var model: PaletteViewModel
        init(model: PaletteViewModel) { self.model = model }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            model.query = field.stringValue
            model.recompute()
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                model.moveSelection(1); return true
            case #selector(NSResponder.moveUp(_:)):
                model.moveSelection(-1); return true
            case #selector(NSResponder.insertNewline(_:)):
                model.activateSelected(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                model.escapeOrPop(); return true
            case #selector(NSResponder.deleteBackward(_:)):
                return model.backspaceOnEmpty()
            default:
                return false
            }
        }
    }
}
#endif
