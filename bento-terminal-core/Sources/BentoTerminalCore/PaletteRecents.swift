import Foundation

/// A launch the recents list remembers — the palette's row AND the
/// launcher-wide value, and only one of those two is allowed to own the
/// definition. This file owns it so the shared engine (TerminalViewModel
/// records launches) and the macOS palette can share the same store.
///
/// `host` is nil for everything today and means "this Mac". It exists NOW,
/// unused, purely so that remembering a launch on a remote machine later is a
/// new value rather than a store migration: the synthesized `Codable` encodes a
/// nil optional by omitting the key and decodes a missing key as nil, so JSON
/// written before this field existed still decodes, and JSON written today is
/// still readable by a build that predates it.
public struct LaunchRecord: Codable, Equatable, Sendable {
    public let dir: String
    /// "" = plain shell.
    public let command: String
    /// nil = local. Reserved for remote entries; nothing writes it yet.
    public let host: String?

    public init(dir: String, command: String, host: String? = nil) {
        self.dir = dir
        self.command = command
        self.host = host
    }
}

// MARK: - The noise rule

/// Which launches are worth remembering.
///
/// Every creation path now reports in (that's the point — the list was
/// permanently empty while only the palette's own rows recorded). But most
/// creations are the boring default: a plain login shell in `$HOME`, which is
/// what "new window" already does with no help from a recents list. Twenty of
/// those would push out the one row the user actually wanted.
///
/// So: **remember a launch when it says something the default doesn't** —
/// either a real program was requested, or the directory isn't home. A plain
/// shell in home is the only combination that's pure noise, and it's also by
/// far the most common, which is exactly why it's the one we drop.
///
/// A launch with no known directory is dropped too: the row's whole job is to
/// reopen *somewhere*, and it can't name a session without a folder to name it
/// after.
public enum RecentLaunchPolicy {
    /// Trim, expand `~`, and drop a trailing slash so `/a/b` and `/a/b/` are
    /// one entry rather than two.
    public static func normalizedDir(_ raw: String?) -> String? {
        guard var dir = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty
        else { return nil }
        dir = (dir as NSString).expandingTildeInPath
        while dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
        return dir.isEmpty ? nil : dir
    }

    public static func normalizedCommand(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// nil = don't remember this one.
    public static func record(dir: String?, command: String?, host: String? = nil) -> LaunchRecord? {
        guard let dir = normalizedDir(dir) else { return nil }
        let command = normalizedCommand(command)
        let home = NSHomeDirectory()
        guard !command.isEmpty || dir != home else { return nil }
        return LaunchRecord(dir: dir, command: command, host: host)
    }
}

/// MRU store for the ⌘P palette: files you've previewed and (directory +
/// command) launches you've spun up. UserDefaults JSON — small, per-user,
/// survives relaunch. Lives in the core so the shared engine can record
/// launches from every creation path; the macOS palette renders it.
public final class PaletteRecents {
    public static let shared = PaletteRecents()

    public struct FileEntry: Codable, Equatable {
        public let path: String
        public let host: String
    }
    /// Backed by `LaunchRecord` (see its doc comment — it's the store's row
    /// AND the launcher-wide value). This name stays for the call sites that
    /// predate it.
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
