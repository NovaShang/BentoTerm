import Foundation
import os
import BentoFilePreviewKit

/// The command palette (⌘P): one single-state box over the focused pane that
/// blends *file preview* (browse / fuzzy-find / open any file in the working
/// tree) with *actions* (split, close, switch window, launch a pane in a recent
/// dir+command). No VS Code–style navigate/command mode split — you just type,
/// and files + commands rank in the same list; directories drill in.
///
/// This file is the platform-neutral core: the item/section model, a
/// subsequence fuzzy scorer (the "command box" feel, distinct from
/// `PathSearchEngine`'s exact-suffix tap matcher), a recents store, and the
/// file-browsing provider. The floating panel + SwiftUI live in the macOS UI
/// file; iOS can reuse everything here later.
let paletteLog = Logger(subsystem: "com.novashang.bento", category: "CommandPalette")

// MARK: - Item model

/// What activating a row does. `drill` navigates the palette into a directory
/// (no dismiss); the others act and dismiss.
public enum PaletteAction {
    /// Run an action (split pane, switch window, create pane…) and close.
    case run(@MainActor () -> Void)
    /// Navigate the file browser into this absolute directory.
    case drill(dir: String)
    /// Resolve `path` against the pane and open the preview panel.
    case preview(path: String, line: Int?)
}

/// One row. `matchText` is what the fuzzy scorer sees (basename for files,
/// title+keywords for commands); `subtitle` is the dimmed secondary line.
public struct PaletteItem: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let systemImage: String
    public let matchText: String
    public let action: PaletteAction
    /// Filled by ranking; higher = better. 0 for empty-state (unfiltered) rows.
    public var score: Int = 0

    public init(id: String, title: String, subtitle: String? = nil,
                systemImage: String, matchText: String? = nil,
                action: PaletteAction) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.matchText = matchText ?? title
        self.action = action
    }
}

/// A titled group of rows (Files / Commands / New Pane / Recent…). Sections
/// render in the order the controller assembles them; each is internally
/// ranked and capped.
public struct PaletteSection: Identifiable {
    public let id: String
    public let title: String
    public var items: [PaletteItem]

