import Foundation

/// TmuxResolver picks which tmux binary the menubar (and any other Swift
/// callers) should spawn. Policy mirrors desktop/internal/tmuxresolver:
/// prefer the user's own tmux when it's recent enough, else fall back to a
/// bundled binary we ship inside the .app.
///
/// We deliberately re-implement the logic in Swift rather than shelling out
/// to `bento doctor` because the menubar wants this resolution at startup
/// to power the agent wizard — before the daemon is even guaranteed to be
/// running.
enum TmuxResolver {
    /// Minimum tmux version we accept as "system". Anything older falls
    /// back to bundled. 3.2 is where control-mode notifications became
    /// reliable enough for our use.
    static let minVersion = Version(major: 3, minor: 2, suffix: "")

    /// A fully-described resolution decision. Kind/reason are surfaced in
    /// the UI's diagnostics panel so users can see why a particular tmux
    /// got picked.
    struct Resolution {
        let url: URL
        let version: Version
        let kind: Kind
        let reason: String
    }

    enum Kind: String {
        case system
        case bundled
        case override   // BENTO_TMUX env var
    }

    struct Version: Comparable, CustomStringConvertible {
        let major: Int
        let minor: Int
        let suffix: String

        static func < (a: Version, b: Version) -> Bool {
            if a.major != b.major { return a.major < b.major }
            if a.minor != b.minor { return a.minor < b.minor }
            return a.suffix < b.suffix
        }

        var description: String { "\(major).\(minor)\(suffix)" }

        /// Parse `tmux -V` output ("tmux 3.5a\n" → 3.5a). Returns nil on
        /// any parse failure so callers treat unknown versions as too old.
        static func parse(_ raw: String) -> Version? {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let space = s.lastIndex(of: " ") {
                s = String(s[s.index(after: space)...])
            }
            // Strip non-digit prefix ("next-3.6" → "3.6").
            while let c = s.first, !c.isNumber { s.removeFirst() }
            guard let dot = s.firstIndex(of: ".") else { return nil }
            let majorStr = String(s[..<dot])
            let rest = s[s.index(after: dot)...]
            var end = rest.startIndex
            while end < rest.endIndex, rest[end].isNumber {
                end = rest.index(after: end)
            }
            guard end > rest.startIndex,
                  let major = Int(majorStr),
                  let minor = Int(rest[..<end]) else { return nil }
            return Version(major: major, minor: minor, suffix: String(rest[end...]))
        }
    }

    /// Resolve and cache. Most callers should use `url()`; tests can
    /// call `resolve(...)` directly with custom search paths.
    private static let cached: Resolution? = resolve()

    /// Convenience: URL form for direct `Process.executableURL` use.
    /// nil only if neither system nor bundled tmux is available, in which
    /// case callers should show an install hint.
    static func url() -> URL? { cached?.url }

    /// Run resolution. Exposed for tests with custom search paths.
    static func resolve(
        env: [String: String] = ProcessInfo.processInfo.environment,
        systemPaths: [String]? = nil,
        bundledPaths: [String]? = nil
    ) -> Resolution? {
        // 1. Explicit override wins if executable.
        if let p = env["BENTO_TMUX"], let v = probe(p) {
            return Resolution(url: URL(fileURLWithPath: p), version: v,
                              kind: .override, reason: "BENTO_TMUX=\(p)")
        }

        let sysList = systemPaths ?? defaultSystemPaths()
        var sysPath: String?
        var sysVer: Version?
        for p in sysList {
            if let v = probe(p) { sysPath = p; sysVer = v; break }
        }

        if let sp = sysPath, let sv = sysVer, sv >= minVersion {
            return Resolution(url: URL(fileURLWithPath: sp), version: sv,
                              kind: .system, reason: "system tmux \(sv)")
        }

        for dir in (bundledPaths ?? defaultBundledDirs()) {
            let p = (dir as NSString).appendingPathComponent("tmux")
            if let v = probe(p) {
                let reason: String
                if let sp = sysPath, let sv = sysVer {
                    reason = "bundled tmux \(v) (system \(sp) is \(sv), older than \(minVersion))"
                } else {
                    reason = "bundled tmux \(v)"
                }
                return Resolution(url: URL(fileURLWithPath: p), version: v,
                                  kind: .bundled, reason: reason)
            }
        }
        return nil
    }

    // MARK: - private

    private static func probe(_ path: String) -> Version? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["-V"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return Version.parse(String(decoding: data, as: UTF8.self))
    }

    private static func defaultSystemPaths() -> [String] {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    }

    /// Probe order for bundled tmux. The Mac app puts helpers inside
    /// Contents/MacOS/helpers/ (avoiding the APFS case-insensitive clash
    /// between the Swift `Bento` executable and the Go `bento` CLI), so
    /// the bundled tmux lives there too.
    private static func defaultBundledDirs() -> [String] {
        var dirs: [String] = []
        let macOS = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS")
        dirs.append(macOS.appendingPathComponent("helpers").path)
        dirs.append(macOS.path)
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs.append(home.appendingPathComponent(".bento/bin").path)
        return dirs
    }
}
