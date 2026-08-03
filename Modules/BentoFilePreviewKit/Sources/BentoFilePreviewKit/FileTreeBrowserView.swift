import SwiftUI

/// The focused pane's working directory as a lazily-browsable tree. Rooted
/// at the pane's cwd, one readdir per expanded level (via
/// `LazyDirectoryTreeStore` + `DirectoryListCache`) — so depth is unlimited
/// and a directory costs nothing until you expand it. Tapping a file calls
/// `onOpenFile`.
///
/// Transport-agnostic: everything it needs arrives through
/// `PathPreviewContext`, so the local (macOS) and SFTP-over-SSH (iOS)
/// sources both work unchanged. Shared by the iOS Files sheet and the macOS
/// preview dock's first tab (`isCompact` absorbs the dock's smaller chrome).
public struct FileTreeBrowserView: View {
    /// Resolves the current pane's file context at load time — re-resolved on
    /// every load so switching panes/workspaces re-roots the tree.
    private let contextProvider: () -> PathPreviewContext?
    /// Bump to force a reload (e.g. the focused pane changed).
    private let reloadKey: AnyHashable
    private let onOpenFile: (String, PathPreviewContext) -> Void
    /// Dock variant: smaller rows/buttons, .help tooltips.
    private let isCompact: Bool

    @StateObject private var store = LazyDirectoryTreeStore()
    /// Dotfiles hidden by default (the eye toggles them) — a per-level render
    /// filter, never a refetch.
    @State private var showHidden = false
    /// The context the current tree is rooted at — re-captured on every load.
    @State private var loadedContext: PathPreviewContext?

