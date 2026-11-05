import BentoFilePreviewKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI
import BentoSessionKit
import BentoFoundationKit

// MARK: - Preview content

/// A file preview, as it appears in the side dock. There is no second place a
/// preview can live: the floating "Open in Window" panel is gone — it was a
/// whole parallel surface (its own controller, size memory, Esc handling) for
/// a window that duplicated the dock tab you already had.
struct FilePreviewContentView: View {
    let data: FilePreviewData
    /// Where a file picked from a breadcrumb dropdown goes. Nil leaves the
    /// crumbs as plain labels.
    var onOpenPath: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    /// The Mac dock's sizes for the shared body: the dock is a narrow column
    /// of 11–12pt text.
    private static let bodyStyle = FilePreviewContentBody.Style(
        noteFontSize: 12, truncationPadding: 4,
        truncationFill: AnyShapeStyle(.quaternary.opacity(0.5)))

    private var content: some View {
        FilePreviewContentBody(data: data, style: Self.bodyStyle)
    }

    /// One bar carrying both jobs a preview header has: where this file IS
    /// (clickable crumbs — the dock is a narrow column and hunting a sibling
    /// through the tree tab meant losing the file you were reading), and what
    /// you can do with it. The actions used to sit in a footer, which put the
    /// two halves of "this file" at opposite ends of the panel.
    private var header: some View {
        HStack(spacing: 6) {
            FilePreviewBreadcrumbs(data: data, onOpenPath: onOpenPath)
            Spacer(minLength: 4)
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(height: 30)
    }

    private var actions: some View {
        HStack(spacing: 1) {
            actionButton("doc.on.doc", "Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(data.resolvedPath, forType: .string)
            }
            if data.isLocal {
                actionButton("folder", "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: data.resolvedPath)])
                }
                actionButton("arrow.up.forward.app", "Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: data.resolvedPath))
                }
            }
            // Deliberately not gated on what the panel above managed to
            // render: the files we can't preview are the ones worth exporting.
            // Icon-only like its neighbours; it keeps its own progress and
            // picker anchor, so it stays a real view rather than a menu item.
            if let share = FileShareButton(data: data) {
                share
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    // Padding, not a fixed frame: mid-download this button
                    // grows a progress bar and a Cancel, which a 22pt box
                    // would clip.
                    .padding(.horizontal, 5)
                    .help("Share")
            }
        }
        .controlSize(.small)
    }

    private func actionButton(_ icon: String, _ help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Breadcrumbs

/// The file's path as clickable crumbs, VS Code style: every crumb drops down
/// its own directory, so switching to a sibling — the overwhelmingly common
/// move while reading code — is one click from inside the file you're in.
///
/// The strip scrolls horizontally and stays pinned to its trailing end: the
/// dock is a narrow column, and of `/Users/…/Sources/Views/Thing.swift` the
/// part worth the width is the right-hand end.
private struct FilePreviewBreadcrumbs: View {
    let data: FilePreviewData
    let onOpenPath: ((String) -> Void)?

    @State private var openCrumb: Int?
    /// The pane's directory — the same root the Files tab lists. Crumbs start
    /// there, not at `/`: what you're navigating is a project, and eight
    /// segments of machine-specific prefix in front of it are noise.
    @State private var root: String?

    private struct Crumb: Hashable {
        let name: String
        let path: String
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    if !data.isLocal {
                        Text(data.hostLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(0.06)))
                            .help("This file lives on \(data.hostLabel)")
                        separator
                    }
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 { separator }
                        crumbButton(index, crumb)
                            .id(index)
                    }
                }
                .padding(.trailing, 2)
            }
            .onAppear { scrollToFile(proxy) }
            .onChange(of: data.resolvedPath) { _, _ in scrollToFile(proxy) }
            .task(id: data.resolvedPath) { root = await data.context?.cwd() }
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.compact.right")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func crumbButton(_ index: Int, _ crumb: Crumb) -> some View {
        let last = index == crumbs.count - 1
        Button {
            guard data.context != nil, onOpenPath != nil else { return }
            openCrumb = index
        } label: {
            Text(crumb.name)
                .font(.system(size: 11, weight: last ? .medium : .regular))
                .foregroundStyle(last ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { openCrumb == index },
                                      set: { if !$0, openCrumb == index { openCrumb = nil } }),
                 arrowEdge: .bottom) {
            if let context = data.context, let onOpenPath {
                DirectorySwitchPopover(source: context.source,
                                       start: listingDirectory(index),
                                       currentPath: data.resolvedPath,
                                       onOpen: onOpenPath)
            }
        }
        .help(crumb.path)
    }

    /// The path as crumbs, each carrying its own absolute path.
    ///
    /// Rooted at the pane's directory when the file is inside it — that root is
    /// what the Files tab lists, and it's the only prefix a reader thinks in.
    /// Everything above it collapses into a single `…` crumb, which still drops
    /// down its parent, so going up stays one click without costing width.
    /// A file outside the pane's directory (or a pane whose cwd we never
    /// learned) falls back to the absolute path from `/`.
    private var crumbs: [Crumb] {
        let path = data.resolvedPath
        var out: [Crumb] = []
        var current = "/"
        var rest = path

        if let root, root != "/", root.hasPrefix("/"),
           path == root || path.hasPrefix(root + "/") {
            out.append(Crumb(name: "…", path: (root as NSString).deletingLastPathComponent))
            out.append(Crumb(name: (root as NSString).lastPathComponent, path: root))
            current = root
            rest = String(path.dropFirst(root.count))
        } else {
            out.append(Crumb(name: "/", path: "/"))
        }

        for part in rest.split(separator: "/") {
            current = (current as NSString).appendingPathComponent(String(part))
            out.append(Crumb(name: String(part), path: current))
        }
        return out
    }

    /// Which directory a crumb drops down. Every crumb but the last IS a
    /// directory; the last one is the file itself, and what you want there is
    /// its siblings — the reason to click it at all.
    private func listingDirectory(_ index: Int) -> String {
        let crumb = crumbs[index]
        if index == crumbs.count - 1, !data.stat.isDirectory {
            return (crumb.path as NSString).deletingLastPathComponent
        }
        return crumb.path
    }

    private func scrollToFile(_ proxy: ScrollViewProxy) {
        guard crumbs.count > 1 else { return }
        proxy.scrollTo(crumbs.count - 1, anchor: .trailing)
    }
}

