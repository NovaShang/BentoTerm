import Foundation

/// A launch the recents list remembers. This file owns it so the shared engine
/// (TerminalViewModel records launches) and the Mac's menus can
/// share the same store.
///
/// `host` is nil for a launch on this Mac and the ssh alias for one on a
/// remote box (`TerminalViewModel.launchHost`). A row is only ever offered
/// back on the machine it was recorded on: its directory names nothing
/// anywhere else. The synthesized `Codable` encodes a nil optional by omitting
/// the key and decodes a missing key as nil, so JSON written before this field
/// existed still decodes, and local rows stay readable by a build that
/// predates it.
public struct LaunchRecord: Codable, Equatable, Sendable {
    public let dir: String
    /// "" = plain shell.
    public let command: String
    /// nil = local; otherwise the host the directory lives on.
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
/// Every creation path reports in (the list was once permanently empty
/// because only replaying a row recorded one). But most
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

    /// Whether a remembered command can actually be run again.
    ///
    /// Builds through 0.3.1 also stored tmux's `#{pane_current_command}` as a
    /// row's program. On Darwin that format is the kernel's accounting name
    /// (`p_comm` — the exec'd FILE's name, not argv[0], capped at 16 chars), so
    /// a versioned install like Claude Code's
    /// `~/.local/share/claude/versions/2.1.234` wrote rows whose "command" is
    /// `2.1.234`. Nothing on `PATH` is called that: replaying such a row opens a
    /// pane that exits the instant it appears. Nothing writes them any more (see
    /// `TerminalViewModel.recordActivePaneLaunch`), but users have them on disk
    /// today, so `LaunchRecents` repairs the store when it loads it — the
    /// directory is still good, so the row survives as a plain shell.
    ///
    /// Deliberately narrow: it rejects what CANNOT be a program name, not what
    /// merely looks unlikely. A version token is digits and dots, nothing else.
    public static func isReplayableCommand(_ command: String) -> Bool {
        let name = normalizedCommand(command)
        guard !name.isEmpty else { return true }  // "" is a plain shell, always fine
        let program = name.split(separator: " ").first.map(String.init) ?? name
        let versionLike = program.contains(".") && program.allSatisfy { $0.isNumber || $0 == "." }
        return !versionLike
    }

    /// The subset worth offering as "start this agent again", most-recent
    /// first. Pure so it can be tested without a store: `LaunchRecents` is a
    /// UserDefaults-backed singleton, and a test that reached for it would be
    /// reading whatever the developer ran this morning.
    ///
    /// A row with no command is a directory, not an agent — the plain
    /// split-and-inherit already covers going back to a folder. A row with a
    /// command we know can't run is dropped for the same reason the store
    /// repairs those on load.
    ///
    /// Only rows from `host` — the machine the split will run on. A window
    /// attached to a remote tmux used to get this Mac's rows, and splitting
    /// one sent a local path to the remote shell.
    public static func agentLaunches(from launches: [LaunchRecord],
                                     host: String? = nil,
                                     limit: Int = 6) -> [LaunchRecord] {
        launches
            .filter { $0.host == host && !$0.command.isEmpty && isReplayableCommand($0.command) }
            .prefix(max(0, limit))
            .map { $0 }
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

/// MRU store of (directory + command) launches — behind Recent Agents in the
/// New and pane menus and the Dock menu's recent launches.
/// UserDefaults JSON — small, per-user, survives relaunch. Lives in the core so
/// the shared engine can record launches from every creation path.
///
/// The UserDefaults key keeps its old `palette_` name so existing lists survive.
public final class LaunchRecents {
    public static let shared = LaunchRecents()

    /// Backed by `LaunchRecord`. This name stays for the call sites that
    /// predate it.
    public typealias LaunchEntry = LaunchRecord

    private let launchesKey = "palette_recent_launches"
    private let cap = 20

    public private(set) var launches: [LaunchEntry]

    private init() {
        let d = UserDefaults.standard
        // Recent previewed files, from when the ⌘P palette listed them.
        d.removeObject(forKey: "palette_recent_files")
        let stored = (try? JSONDecoder().decode([LaunchEntry].self,
            from: d.data(forKey: launchesKey) ?? Data())) ?? []
        launches = Self.repaired(stored)
        // Write the repair straight back, so a row an older build poisoned is
        // gone from the store rather than filtered on every read.
        if launches != stored { persist(launches, key: launchesKey) }
    }

    /// Load-time repair of rows earlier builds wrote (see
    /// `RecentLaunchPolicy.isReplayableCommand`): a row whose command can never
    /// be run keeps its directory and loses the command, the result is put back
    /// through the noise rule — a repaired row can become the plain-shell-in-
    /// `$HOME` default, which is exactly what that rule drops — and deduped, so
    /// the repair cannot leave two identical rows behind.
    static func repaired(_ stored: [LaunchEntry]) -> [LaunchEntry] {
        var out: [LaunchEntry] = []
        for entry in stored {
            let command = RecentLaunchPolicy.isReplayableCommand(entry.command) ? entry.command : ""
            guard let kept = RecentLaunchPolicy.record(
                dir: entry.dir, command: command, host: entry.host) else { continue }
            if !out.contains(kept) { out.append(kept) }
        }
        return out
    }

    /// Remember a launch IF it's worth remembering (see `RecentLaunchPolicy` —
    /// a plain shell in `$HOME` is the default and carries no information).
    /// This is what the creation paths call; `recordLaunch` below is the
    /// unconditional store.
    ///
    /// Recording lives on the paths that CREATE something. It used to happen
    /// only when a row was replayed, which meant the list could never gain a
    /// first entry and was empty for everyone, always.
    public func recordLaunchIfUseful(dir: String?, command: String?, host: String? = nil) {
        guard let record = RecentLaunchPolicy.record(dir: dir, command: command, host: host)
        else { return }
        recordLaunch(record)
    }

    /// Recent launches that name a program, most-recent-first, on `host`
    /// (nil = this Mac).
    ///
    /// This is the list behind "split one of these again". A row with no
    /// command is a directory you worked in, which the ordinary
    /// split-and-inherit already covers — offering it here would pad the menu
    /// with rows that do nothing the button above them doesn't.
    public func agentLaunches(host: String? = nil, limit: Int = 6) -> [LaunchEntry] {
        RecentLaunchPolicy.agentLaunches(from: launches, host: host, limit: limit)
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
