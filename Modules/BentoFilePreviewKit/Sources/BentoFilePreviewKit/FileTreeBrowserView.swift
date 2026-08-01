import SwiftUI

/// The focused pane's working directory as a browsable tree. Built from the
/// same bounded listing as tap-to-preview (`listTree`: depth ≤ 4 / 2000
/// entries), so it's "browse the project you're working in", not a general file
/// manager. Tapping a file calls `onOpenFile`.
///
/// Transport-agnostic: everything it needs arrives through `PathPreviewContext`,
/// so the local (macOS) and SFTP-over-SSH (iOS) sources both work unchanged.
///
/// Today this is the iOS browser. The macOS preview dock still walks its own
/// copy of this tree (`PreviewDock_macOS`, whose file-private `FileTreeNode`
/// shadows the one below); collapsing the two is a follow-up.
public struct FileTreeBrowserView: View {
    /// Resolves the current pane's file context at load time — re-resolved on
    /// every load so switching panes/workspaces re-roots the tree.
    private let contextProvider: () -> PathPreviewContext?
    /// Bump to force a reload (e.g. the focused pane changed).
    private let reloadKey: AnyHashable
    private let onOpenFile: (String, PathPreviewContext) -> Void

    public init(reloadKey: AnyHashable = 0,
                contextProvider: @escaping () -> PathPreviewContext?,
                onOpenFile: @escaping (String, PathPreviewContext) -> Void) {
        self.reloadKey = reloadKey
        self.contextProvider = contextProvider
        self.onOpenFile = onOpenFile
    }

    @State private var rootPath = ""
    @State private var entries: [FileTreeEntry] = []
    @State private var nodes: [FileTreeNode] = []
    @State private var loading = false
    @State private var problem: String?
    @State private var loadedContext: PathPreviewContext?
    @State private var reloadTick = 0
    @State private var truncated = false
    /// Dotfiles hidden by default (the eye toggles them) — a local rebuild, no
    /// refetch.
    @State private var showHidden = false

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            treeBody
            if truncated {
                Divider()
                Text("Bounded listing — first \(TreeListRequest().maxEntries) entries, depth ≤ \(TreeListRequest().maxDepth)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
        }
        .task(id: "\(reloadKey.hashValue)-\(reloadTick)") { await load() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(rootPath.isEmpty ? "…" : Self.abbreviated(rootPath))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if loading { ProgressView().controlSize(.small) }
            Button {
                showHidden.toggle()
                rebuild()
            } label: {
                Image(systemName: showHidden ? "eye" : "eye.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(showHidden ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { reloadTick += 1 } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder private var treeBody: some View {
        if let problem, nodes.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 26)).foregroundStyle(.quaternary)
                Text(problem).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(nodes, children: \.children) { node in
                row(node)
            }
            .listStyle(.inset)
        }
    }

    private func row(_ node: FileTreeNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.isDir ? "folder" : "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(node.isDir ? Color.accentColor.opacity(0.8) : .secondary)
            Text(node.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !node.isDir, let ctx = loadedContext, !rootPath.isEmpty else { return }
            onOpenFile(rootPath + "/" + node.id, ctx)
        }
    }

    private func load() async {
        guard let ctx = contextProvider() else {
            problem = "No active pane"; entries = []; nodes = []; truncated = false; return
        }
        loading = true
        defer { loading = false }
        // A pane whose files live elsewhere (a remote shell on macOS): our
        // source can't reach them — refuse honestly rather than list the wrong
        // disk.
        if let block = ctx.remoteBlock, let reason = await block() {
            problem = reason; entries = []; nodes = []; truncated = false; return
        }
        guard let cwd = await ctx.cwd(), cwd.hasPrefix("/") else {
            problem = "Working directory unknown"; entries = []; nodes = []; truncated = false; return
        }
        rootPath = cwd
        loadedContext = ctx
        do {
            let request = TreeListRequest()
            entries = try await ctx.source.listTree(root: cwd, request: request)
            // The walk stops at the entry budget — at the cap, assume there was
            // more (no silent truncation).
            truncated = entries.count >= request.maxEntries
            rebuild()
        } catch {
            problem = error.localizedDescription
            entries = []
            nodes = []
            truncated = false
        }
    }

    /// Entries → visible nodes (dotfile filter applied). Pure local.
    private func rebuild() {
        let visible = showHidden ? entries : entries.filter { e in
            !e.relPath.split(separator: "/").contains { $0.hasPrefix(".") }
        }
        nodes = FileTreeNode.build(visible)
        problem = nodes.isEmpty ? "Nothing to list here" : nil
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

// MARK: - Tree node

/// One node of the browsable tree, built from the flat bounded index
/// (`listTree`). `children == nil` marks a file (List's disclosure convention).
public struct FileTreeNode: Identifiable {
    public let id: String        // relPath from the tree root
    public let name: String
    public let isDir: Bool
    public var children: [FileTreeNode]?

    public static func build(_ entries: [FileTreeEntry]) -> [FileTreeNode] {
        final class Box { var isDir = false; var kids: [String: Box] = [:] }
        let root = Box()
        for e in entries {
            var cur = root
            let comps = e.relPath.split(separator: "/")
            for (i, c) in comps.enumerated() {
                let key = String(c)
                let next: Box
                if let existing = cur.kids[key] {
                    next = existing
                } else {
                    next = Box()
                    cur.kids[key] = next
                }
                if i < comps.count - 1 { next.isDir = true }
                else if e.isDir { next.isDir = true }
                cur = next
            }
        }
        func convert(_ box: Box, prefix: String) -> [FileTreeNode] {
            box.kids.map { name, b in
                let rel = prefix.isEmpty ? name : prefix + "/" + name
                return FileTreeNode(id: rel, name: name, isDir: b.isDir,
                                    children: b.isDir ? convert(b, prefix: rel) : nil)
            }
            .sorted {
                if $0.isDir != $1.isDir { return $0.isDir }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        return convert(root, prefix: "")
    }
}
