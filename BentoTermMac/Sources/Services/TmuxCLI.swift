import Foundation
import BentoFoundationKit
import BentoSessionKit
import BentoUISharedKit
import BentoTmuxKit

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

    /// Sessions on this machine's server, most recently active first — "what
    /// I'm currently working on" sits at the top. Empty when tmux is missing or
    /// no server is running.
    static func listSessions() async -> [TmuxSessionListing.Session] {
        guard let tmux = locate(),
              let result = try? await runCapture(tmux, TmuxSessionListing.arguments),
              result.code == 0 else { return [] }
        return TmuxSessionListing.parse(result.out).sorted {
            ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

    /// Enumerate every window inside `session`. Used to drive the
    /// per-session submenu so users can jump straight to "the claude
    /// window" instead of attaching + typing prefix-n a few times.
    static func listWindows(session localSession: LocalTmuxSessionName) async -> [LocalWindowInfo] {
        // One row per PANE (`list-panes -s`), folded into windows here: the
        // sidebar needs each window's pane status (`@bento_state`) and what its
        // active pane is doing, and a window-scoped listing can only see the
        // active pane. Same number of tmux calls per session as before.
        //
        // Tab-separated, the free-text fields last: a title or a name can hold
        // `|`, and `maxSplits` keeps whatever the title contains in one field.
        guard let tmux = locate(),
              let result = try? await runCapture(tmux, [
                "list-panes", "-s", "-t", "=" + localSession.rawValue, "-F",
                LocalWindowInfo.paneListingFormat,
              ]), result.code == 0 else { return [] }
        return LocalWindowInfo.parsePaneListing(result.out)
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
