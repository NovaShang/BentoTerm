import BentoFilePreviewKit
import BentoUISharedKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI
import BentoSessionKit
import BentoFoundationKit

// MARK: - File watcher

/// Watches ONE file for content changes and calls `onChange` (debounced), so a
/// pinned preview can track the file an agent is editing. Agents/editors often
/// replace files atomically (write temp → rename), which orphans the fd — so on
/// delete/rename we re-open and re-arm. Local files only.
final class LocalFileWatcher {
    private let path: String
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.novashang.bento.filewatch")
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounce: DispatchWorkItem?
    private var cancelled = false

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.onChange = onChange
        queue.async { [weak self] in self?.arm() }
    }

    private func arm() {
        guard !cancelled, fd < 0 else { return }
        let f = open(path, O_EVTONLY)
        guard f >= 0 else {
            // Mid atomic-replace (temp not yet renamed in) — retry shortly.
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.arm() }
            return
        }
        fd = f
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: f,
            eventMask: [.write, .extend, .delete, .rename, .revoke, .link],
            queue: queue)
        src.setEventHandler { [weak self] in self?.handle(src.data) }
        src.setCancelHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            close(self.fd); self.fd = -1
        }
        source = src
        src.resume()
    }

    private func handle(_ events: DispatchSource.FileSystemEvent) {
        let replaced = !events.isDisjoint(with: [.delete, .rename, .revoke])
        if replaced {
            source?.cancel(); source = nil   // cancel handler closes the fd
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.arm() }
        }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.cancelled else { return }
            self.onChange()
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func cancel() {
        cancelled = true
        queue.async { [weak self] in
            self?.debounce?.cancel()
            self?.source?.cancel(); self?.source = nil
        }
    }
}

// MARK: - Pinned preview

/// One tab in the side dock: a file, how to reload it, and its render state.
/// While pinned it watches the file (local panes) and reloads on change; the
/// WebView preserves scroll on a same-file re-render, so watching an agent edit
/// doesn't yank you to the top.
@MainActor
final class PinnedPreview: ObservableObject, Identifiable {
    let id: String            // resolvedPath — also the dedupe key
    let path: String
    let line: Int?
    let context: PathPreviewContext
    let title: String

    enum Phase {
        case loading
        case loaded(FilePreviewData)
        case failed(String)
    }
    @Published var phase: Phase

    nonisolated(unsafe) private var watcher: LocalFileWatcher?
    private var reloadTask: Task<Void, Never>?

    /// `path` is an already-resolved absolute path. `initial` seeds the first
    /// render when the caller already has it (a detach); otherwise the tab loads
    /// itself (loading → loaded/failed).
    init(path: String, line: Int?, context: PathPreviewContext, initial: FilePreviewData?) {
        self.id = path
        self.path = path
        self.line = line
        self.context = context
        self.title = (path as NSString).lastPathComponent
        self.phase = initial.map(Phase.loaded) ?? .loading
        if context.isLocal {
            watcher = LocalFileWatcher(path: path) { [weak self] in
                Task { @MainActor in self?.reload() }
            }
        }
        if initial == nil { reload() }
    }