    public init(reloadKey: AnyHashable = 0,
                contextProvider: @escaping () -> PathPreviewContext?,
                onOpenFile: @escaping (String, PathPreviewContext) -> Void,
                isCompact: Bool = false) {
        self.reloadKey = reloadKey
        self.contextProvider = contextProvider
        self.onOpenFile = onOpenFile
        self.isCompact = isCompact
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            treeBody
        }
        .task(id: reloadKey) { await load() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: isCompact ? 10 : 11))
                .foregroundStyle(.secondary)
            Text(store.root?.isEmpty == false ? Self.abbreviated(store.root!) : "…")
                .font(.system(size: isCompact ? 10 : 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if store.rootLoading { ProgressView().controlSize(.small) }
            Button {
                showHidden.toggle()
            } label: {
                Image(systemName: showHidden ? "eye" : "eye.slash")
                    .font(.system(size: isCompact ? 9 : 10, weight: .semibold))
                    .foregroundStyle(showHidden ? Color.accentColor : .secondary)
                    .frame(width: isCompact ? 20 : 24, height: isCompact ? 20 : 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showHidden ? "Hide dotfiles" : "Show dotfiles")
            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: isCompact ? 9 : 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: isCompact ? 20 : 24, height: isCompact ? 20 : 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reload")
        }
        .padding(.horizontal, isCompact ? 8 : 10)
        .padding(.vertical, isCompact ? 4 : 5)
    }

    @ViewBuilder private var treeBody: some View {
        let rootState = store.state(of: "")
        if rootState.entries == nil {
            if let err = rootState.error {
                problemView(err)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(store.root ?? "…")
                        .font(.system(size: isCompact ? 10 : 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List {
                if LazyTreeRow.visibleChildren(of: "", store: store, showHidden: showHidden).isEmpty {
                    Text("Nothing to list here")
                        .font(.system(size: isCompact ? 10 : 11))
                        .foregroundStyle(.tertiary)
                }
                ForEach(LazyTreeRow.visibleChildren(of: "", store: store, showHidden: showHidden),
                        id: \.name) { entry in
                    LazyTreeRow(entry: entry, relPath: "", store: store,
                                showHidden: showHidden, isCompact: isCompact,
                                loadedContext: loadedContext, onOpenFile: onOpenFile)
                }
                if rootState.truncated {
                    LazyTreeRow.showMoreRow("", store: store, isCompact: isCompact)
                }
            }
            .listStyle(.inset)
        }
    }

    private func problemView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
            Text(message)
                .font(.system(size: isCompact ? 11 : 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard let ctx = contextProvider() else {
            store.resetFailed("No active pane")
            loadedContext = nil
            return
        }
        // A pane whose files live elsewhere (a remote shell on macOS): our
        // source can't reach them — refuse honestly rather than list the
        // wrong disk.
        if let block = ctx.remoteBlock, let reason = await block() {
            store.resetFailed(reason)
            loadedContext = nil
            return
        }
        guard let cwd = await ctx.cwd(), cwd.hasPrefix("/") else {
            store.resetFailed("Working directory unknown")
            loadedContext = nil
            return
        }
        loadedContext = ctx
        store.reset(context: ctx, root: cwd)
    }

    /// Abbreviate the LOCAL home to ~ on macOS; on iOS the path is the remote
    /// Mac's, so head-truncation (in the Text) is the only sane shortening.
    private static func abbreviated(_ path: String) -> String {
        #if os(macOS)
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        #endif
        return path
    }
}

// MARK: - One row (recursion lives in a NAMED type so `some View` inference
// terminates — a function returning its own opaque type can't recurse).

private struct LazyTreeRow: View {
    let entry: DirectoryEntry
    let relPath: String
    @ObservedObject var store: LazyDirectoryTreeStore
    let showHidden: Bool
    let isCompact: Bool
    let loadedContext: PathPreviewContext?
    let onOpenFile: (String, PathPreviewContext) -> Void

    var body: some View {
        let childRel = relPath.isEmpty ? entry.name : relPath + "/" + entry.name
        if entry.isDir {
            DisclosureGroup(isExpanded: expandedBinding(childRel)) {
                content(childRel)
            } label: {
                label
            }
        } else {
            label
                .contentShape(Rectangle())
                .onTapGesture {
                    guard let ctx = loadedContext, let root = store.root else { return }
                    onOpenFile(root + "/" + childRel, ctx)
                }
        }
    }

    @ViewBuilder private func content(_ childRel: String) -> some View {
        let st = store.state(of: childRel)
        if st.loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading…")
                    .font(.system(size: isCompact ? 10 : 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 8)
        } else if let err = st.error {
            HStack(spacing: 8) {
                Text(err)
                    .font(.system(size: isCompact ? 10 : 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Retry") { store.retry(childRel) }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            }
            .padding(.leading, 8)
        } else if Self.visibleChildren(of: childRel, store: store, showHidden: showHidden).isEmpty {
            Text("Empty")
                .font(.system(size: isCompact ? 10 : 11))
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
        } else {
            ForEach(Self.visibleChildren(of: childRel, store: store, showHidden: showHidden),
                    id: \.name) { kid in
                LazyTreeRow(entry: kid, relPath: childRel, store: store,
                            showHidden: showHidden, isCompact: isCompact,
                            loadedContext: loadedContext, onOpenFile: onOpenFile)
            }
            if st.truncated {
                Self.showMoreRow(childRel, store: store, isCompact: isCompact)
            }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.isDir ? "folder" : "doc.text")
                .font(.system(size: isCompact ? 11 : 12))
                .foregroundStyle(entry.isDir ? Color.accentColor.opacity(0.8) : .secondary)
            Text(entry.name)
                .font(.system(size: isCompact ? 12 : 13))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func expandedBinding(_ rel: String) -> Binding<Bool> {
        Binding(
            get: { store.state(of: rel).expanded },
            set: { _ in store.toggle(rel) })
    }

    /// Dotfile filter at render time — the store keeps raw names so toggling
    /// the eye never refetches.
    static func visibleChildren(of rel: String, store: LazyDirectoryTreeStore,
                                showHidden: Bool) -> [DirectoryEntry] {
        guard let entries = store.state(of: rel).entries else { return [] }
        if showHidden { return entries }
        return entries.filter { !$0.name.hasPrefix(".") }
    }

    /// The per-directory truncation affordance: "Show more…" until the ladder
    /// tops out, then an inert "Too many items".
    @ViewBuilder
    static func showMoreRow(_ rel: String, store: LazyDirectoryTreeStore, isCompact: Bool) -> some View {
        let st = store.state(of: rel)
        if st.maxChildren < 4000 {
            Button {
                store.showMore(rel)
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
}
