import Foundation

/// One agent found on this machine.
public struct DetectedAgent: Identifiable, Equatable, Sendable {
    public let preset: AgentPreset
    /// The word that resolved (`claude`, `cursor-agent`).
    public let command: String
    /// Where it resolved to, abbreviated with `~` for display.
    public let path: String

    public var id: String { command }

    public init(preset: AgentPreset, command: String, path: String) {
        self.preset = preset
        self.command = command
        self.path = path
    }
}

/// Which known agents are installed on this machine.
///
/// Named for what it answers, not for what it does — `AgentDetector` in
/// `AgentStatusRules` already owns the other kind of detection (which STATE a
/// running pane is in).
///
/// **The old detector asked the wrong shell.** It ran `zsh -lc`, which is a
/// LOGIN but NON-INTERACTIVE shell, and zsh only sources `~/.zshrc` for
/// interactive ones. A pane, meanwhile, runs `$SHELL -l` on a pty — interactive
/// — so it does source `.zshrc`. Anything whose PATH entry lives there (which
/// includes `~/.local/bin`, where Claude Code's own `install.sh` puts itself
/// and which it adds to the rc file) was invisible to the detector and
/// perfectly visible to the pane. Reproduced with a HOME whose only PATH edit
/// is in `.zshrc`:
///
///     zsh -lc  'command -v x'  → not found
///     zsh -lic 'command -v x'  → ~/bin/x
///
/// So: **ask the shell a pane will actually use.** Detection means "will this
/// run in a pane", and only the pane's own shell semantics can answer that.
///
/// Two consequences, both deliberate:
///  * an interactive shell runs the user's rc files, which can be slow or
///    chatty — hence the timeout and the discarded stderr;
///  * a PATH probe is a heuristic no matter how it is spelled, so the result
///    only ever ranks and prefills. Nothing in the UI may gate on it, and no
///    screen may tell a user that something they installed isn't there.
public enum InstalledAgents {
    /// Directories checked directly when the shell probe finds nothing — no
    /// subprocess, no rc files, just the places agents actually install to.
    static let wellKnownDirectories: [String] = [
        "~/.local/bin",
        "~/.claude/local",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.bun/bin",
        "/opt/homebrew/lib/node_modules/.bin",
        "/usr/local/lib/node_modules/.bin",
    ]

    /// How long the interactive shell gets before we fall back. A user's zshrc
    /// can do surprising things; the panel must still render.
    static let probeTimeout: Duration = .seconds(2)

    public static func scan() async -> [DetectedAgent] {
        let wanted: [(preset: AgentPreset, word: String)] = AgentPreset.allCases.compactMap { preset in
            guard let command = preset.command, !command.isEmpty else { return nil }
            let word = command.split(separator: " ").first.map(String.init) ?? command
            return (preset, word)
        }

        var resolved: [String: String] = await shellResolve(wanted.map(\.word))
        for (_, word) in wanted where resolved[word] == nil {
            if let path = wellKnownPath(for: word) { resolved[word] = path }
        }

        return wanted.compactMap { entry in
            guard let path = resolved[entry.word] else { return nil }
            return DetectedAgent(preset: entry.preset, command: entry.word,
                                 path: (path as NSString).abbreviatingWithTildeInPath)
        }
    }

    // MARK: - Probes

    private static func wellKnownPath(for word: String) -> String? {
        for dir in wellKnownDirectories {
            let expanded = (dir as NSString).expandingTildeInPath
            let candidate = (expanded as NSString).appendingPathComponent(word)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// One shell, every word — spawning an interactive shell per agent would
    /// run the user's rc files a dozen times over.
    private static func shellResolve(_ words: [String]) async -> [String: String] {
        #if os(macOS)
        guard !words.isEmpty else { return [:] }
        let list = words.map { "'\($0)'" }.joined(separator: " ")
        let script = "for c in \(list); do printf '%s\\t' \"$c\"; command -v \"$c\" 2>/dev/null || echo; done"

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Test hook (kept from the previous detector): BENTO_DETECT_PATH replaces
        // the shell's PATH so a bare machine can be simulated. Non-interactive
        // there on purpose — the point is a deterministic PATH, not the user's.
        if let override = ProcessInfo.processInfo.environment["BENTO_DETECT_PATH"] {
            process.arguments = ["-c", "PATH=\(override); \(script)"]
        } else {
            process.arguments = ["-lic", script]
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // An interactive shell wants a stdin; give it an empty one so it can't
        // block waiting on the terminal we don't have.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return [:]
        }

        let reader = Task.detached { () -> Data in
            (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        let watchdog = Task {
            try? await Task.sleep(for: probeTimeout)
            if process.isRunning { process.terminate() }
        }
        let data = await reader.value
        watchdog.cancel()
        process.waitUntilExit()

        var result: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let word = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, !path.isEmpty else { continue }
            result[word] = path
        }
        return result
        #else
        // iOS has no local shell to ask — agents live on the host you connect
        // to, and enumerating them there is a session-level question.
        return [:]
        #endif
    }
}