    func reload() {
        reloadTask?.cancel()
        let path = path, line = line, context = context
        reloadTask = Task { @MainActor [weak self] in
            do {
                let data = try await FilePreviewLoader.load(path: path, line: line, context: context)
                guard !Task.isCancelled else { return }
                self?.phase = .loaded(data)
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        reloadTask?.cancel()
    }

    /// The whole dock can go away with its window (windowWillClose tears the
    /// manager down) without close() ever running — don't leak the watch fd.
    deinit { watcher?.cancel() }
}

// MARK: - Dock model

/// One tab in the dock. A file the agent is writing and a page the agent has
/// built are the same question — "what did that just do?" — so they are two
/// kinds of the same tab rather than two panels.
///
/// Main-actor isolated because both payloads are: these are live view models,
/// not values.
@MainActor
enum DockTab: @preconcurrency Identifiable {
    case file(PinnedPreview)
    case web(WebTab)

    /// File tabs key on their resolved path (a file tab never becomes a
    /// different file). Web tabs carry a synthetic id, because a browser tab
    /// DOES become a different URL and keying on that would rebuild the
    /// WKWebView — losing scroll, forms and login — on every click.
    var id: String {
        switch self {
        case .file(let p): return p.id
        case .web(let w): return w.id
        }
    }

    var title: String {
        switch self {
        case .file(let p): return p.title
        case .web(let w): return w.title
        }
    }

    var icon: String {
        switch self {
        case .file: return "doc.text"
        case .web: return "globe"
        }
    }

    /// The hover text. Not a visible label: a strip this narrow cannot spend
    /// room restating what the window title already says, but two dev servers
    /// that both render as ":5173" do need SOMETHING that tells them apart,
    /// and a tooltip costs nothing until it is asked for.
    var tooltip: String {
        switch self {
        case .file(let p): return p.path
        case .web(let w):
            let address = w.displayURL?.absoluteString ?? "New Tab"
            return w.host.isLocal ? address : "\(address) — \(w.host.label)"
        }
    }

    var fileTab: PinnedPreview? {
        if case .file(let p) = self { return p }
        return nil
    }

    func stop() {
        switch self {
        case .file(let p): p.stop()
        case .web(let w): w.stop()
        }
    }
}

/// The window's side dock: a permanent file-tree tab (the focused pane's
/// working directory) + an ordered set of preview tabs. One per window (owned
/// by `TerminalWindowManager`); persists across terminal tab switches.
@MainActor
final class PreviewDockModel: ObservableObject {
    /// The permanent, uncloseable first tab: the active pane's directory tree.
    static let treeTabID = "bento://tree"

    @Published private(set) var tabs: [DockTab] = []
    @Published var selectedID: String? = PreviewDockModel.treeTabID

    /// Resolves the CURRENT focused pane's file context at load time (set once
    /// by the manager) — the tree always lists where the user actually is.
    var treeContextProvider: (() -> PathPreviewContext?)?
    /// Bumped when the focused tab/pane may have changed → the tree reloads.
    @Published private(set) var treeGeneration = 0
    func refreshTree() { treeGeneration &+= 1 }

    var selected: DockTab? { tabs.first { $0.id == selectedID } }

    /// Open a preview as a dock tab (`path` already resolved). Re-opening a
    /// docked file just focuses + reloads its tab.
    func open(path: String, line: Int?, context: PathPreviewContext) {
        if let existing = tabs.first(where: { $0.id == path })?.fileTab {
            existing.reload()
            selectedID = existing.id
            return
        }
        let tab = PinnedPreview(path: path, line: line, context: context, initial: nil)
        tabs.append(.file(tab))
        selectedID = tab.id
    }

    /// Follow a breadcrumb pick: this tab BECOMES the file that was picked.
    /// Navigating a path is moving around inside one view of the filesystem —
    /// piling up a tab per hop turns three clicks into three tabs to close.
    /// Opening from the file tree still makes a tab; that's a deliberate
    /// "keep this one open".
    func replace(_ id: String, with path: String, line: Int? = nil,
                 context: PathPreviewContext) {
        // Already open elsewhere (including this very tab) — go there rather
        // than end up with the same file twice.
        if let existing = tabs.first(where: { $0.id == path })?.fileTab {
            existing.reload()
            selectedID = existing.id
            return
        }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            open(path: path, line: line, context: context)
            return
        }
        tabs[index].stop()          // the outgoing file stops being watched
        let tab = PinnedPreview(path: path, line: line, context: context, initial: nil)
        tabs[index] = .file(tab)
        selectedID = tab.id
    }

    /// Open a page in the dock.
    ///
    /// Unlike a file, the same URL twice is two legitimate tabs (two states of
    /// one app), so this never dedupes — the browser convention, and the one
    /// that does not silently throw away what you were looking at.
    @discardableResult
    func openWeb(url: URL?, origin: LinkOrigin?) -> WebTab {
        let tab = WebTab(url: url, origin: origin)
        // A page asking for a new tab (`target="_blank"`) gets a real one, on
        // the same machine as the page that asked.
        tab.onOpenInNewTab = { [weak self] target in
            self?.openWeb(url: target, origin: origin)
        }
        tabs.append(.web(tab))
        selectedID = tab.id
        return tab
    }

    func close(_ id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].stop()
        tabs.remove(at: idx)
        if selectedID == id {
            selectedID = idx < tabs.count ? tabs[idx].id
                : (tabs.last?.id ?? Self.treeTabID)
        }
    }

