import Foundation
import BentoTerminalCore

/// TmuxCLI shells out to a tmux binary. The Mac app never proxies the
/// tmux protocol — the agent wizard builds a command sequence and `exec`s
/// it. Binary resolution (system vs bundled) lives in TmuxResolver.
/// Every function here runs the `tmux` binary on THIS machine, so every one of
/// them takes a `LocalTmuxSessionName` rather than a bare `String`. That is the
/// whole point of the type: a window attached to a session on an ssh host
/// cannot hand its session name to `kill` or `rename`, because the only way to
/// make one of these from a `TmuxSessionID` is a failable initializer that
/// returns nil for anything remote. The bug it forecloses is not cosmetic —
/// "Kill Session" in a remote window used to destroy the LOCAL session that
/// happened to share the name.
enum TmuxCLI {
    /// Backwards-compatible accessor. Returns the resolved tmux URL, or
    /// nil if neither system nor bundled tmux is available. Callers that
    /// already handle nil for "tmux missing" keep working unchanged.
    static func locate() -> URL? { TmuxResolver.url() }

    static func listSessions() async -> [TmuxSession] {
        // Use `|` as the field separator. Tab worked in standalone tools but
        // Swift's `split(separator:)` overloading on Substring made the
        // tab-keyed split unreliable in the app build — pipe is unambiguous.
        // (Session names can't contain `|` because tmux disallows it.)
        // Format: name | attached | activity_unix_seconds
        guard let rows = await captureRows(
            ["list-sessions", "-F", "#{session_name}|#{?session_attached,1,0}|#{session_activity}"]
        ) else { return [] }
        var sessions: [TmuxSession] = []
        for parts in rows {
            guard parts.count == 3 else { continue }
            let activity: Date
            if let ts = Double(parts[2]), ts > 0 {
                activity = Date(timeIntervalSince1970: ts)
            } else {
                activity = .distantPast
            }
            sessions.append(TmuxSession(
                name: LocalTmuxSessionName(onLocalServer: parts[0]),
                attached: parts[1] == "1",
                lastActivity: activity
            ))
        }
        // Most recently active first — matches user intuition that "what I'm
        // currently working on" sits at the top.
        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Build the shell command that creates the desired session. Running
    /// this in Terminal.app gives the user an attached view. When
    /// `useTmuxControlMode` is true the final attach uses `tmux -CC` so
    /// iTerm2 switches into its native multi-window integration.
    static func buildAgentScript(spec: AgentSpec, useTmuxControlMode: Bool = false) -> String {
        let tmux = locate()?.path ?? "tmux"
        let name = shellQuote(spec.sessionName)
        let dir = shellQuote(spec.workingDir)
        // Empty agent command → start the user's shell so the pane is
        // interactive but no agent runs in it.
        let cmd = spec.agentCommand.isEmpty ? "" : " " + shellQuote(spec.agentCommand)

        var lines: [String] = [
            "\(tmux) new-session -d -s \(name) -c \(dir)\(cmd)"
        ]
        for _ in 1..<spec.layout.paneCount {
            lines.append("\(tmux) split-window -t \(name) -c \(dir)\(cmd)")
        }
        if let layoutName = spec.layout.tmuxLayoutName {
            lines.append("\(tmux) select-layout -t \(name) \(layoutName)")
        }
        let ccFlag = useTmuxControlMode ? "-CC " : ""
        lines.append("\(tmux) \(ccFlag)attach -t \(name)")
        return lines.joined(separator: "\n")
    }

    /// Open a new window of the user's preferred terminal running
    /// `command`. Dispatch is by terminal kind so we can honor each
    /// app's preferred IPC (AppleScript is the lowest-common-denominator;
    /// iTerm2's variant uses its own scripting object model).
    static func openInTerminal(command: String, kind: TerminalAppKind) async throws {
        switch kind {
        case .bento:
            // The native terminal attaches to tmux sessions (see `attach` /
            // wizard `launch`), not arbitrary command strings — those paths
            // intercept `.bento` before reaching here. If a raw command does
            // arrive, fall back to Terminal.app so nothing is silently dropped.
            try await openInTerminal(command: command, kind: .terminal)

        case .terminal:
            try await runAppleScript("""
            tell application "Terminal"
                activate
                do script "\(escapeForAppleScript(command))"
            end tell
            """)

        case .iTerm:
            // iTerm2's AppleScript: create a new window with default
            // profile, then write the command to its current session.
            // When the command starts with `tmux -CC` iTerm2 transparently
            // upgrades the session into its native control-mode UI.
            try await runAppleScript("""
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(escapeForAppleScript(command))"
                end tell
            end tell
            """)

        case .ghostty:
            // Ghostty supports `-e <cmd>` to run a command in a fresh
            // window via the `open` URL handler approach. Use `open -na`
            // to force a *new* window even when Ghostty is already running.
            try await runProcess(URL(fileURLWithPath: "/usr/bin/open"),
                ["-na", "Ghostty", "--args", "-e", command])

        case .warp:
            // Warp doesn't expose a `do script`-style scripting hook yet,
            // so we fall back to the same `open -e` shape Ghostty uses.
            try await runProcess(URL(fileURLWithPath: "/usr/bin/open"),
                ["-na", "Warp", "--args", "-e", command])
        }
    }

    /// Attach to a tmux session in the user's preferred terminal.
    ///
    /// CC-capable terminals (iTerm2) share **one** control-mode client per
    /// session — each tmux window already shows up as a native iTerm2
    /// window, so a second `tmux -CC attach` would duplicate everything.
    /// When a control client already exists we route through
    /// `tmux switch-client -c <tty>` to retarget that client; iTerm2
    /// raises the corresponding native window in response. Only the
    /// first session-click for a session actually spawns a new CC
    /// connection.
    ///
    /// Non-CC terminals (Terminal.app, Ghostty, Warp) each new attach is
    /// an independent client — clicking three different windows from
    /// the submenu opens three terminal windows, which is what the user
    /// expects there.
    static func attach(session localSession: LocalTmuxSessionName, window: Int? = nil) async throws {
        let session = localSession.rawValue
        let tmux = locate()?.path ?? "tmux"
        let kind = TerminalAppKind.preferred
        let target = window.map { "\(session):\($0)" }

        // Native Bento terminal: open an in-app libghostty window attached to the
        // session over a local pty + tmux -CC. (Window selection within the
        // session is handled inside the native UI; the `window` arg is ignored
        // here until per-window tabs land.)
        if kind.isNative {
            await MainActor.run { BentoTerminalWindow.focusOrOpen(localSession.id) }
            return
        }

        if kind.supportsTmuxControlMode {
            // CC path: reuse an existing control client if one exists.
            if let cc = await firstControlModeClient(session: localSession) {
                if let target {
                    _ = try await runCapture(URL(fileURLWithPath: tmux), [
                        "switch-client", "-c", cc, "-t", target
                    ])
                }
                // Whether we switched windows or not, the session is
                // already open in iTerm — just bring it forward.
                try await runAppleScript("tell application \"iTerm\" to activate")
                return
            }
            // First attach for this session in CC mode: spawn a fresh
            // -CC client and (optionally) land on the right window.
            var cmd = "\(tmux) -CC attach -t \(shellQuote(session))"
            if let target {
                cmd += " \\; select-window -t \(shellQuote(target))"
            }
            try await openInTerminal(command: cmd, kind: kind)
            return
        }

        // Non-CC path: every menu click opens a new terminal window,
        // optionally pre-selected to the chosen tmux window.
        var cmd = "\(tmux) attach -t \(shellQuote(session))"
        if let target {
            cmd += " \\; select-window -t \(shellQuote(target))"
        }
        try await openInTerminal(command: cmd, kind: kind)
    }

    /// Return the tty path of the first tmux client attached to
    /// `session` in control mode (i.e. iTerm2 CC), or nil if none.
    /// `client_flags` contains "control" for CC clients; non-CC clients
    /// have flags like "active,readonly" instead.
    private static func firstControlModeClient(session: LocalTmuxSessionName) async -> String? {
        guard let rows = await captureRows([
            "list-clients", "-t", session.rawValue, "-F", "#{client_tty}|#{client_flags}"
        ]) else { return nil }
        for parts in rows {
            guard parts.count == 2 else { continue }
            if parts[1].contains("control") {
                return parts[0]
            }
        }
        return nil
    }

    /// Enumerate every window inside `session`. Used to drive the
    /// per-session submenu so users can jump straight to "the claude
    /// window" instead of attaching + typing prefix-n a few times.
    static func listWindows(session localSession: LocalTmuxSessionName) async -> [TmuxWindow] {
        let session = localSession.rawValue
        // Format mirrors listSessions: pipe-separated fields, easy to
        // split unambiguously since tmux disallows `|` in names.
        // index | name | active | pane_count
        guard let rows = await captureRows([
            "list-windows", "-t", session, "-F",
            "#{window_index}|#{window_name}|#{?window_active,1,0}|#{window_panes}"
        ]) else { return [] }
        var windows: [TmuxWindow] = []
        for parts in rows {
            guard parts.count == 4, let idx = Int(parts[0]), let panes = Int(parts[3]) else {
                continue
            }
            windows.append(TmuxWindow(
                session: localSession,
                index: idx,
                name: parts[1],
                active: parts[2] == "1",
                paneCount: panes
            ))
        }
        return windows.sorted { $0.index < $1.index }
    }

    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ script: String) async throws {
        _ = try await run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script])
    }

    private static func runProcess(_ exe: URL, _ args: [String]) async throws {
        _ = try await runCapture(exe, args)
    }

    /// Kill a tmux session. Any Terminal windows attached to it exit.
    /// `=` forces an exact-name target — a bare `-t foo` prefix-matches and
    /// could kill `foo2` instead.
    static func kill(session: LocalTmuxSessionName) async throws {
        guard let tmux = locate() else { return }
        _ = try await runCapture(tmux, ["kill-session", "-t", "=" + session.rawValue])
    }

    /// Rename a tmux session (exact-name target, same as `kill`).
    static func rename(session: LocalTmuxSessionName, to newName: String) async throws {
        guard let tmux = locate() else { return }
        _ = try await runCapture(tmux, ["rename-session", "-t", "=" + session.rawValue, newName])
    }

    // MARK: - helpers

    private static func shellQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private static func run(_ exe: URL, _ args: [String]) async throws -> String {
        try await runCapture(exe, args).out
    }

    /// Run tmux with `args` and split its stdout into rows of `|`-separated
    /// fields — the query shape shared by list-sessions / list-clients /
    /// list-windows. Returns nil when tmux is missing, fails to spawn, or
    /// exits non-zero. Callers validate field counts themselves.
    private static func captureRows(_ args: [String]) async -> [[String]]? {
        guard let tmux = locate() else { return nil }
        guard let result = try? await runCapture(tmux, args), result.code == 0 else {
            return nil
        }
        return result.out.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        }
    }

    private static func runCapture(_ exe: URL, _ args: [String]) async throws
        -> (out: String, err: String, code: Int32)
    {
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // terminationHandler + continuation instead of waitUntilExit, which
        // would park a cooperative-pool thread for the whole run —
        // the app fans these out per-session every refresh tick.
        return try await withCheckedThrowingContinuation { cont in
            proc.terminationHandler = { p in
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                cont.resume(returning: (
                    out: String(decoding: outData, as: UTF8.self),
                    err: String(decoding: errData, as: UTF8.self),
                    code: p.terminationStatus
                ))
            }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

// AgentPreset / AgentSpec / TmuxLayout live in BentoTerminalCore (AgentSpec.swift)
// — the canonical copies. Duplicates here were removed in the module split;
// keep edits in core only.