    public init(id: String, title: String, items: [PaletteItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// A caller-supplied static section (Commands / New Pane / Recent Files). The
/// controller fuzzy-filters `items` as the user types (unless `emptyStateOnly`,
/// in which case it's a suggestion that hides the moment there's a query). The
/// live File section is computed separately by the controller.
public struct PaletteSectionSpec {
    public let id: String
    public let title: String
    public let items: [PaletteItem]
    /// Shown only when the query is empty (e.g. Recent Files — once you type,
    /// the live File section covers them, so keep them from doubling up).
    public let emptyStateOnly: Bool
    public let limit: Int

    public init(id: String, title: String, items: [PaletteItem],
                emptyStateOnly: Bool = false, limit: Int = 8) {
        self.id = id
        self.title = title
        self.items = items
        self.emptyStateOnly = emptyStateOnly
        self.limit = limit
    }

    /// Resolve to a display section for `query` (nil = drop the section).
    public func resolved(query: String) -> PaletteSection? {
        let typing = !query.trimmingCharacters(in: .whitespaces).isEmpty
        if typing && emptyStateOnly { return nil }
        let ranked = PaletteFuzzy.rank(query: query, items: items, limit: limit)
        guard !ranked.isEmpty else { return nil }
        return PaletteSection(id: id, title: title, items: ranked)
    }
}

// MARK: - Fuzzy scorer (pure, unit-tested)

/// Subsequence fuzzy matcher for the command box. Query chars must appear in
/// order in the target (case-insensitive, spaces in the query ignored so
/// "pane view" matches "PaneViewModel"). Score rewards word-boundary hits
/// (after a separator or a camelCase hump), consecutive runs, and shorter
/// targets — the fzf/Sublime feel, not exact-suffix like `PathSearchEngine`.
public enum PaletteFuzzy {
    /// nil = not a subsequence (no match). Higher score = better.
    public static func score(query: String, target: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let t = Array(target)
        let tl = Array(target.lowercased())
        guard t.count == tl.count else { return simpleScore(q: q, target: target) }

        var qi = 0
        var score = 0
        var lastMatch = -2
        for i in 0..<tl.count where qi < q.count && tl[i] == q[qi] {
            var bonus = 1
            let prevSep = i == 0 || tl[i - 1].isBoundarySeparator
            let camelHump = i > 0 && t[i].isUppercase && !t[i - 1].isUppercase
            if prevSep || camelHump { bonus += 9 }
            if lastMatch == i - 1 { bonus += 5 }              // consecutive run
            if i == 0 { bonus += 3 }                          // matches at very start
            score += bonus
            lastMatch = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Prefer shorter targets, and matches that started early.
        score -= t.count / 8
        return max(score, 1)
    }

    /// Fallback when char arrays disagree (rare non-1:1 lowercasing).
    private static func simpleScore(q: [Character], target: String) -> Int? {
        let tl = Array(target.lowercased())
        var qi = 0
        for ch in tl where qi < q.count && ch == q[qi] { qi += 1 }
        return qi == q.count ? max(10 - target.count / 8, 1) : nil
    }

    /// Rank + filter items by `matchText`. Empty query → items unchanged
    /// (empty-state order preserved). Ties break on shorter matchText then title.
    public static func rank(query: String, items: [PaletteItem], limit: Int) -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(items.prefix(limit)) }
        var scored: [PaletteItem] = []
        for var item in items {
            guard let s = score(query: trimmed, target: item.matchText) else { continue }
            item.score = s
            scored.append(item)
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.matchText.count != $1.matchText.count { return $0.matchText.count < $1.matchText.count }
            return $0.title < $1.title
        }
        return Array(scored.prefix(limit))
    }
}

private extension Character {
    var isBoundarySeparator: Bool {
        self == "/" || self == "_" || self == "-" || self == "." || self == " "
    }
}

// MARK: - Recents store

/// Persisted, capped recents backing the palette's empty state: files you've
/// previewed and (directory + command) launches you've spun up. UserDefaults
/// JSON — small, per-user, survives relaunch.
public final class PaletteRecents {
    public static let shared = PaletteRecents()

    public struct FileEntry: Codable, Equatable {
        public let path: String
        public let host: String
    }
    /// The launch entry's shape lives in `OpenTargets.swift` — it's the store's
    /// row AND the launcher-wide value, and only one of those two is allowed to
    /// own the definition. This name stays for the call sites that predate it.
    public typealias LaunchEntry = LaunchRecord

    private let filesKey = "palette_recent_files"
    private let launchesKey = "palette_recent_launches"
    private let cap = 20

    public private(set) var files: [FileEntry]
    public private(set) var launches: [LaunchEntry]

    private init() {
        let d = UserDefaults.standard
        files = (try? JSONDecoder().decode([FileEntry].self,
            from: d.data(forKey: filesKey) ?? Data())) ?? []
        launches = (try? JSONDecoder().decode([LaunchEntry].self,
            from: d.data(forKey: launchesKey) ?? Data())) ?? []
    }

    /// Most-recent-first, deduped on path.
    public func recordFile(path: String, host: String) {
        let entry = FileEntry(path: path, host: host)
        files.removeAll { $0.path == path }
        files.insert(entry, at: 0)
        if files.count > cap { files.removeLast(files.count - cap) }
        persist(files, key: filesKey)
    }

    /// Remember a launch IF it's worth remembering (see `RecentLaunchPolicy` —
    /// a plain shell in `$HOME` is the default and carries no information).
    /// This is what the creation paths call; `recordLaunch` below is the
    /// unconditional store.
    ///
    /// Recording lives on the paths that CREATE something. It used to happen
    /// only when the palette replayed a row it already had, which meant the
    /// list could never gain a first entry and was empty for everyone, always.
    public func recordLaunchIfUseful(dir: String?, command: String?, host: String? = nil) {
        guard let record = RecentLaunchPolicy.record(dir: dir, command: command, host: host)
        else { return }
        recordLaunch(record)
    }

    /// Most-recent-first, deduped on (dir, command, host).
    public func recordLaunch(dir: String, command: String) {
        recordLaunch(LaunchEntry(dir: dir, command: command))
    }

    public func recordLaunch(_ entry: LaunchEntry) {
        launches.removeAll { $0 == entry }
        launches.insert(entry, at: 0)
        if launches.count > cap { launches.removeLast(launches.count - cap) }
        persist(launches, key: launchesKey)
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - File browsing provider

/// Turns (query, browse-root, pane context) into file/dir rows — the palette's
/// live File section. Reuses the tap-preview infrastructure: `FileTreeIndexCache`
/// for the bounded (depth 4 / 2000) subtree index and `PathSearchEngine`/fuzzy
/// for ranking. Directories drill; files preview.
///
/// - Empty query: immediate children of `root` (dirs first) — a browser.
/// - Typed query: flat fuzzy over the whole subtree under `root`.
/// - `/…` or `~/…`: a literal path, stat'd directly so you can escape the
///   bounded index and open any file.
public enum PaletteFileBrowser {
    public static func items(query: String, root: String,
                             context: PathPreviewContext, limit: Int = 40) async -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        // Literal absolute / ~ path → resolve directly (escape hatch).
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            if let (resolved, stat) = try? await context.source.stat(path: trimmed, cwd: root) {
                return [fileItem(relPath: (resolved as NSString).lastPathComponent,
                                 absPath: resolved, isDir: stat.isDirectory)]
            }
            return []
        }

        let entries: [FileTreeEntry]
        do {
            entries = try await FileTreeIndexCache.shared.entries(source: context.source, root: root)
        } catch {
            paletteLog.log("file index unavailable root=\(root, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }

        if trimmed.isEmpty {
            // Browse: immediate children only, directories first, alphabetical.
            let children = entries.filter { !$0.relPath.contains("/") }
                .sorted { a, b in
                    if a.isDir != b.isDir { return a.isDir && !b.isDir }
                    return a.relPath.localizedCaseInsensitiveCompare(b.relPath) == .orderedAscending
                }
            return children.prefix(limit).map {
                fileItem(relPath: $0.relPath, absPath: join(root, $0.relPath), isDir: $0.isDir)
            }
        }

        // Fuzzy over the whole subtree.
        var scored: [(Int, FileTreeEntry)] = []
        for e in entries {
            let base = (e.relPath as NSString).lastPathComponent
            // Prefer basename match; fall back to full relative path.
            let s = PaletteFuzzy.score(query: trimmed, target: base)
                ?? PaletteFuzzy.score(query: trimmed, target: e.relPath).map { $0 - 4 }
            if let s { scored.append((s, e)) }
        }
        scored.sort {
            if $0.0 != $1.0 { return $0.0 > $1.0 }
            return $0.1.relPath.count < $1.1.relPath.count
        }
        return scored.prefix(limit).map {
            fileItem(relPath: $0.1.relPath, absPath: join(root, $0.1.relPath), isDir: $0.1.isDir)
        }
    }

    private static func fileItem(relPath: String, absPath: String, isDir: Bool) -> PaletteItem {
        let name = (relPath as NSString).lastPathComponent
        let dirName = (relPath as NSString).deletingLastPathComponent
        return PaletteItem(
            id: "file:" + absPath,
            title: isDir ? name + "/" : name,
            subtitle: dirName.isEmpty ? nil : dirName,
            systemImage: isDir ? "folder" : "doc.text",
            matchText: name,
            action: isDir ? .drill(dir: absPath) : .preview(path: absPath, line: nil))
    }

    private static func join(_ root: String, _ rel: String) -> String {
        root.hasSuffix("/") ? root + rel : root + "/" + rel
    }
}
