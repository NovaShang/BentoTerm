import SwiftUI

/// Pick one directory by walking to it, a level at a time.
///
/// Deliberately NOT the expandable tree (`FileTreeBrowserView`): that one is
/// rooted at the pane's cwd and can only name paths *below* it, so a pane
/// sitting deep inside a repo could never pick the repo — or a sibling, or
/// anything at all above. Here the unit is one directory listing: you see
/// where you are, tap a folder to go in, tap the breadcrumb (or ↑) to go
/// back out, and the directory you are standing in IS the pick. One state,
/// no second "which row is checked" that can disagree with the list.
///
/// Files are listed but inert — you recognise a directory by what's in it,
/// and this picker returns directories.
///
/// Transport-agnostic like the tree browser: everything arrives through
/// `PathPreviewContext`, so local (macOS) and SFTP-over-SSH (iOS) both work.
public struct DirectoryPickerView: View {
    private let contextProvider: () -> PathPreviewContext?
    /// Bump to re-resolve the pane and start over at its cwd.
    private let reloadKey: AnyHashable
    private let confirmTitle: String
    private let onPick: (String) -> Void
    private let isCompact: Bool

    @StateObject private var store = DirectoryLevelStore()
    @State private var nav = DirectoryPickerPath()
    /// Dotfiles hidden by default (the eye toggles them) — a render filter,
    /// never a refetch.
    @State private var showHidden = false

    public init(reloadKey: AnyHashable = 0,
                contextProvider: @escaping () -> PathPreviewContext?,
                confirmTitle: String = "Use This Folder",
                onPick: @escaping (String) -> Void,
                isCompact: Bool = false) {
        self.reloadKey = reloadKey
        self.contextProvider = contextProvider
        self.confirmTitle = confirmTitle
        self.onPick = onPick
        self.isCompact = isCompact
    }

    public var body: some View {
        VStack(spacing: 0) {
            locationBar
            Divider()
            levelBody
            Divider()
            confirmBar
        }
        .task(id: reloadKey) { await start() }
    }

    // MARK: - Location (where we are + the ways up)

