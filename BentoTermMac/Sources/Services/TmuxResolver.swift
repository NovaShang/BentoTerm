import Foundation
import BentoUISharedKit

/// TmuxResolver picks which tmux binary the Mac app (and any other Swift
/// callers) should spawn: prefer the user's own tmux when it's recent enough,
/// else fall back to a bundled binary we ship inside the .app.
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

    // MARK: - Facts for the UI

    /// The resolution, flattened for the tmux setup panel.
    ///
    /// The extra thing it works out beyond `resolve()`: whether a tmux server is
    /// ALREADY RUNNING from a system tmux we rejected. That combination is the
    /// one silent way this app disappoints a tmux user — different tmux versions
    /// are different servers, so their `tmux ls` sessions simply won't be there,
    /// with nothing on screen to explain why. Version alone isn't enough to
    /// warn on: a user with an old tmux they never run has no problem to fix.
    static func facts() -> TmuxFacts? {
        guard let resolution = cached else { return nil }
        let source: TmuxFacts.Source
        switch resolution.kind {
        case .system:   source = .system
        case .bundled:  source = .bundled
        case .override: source = .override
        }
        var conflicting: String?
        if resolution.kind == .bundled,
           let systemPath = defaultSystemPaths().first(where: { probe($0) != nil }),
           let systemVersion = probe(systemPath),
           systemVersion != resolution.version,
           serverIsRunning(tmuxAt: systemPath) {
            conflicting = systemVersion.description
        }
        return TmuxFacts(source: source,
                         version: resolution.version.description,
                         path: resolution.url.path,
                         conflictingSystemVersion: conflicting)
    }

    /// Does THIS tmux binary have a server with sessions? `list-sessions` exits
    /// non-zero with "no server running" when it doesn't, which is exactly the
    /// question — and asking the binary means the answer accounts for the
    /// version-keyed socket rather than guessing at socket paths.
    private static func serverIsRunning(tmuxAt path: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["list-sessions"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return false
        }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
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

    /// Probe order for bundled tmux. The Mac app keeps its helper binaries in
    /// Contents/MacOS/helpers/, so that is where the bundled tmux lands; the
    /// bare Contents/MacOS is only a fallback for older layouts.
    private static func defaultBundledDirs() -> [String] {
        let macOS = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS")
        return [macOS.appendingPathComponent("helpers").path, macOS.path]
    }
}