/// One directory's contents, as a dropdown. Folders walk deeper in place (the
/// crumb you opened is the way back up), files open and dismiss.
private struct DirectorySwitchPopover: View {
    let source: FilePreviewSource
    let start: String
    let currentPath: String
    let onOpen: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var directory: String
    @State private var entries: [DirectoryEntry] = []
    @State private var truncated = false
    @State private var loading = true
    @State private var error: String?
    @State private var filter = ""

    /// Listed per directory. Bigger than the browse default because this list
    /// is the only thing on screen and a source directory of 300 files is
    /// ordinary; the truncation note below still tells the truth past it.
    private static let maxEntries = 500

    init(source: FilePreviewSource, start: String, currentPath: String,
         onOpen: @escaping (String) -> Void) {
        self.source = source
        self.start = start
        self.currentPath = currentPath
        self.onOpen = onOpen
        _directory = State(initialValue: start)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if directory != start {
                    Button {
                        filter = ""
                        directory = (directory as NSString).deletingLastPathComponent
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Back to \((directory as NSString).deletingLastPathComponent)")
                }
                Text(directory)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 7)

            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            Divider()
            list
        }
        .frame(width: 300, height: 340)
        .task(id: directory) { await load() }
    }

    @ViewBuilder private var list: some View {
        if loading {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible, id: \.name) { entry in
                        let full = (directory as NSString).appendingPathComponent(entry.name)
                        DirectoryRow(entry: entry, isCurrent: full == currentPath) {
                            if entry.isDir {
                                filter = ""
                                directory = full
                            } else {
                                onOpen(full)
                                dismiss()
                            }
                        }
                    }
                    if visible.isEmpty {
                        Text(entries.isEmpty ? "Empty folder" : "No matches")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                    if truncated {
                        Text("First \(Self.maxEntries) entries")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var visible: [DirectoryEntry] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.name.lowercased().contains(needle) }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            let result = try await DirectoryListCache.shared.listing(
                source: source, path: directory,
                request: DirectoryListRequest(maxChildren: Self.maxEntries))
            // Folders first, then names the way Finder orders them — the list
            // is read by eye, not by byte.
            entries = result.entries.sorted { a, b in
                if a.isDir != b.isDir { return a.isDir }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            truncated = result.truncated
        } catch {
            self.error = error.localizedDescription
            entries = []
            truncated = false
        }
        loading = false
    }
}

private struct DirectoryRow: View {
    let entry: DirectoryEntry
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: entry.isDir ? "folder" : "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(entry.isDir ? Color.accentColor : .secondary)
                    .frame(width: 13)
                Text(entry.name)
                    .font(.system(size: 11))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.primary.opacity(0.07) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

#endif