    private var locationBar: some View {
        HStack(spacing: 4) {
            Button {
                go { $0.up() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: isCompact ? 11 : 12, weight: .semibold))
                    .frame(width: isCompact ? 24 : 28, height: isCompact ? 24 : 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!nav.canGoUp)
            .foregroundStyle(nav.canGoUp ? Color.accentColor : Color.secondary.opacity(0.5))
            .help("Go to parent folder")

            breadcrumb

            Button {
                showHidden.toggle()
            } label: {
                Image(systemName: showHidden ? "eye" : "eye.slash")
                    .font(.system(size: isCompact ? 10 : 11, weight: .semibold))
                    .foregroundStyle(showHidden ? Color.accentColor : .secondary)
                    .frame(width: isCompact ? 22 : 26, height: isCompact ? 22 : 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showHidden ? "Hide dotfiles" : "Show dotfiles")

            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: isCompact ? 10 : 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: isCompact ? 22 : 26, height: isCompact ? 22 : 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reload")
        }
        .padding(.horizontal, isCompact ? 6 : 8)
        .padding(.vertical, isCompact ? 3 : 4)
    }

    /// The trail of ancestors, tail-anchored: deep paths scroll so the folder
    /// you are IN stays visible, and every parent above it is one tap away.
    private var breadcrumb: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(nav.breadcrumb) { crumb in
                        if crumb.path != "/" {
                            Image(systemName: "chevron.right")
                                .font(.system(size: isCompact ? 7 : 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            go { $0.jump(to: crumb.path) }
                        } label: {
                            Text(crumb.label)
                                .font(.system(size: isCompact ? 11 : 12, design: .monospaced))
                                .foregroundStyle(crumb.path == nav.current ? .primary : .secondary)
                                .fontWeight(crumb.path == nav.current ? .semibold : .regular)
                                .lineLimit(1)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(crumb.path)
                    }
                }
                .padding(.horizontal, 2)
            }
            .onChange(of: nav.current) { _, path in
                guard let path else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(path, anchor: .trailing) }
            }
        }
    }

    // MARK: - One level

    @ViewBuilder private var levelBody: some View {
        if let err = store.error, store.entries.isEmpty {
            problemView(err)
        } else if store.loading, store.entries.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text(nav.current ?? "…")
                    .font(.system(size: isCompact ? 10 : 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if visibleEntries.isEmpty {
                    Text("Nothing to list here")
                        .font(.system(size: isCompact ? 10 : 11))
                        .foregroundStyle(.tertiary)
                }
                ForEach(visibleEntries, id: \.name) { entry in
                    row(entry)
                }
                if store.truncated { showMoreRow }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder private func row(_ entry: DirectoryEntry) -> some View {
        if entry.isDir {
            Button {
                go { $0.enter(entry.name) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: isCompact ? 11 : 12))
                        .foregroundStyle(Color.accentColor.opacity(0.8))
                    Text(entry.name)
                        .font(.system(size: isCompact ? 12 : 13))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: isCompact ? 9 : 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: isCompact ? 11 : 12))
                    .foregroundStyle(.secondary)
                Text(entry.name)
                    .font(.system(size: isCompact ? 12 : 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .opacity(0.45)
        }
    }

    /// Same per-directory truncation ladder as the tree browser: "Show more…"
    /// until the cap tops out, then an inert count.
    @ViewBuilder private var showMoreRow: some View {
        if store.canShowMore {
            Button {
                store.showMore()
            } label: {
                Text("Show more…")
                    .font(.system(size: isCompact ? 10 : 11))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        } else {
            Text("Too many items")
                .font(.system(size: isCompact ? 10 : 11))
                .foregroundStyle(.tertiary)
        }
    }

    private func problemView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: isCompact ? 11 : 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if nav.canConfirm {
                Button("Retry") { store.reload() }
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Confirm

    private var confirmBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Selected")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(nav.current ?? "—")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(nav.canConfirm ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Button(confirmTitle) {
                guard let path = nav.selectedPath else { return }
                onPick(path)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!nav.canConfirm)
        }
        .padding(.horizontal, isCompact ? 8 : 12)
        .padding(.vertical, 8)
    }

    // MARK: - Navigation + loading

    /// Every move goes through here so the listing follows the location in
    /// one step — no onChange round trip that could fire twice or not at all.
    private func go(_ move: (inout DirectoryPickerPath) -> Void) {
        var next = nav
        move(&next)
        guard next.current != nav.current, let path = next.current else { return }
        nav = next
        store.load(path)
    }

    /// Resolve the pane and start at its cwd — the same pre-flight guards the
    /// tree browser uses, so a pane we can't reach refuses honestly instead of
    /// listing the wrong disk.
    private func start() async {
        guard let ctx = contextProvider() else {
            nav.reset(nil)
            store.fail("No active pane")
            return
        }
        if let block = ctx.remoteBlock, let reason = await block() {
            nav.reset(nil)
            store.fail(reason)
            return
        }
        guard let cwd = await ctx.cwd(), cwd.hasPrefix("/") else {
            nav.reset(nil)
            store.fail("Working directory unknown")
            return
        }
        nav.reset(cwd)
        store.bind(context: ctx)
        if let path = nav.current { store.load(path) }
    }

    /// Dotfile filter + directories first: in a folder picker the folders are
    /// the actionable rows, so they lead.
    private var visibleEntries: [DirectoryEntry] {
        let entries = showHidden ? store.entries : store.entries.filter { !$0.name.hasPrefix(".") }
        return entries.filter(\.isDir) + entries.filter { !$0.isDir }
    }
}

// MARK: - One directory at a time

/// The picker's listing state: exactly one directory, replaced on every move.
///
/// Fetches go through the shared `DirectoryListCache`, so a directory the
/// tree browser or search already listed is free here (and vice
/// versa). Results are stamped with the path they were requested for — a slow
/// listing that lands after you have already moved on is dropped rather than
/// shown under the wrong breadcrumb.
@MainActor
final class DirectoryLevelStore: ObservableObject {
    @Published private(set) var path: String?
    @Published private(set) var entries: [DirectoryEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var truncated = false

    private var maxChildren = 200
    private var context: PathPreviewContext?
    private var task: Task<Void, Never>?
    private let cache: DirectoryListCache
    private static let ladder = [200, 600, 1500, 4000]

    init(cache: DirectoryListCache = .shared) {
        self.cache = cache
    }

    var canShowMore: Bool { maxChildren < Self.ladder.last! }

    func bind(context: PathPreviewContext) {
        self.context = context
    }

    /// Pre-flight failure (no pane / unreachable / unknown cwd): one error
    /// surface, nothing listed.
    func fail(_ message: String) {
        task?.cancel()
        task = nil
        context = nil
        path = nil
        entries = []
        truncated = false
        loading = false
        error = message
    }

    /// List `path`. Any in-flight listing for a previous directory is
    /// cancelled — moving is the common case, and its result is stale.
    func load(_ path: String, refresh: Bool = false) {
        guard let ctx = context else { return }
        task?.cancel()
        if path != self.path {
            entries = []
            truncated = false
            maxChildren = Self.ladder[0]
        }
        self.path = path
        loading = true
        error = nil
        let cap = maxChildren
        task = Task { [weak self] in
            var result: DirectoryListResult?
            var err: String?
            do {
                result = try await cache.listing(source: ctx.source, path: path,
                                                 request: DirectoryListRequest(maxChildren: cap),
                                                 refresh: refresh)
            } catch {
                err = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self?.apply(result, error: err, for: path)
        }
    }

    func reload() {
        guard let path else { return }
        load(path, refresh: true)
    }

    /// Re-fetch this level with the next cap (the cache keys on the cap, so it
    /// really re-fetches).
    func showMore() {
        guard let path, let next = Self.ladder.first(where: { $0 > maxChildren }) else { return }
        maxChildren = next
        load(path, refresh: false)
    }

    private func apply(_ result: DirectoryListResult?, error: String?, for path: String) {
        guard path == self.path else { return }
        loading = false
        self.error = error
        if let result {
            entries = result.entries
            truncated = result.truncated
        }
    }
}