    /// Close every preview tab but `keep` (nil = all of them). Each one is
    /// `stop()`ped rather than dropped, so a file being watched stops being
    /// watched — closing twenty tabs must not leave twenty reloaders running.
    func closeAll(except keep: String?) {
        for index in tabs.indices where tabs[index].id != keep {
            tabs[index].stop()
        }
        tabs.removeAll { $0.id != keep }
        if selectedID != keep {
            selectedID = keep ?? Self.treeTabID
        }
    }
}

// MARK: - Dock view

/// Widths of the tab strip's content and of the space it has to live in. Two
/// keys rather than one measurement because the answer we want — "is anything
/// hidden?" — is a comparison between them.
private struct ContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct StripWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct PreviewDock: View {
    @ObservedObject var model: PreviewDockModel
    @State private var contentWidth: CGFloat = 0
    @State private var stripWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Divider()   // hairline under the title-bar band — panel starts here
            tabBar
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // Hiding the panel lives in the window chrome (the toolbar toggle / ⌥⌘P),
    // not in the panel itself — the tab bar is tabs only. The tree tab is
    // permanent and uncloseable; preview tabs follow it.
    //
    // The dock is narrow by design, so this strip overflows after a handful of
    // files. It has always scrolled, which is not the same as being reachable:
    // with the indicators hidden nothing said there was more, a plain mouse
    // wheel does not scroll a horizontal strip, and opening a file selected a
    // tab that could be off-screen. So: the strip scrolls itself to the
    // selection, and a chevron appears — only when something is actually
    // hidden — listing every tab.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        PreviewDockTab(
                            title: "Files",
                            icon: "folder",
                            tooltip: "The focused pane's folder",
                            active: model.selected == nil,
                            closable: false,
                            onSelect: { model.selectedID = PreviewDockModel.treeTabID },
                            onClose: {})
                            .id(PreviewDockModel.treeTabID)
                        ForEach(model.tabs) { tab in
                            PreviewDockTab(
                                title: tab.title,
                                icon: tab.icon,
                                tooltip: tab.tooltip,
                                active: tab.id == model.selectedID,
                                closable: true,
                                onSelect: { model.selectedID = tab.id },
                                onClose: { model.close(tab.id) })
                                .id(tab.id)
                                .contextMenu { closeMenuItems(for: tab) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(widthReporter(ContentWidthKey.self))
                }
                .background(widthReporter(StripWidthKey.self))
                .onPreferenceChange(ContentWidthKey.self) { contentWidth = $0 }
                .onPreferenceChange(StripWidthKey.self) { stripWidth = $0 }
                // Opening a file selects its tab; if that tab is off to the
                // right, selecting it silently is the bug this fixes.
                .onChange(of: model.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            newTabButton
            if overflowing {
                overflowMenu
            }
        }
        .frame(height: 36)
    }

    /// "+" makes a real, empty tab with the cursor in its address bar.
    ///
    /// It used to open the command palette, on the theory that a blank tab has
    /// nothing to show. But "I know the URL I want" is the ordinary case, and
    /// routing that through a file-search panel is a puzzle, not a shortcut.
    private var newTabButton: some View {
        Button {
            model.openWeb(url: nil, origin: BentoTerminalWindow.focusedLinkOrigin())
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New tab")
    }

    /// True when the strip is wider than the space it has — i.e. some tab is
    /// off-screen right now. The 1pt slack keeps rounding from flickering the
    /// chevron on and off at the exact fit.
    private var overflowing: Bool { contentWidth > stripWidth + 1 }

    /// Every tab, reachable without scrolling — plus the two ways out of having
    /// too many, which is how most people arrive at this menu.
    private var overflowMenu: some View {
        Menu {
            Button {
                model.selectedID = PreviewDockModel.treeTabID
            } label: {
                Label("Files", systemImage: model.selected == nil ? "checkmark" : "folder")
            }
            Divider()
            ForEach(model.tabs) { tab in
                Button {
                    model.selectedID = tab.id
                } label: {
                    // A checkmark on the current one; the rest keep their kind's
                    // icon so the list does not jump as the selection moves.
                    // The host is part of the label because with three agents on
                    // three boxes, ":5173" alone names three different pages.
                    // The menu has room the strip does not, so the full
                    // address goes here — this is where you look when two tabs
                    // read the same.
                    Label(tab.tooltip, systemImage: tab.id == model.selectedID ? "checkmark" : tab.icon)
                }
            }
            Divider()
            Button("Close Other Tabs") { model.closeAll(except: model.selectedID) }
                .disabled(model.tabs.count < 2)
            Button("Close All Tabs") { model.closeAll(except: nil) }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.trailing, 6)
        .help("\(model.tabs.count) open tabs")
    }

    @ViewBuilder
    private func closeMenuItems(for tab: DockTab) -> some View {
        Button("Close") { model.close(tab.id) }
        Button("Close Others") { model.closeAll(except: tab.id) }
        Button("Close All") { model.closeAll(except: nil) }
    }

    private func widthReporter<K: PreferenceKey>(_ key: K.Type) -> some View
    where K.Value == CGFloat {
        GeometryReader { geo in
            Color.clear.preference(key: key, value: geo.size.width)
        }
    }

    @ViewBuilder private var content: some View {
        if let tab = model.selected {
            switch tab {
            case .file(let file):
                PreviewDockContent(tab: file,
                                   onOpenPath: { model.replace(file.id, with: $0,
                                                               context: file.context) })
                    .id(file.id)   // stable per tab → WebView reuse preserves scroll
            case .web(let web):
                // Keyed on the tab's synthetic id, NOT its URL: navigating must
                // not rebuild the WKWebView.
                WebBrowserView(tab: web)
                    .id(web.id)
            }
        } else {
            // The shared lazy tree (same view as the iOS Files sheet) —
            // `treeGeneration` maps onto reloadKey so pane switches re-root it.
            FileTreeBrowserView(
                reloadKey: model.treeGeneration,
                contextProvider: { model.treeContextProvider?() },
                onOpenFile: { path, ctx in model.open(path: path, line: nil, context: ctx) },
                isCompact: true)
        }
    }
}

private struct PreviewDockContent: View {
    @ObservedObject var tab: PinnedPreview
    /// A file picked from the breadcrumb dropdown takes this tab over.
    let onOpenPath: (String) -> Void

    var body: some View {
        switch tab.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let data):
            FilePreviewContentView(data: data, onOpenPath: onOpenPath)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PreviewDockTab: View {
    let title: String
    let icon: String
    let tooltip: String
    let active: Bool
    let closable: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    // Select and close are SIBLING buttons — a whole-tab tap gesture over a
    // nested close Button swallowed the close clicks.
    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundStyle(active ? Color.accentColor : .secondary)
                    Text(title)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(active ? .primary : .secondary)
                }
                .padding(.leading, 9)
                .padding(.trailing, closable ? 0 : 9)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if closable {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .opacity(hovering || active ? 1 : 0)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .padding(.leading, 2)
            }
        }
        .frame(maxWidth: 160)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25)
                             : (hovering ? Color.primary.opacity(0.06) : .clear)))
        .onHover { hovering = $0 }
        .help(tooltip)
    }
}

#endif
