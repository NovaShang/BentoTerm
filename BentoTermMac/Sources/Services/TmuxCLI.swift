import Foundation
import BentoTerminalCore

/// TmuxCLI shells out to a tmux binary. The Mac app never proxies the
/// tmux protocol — sessions open in Bento's own in-app terminal, and these
/// calls only query the local server and detach/rename/kill sessions.
/// Binary resolution (system vs bundled) lives in TmuxResolver.
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

    /// Attach to a tmux session: open an in-app libghostty window attached
    /// over a local pty + tmux -CC. Sessions always open in Bento's own
    /// terminal — the third-party terminal attach paths were removed with
    /// the "Open tmux sessions in" setting. (Window selection within the
    /// session is handled inside the native UI; the `window` arg is ignored
    /// here until per-window tabs land.)
    static func attach(session localSession: LocalTmuxSessionName, window: Int? = nil) async throws {
        await MainActor.run { BentoTerminalWindow.focusOrOpen(localSession.id) }
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

    /// Kill a tmux session. Any windows attached to it exit.
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
