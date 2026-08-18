import Foundation
import Testing
@testable import BentoTmuxKit

/// "Duplicate Current", end to end against a REAL tmux server.
///
/// The bug this suite pins down: the duplicate used to seed the new pane with
/// `#{pane_current_command}`. On Darwin that format is the kernel's accounting
/// name of the foreground process (`p_comm`, what `ps -o ucomm` prints) — the
/// name of the exec'd FILE, not argv[0]. Claude Code installs versioned, at
/// `~/.local/share/claude/versions/2.1.234`, so duplicating a pane running it
/// sent `split-window -c <dir> '2.1.234'`; nothing on `PATH` is called that, the
/// spawned shell exited within milliseconds, tmux destroyed the pane, and if it
/// was the window's only pane the window went too — which looked like the app
/// losing the window.
///
/// Only tmux can answer whether a pane SURVIVES, so these run the app's own
/// command strings through `source-file` (tmux's own parser, the same one
/// control mode uses) on a private `-L` socket, and then look at what is still
/// alive a moment later. `LiveTmux` lives in `LiveTmuxRoundTripTests.swift`.
@Suite("live tmux — Duplicate Current", .enabled(if: LiveTmux.isAvailable))
struct DuplicateSeedLiveTests {

    /// A directory to duplicate FROM, with symlinks resolved: tmux reports
    /// `#{pane_current_path}` as the REAL path, and on macOS the temporary
    /// directory lives under `/var`, a link to `/private/var`.
    ///
    /// Resolved with POSIX `realpath`, not `URL.resolvingSymlinksInPath` —
    /// Foundation's version does the opposite of what is needed here, deleting a
    /// leading `/private` instead of adding it, so the comparison failed against
    /// a path that was already correct.
    private func fixtureDirectory() throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bento-dup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let resolved = realpath(dir.path, nil) else { return dir.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Panes still alive after tmux has had time to reap a pane that died on
    /// spawn. A pane that fails to exec is gone in ~10ms; the wait is slack.
    private func survivingPanes(_ tmux: LiveTmux) throws -> [TmuxPaneID] {
        Thread.sleep(forTimeInterval: 0.5)
        return try tmux.panes()
    }

    private func value(_ tmux: LiveTmux, _ format: String, of pane: TmuxPaneID) throws -> String {
        try tmux.capture(["display-message", "-p", "-t", "\(pane)", format])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - The regression itself

    /// The old behaviour, reduced to one command: this is what the app sent,
    /// and it is why the pane vanished. Kept as a test so the reason the seed
    /// dropped is not just a comment.
    @Test func aCapturedProcessNameKillsTheNewPane() throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }
        let dir = try fixtureDirectory()

        try tmux.run(["new-session", "-d", "-s", "work", "-c", dir])
        let source = try #require(try tmux.panes().first)

        try tmux.runScript([TmuxCommand.splitWindow(
            target: source, horizontal: true, path: dir,
            command: .shell("2.1.234")).commandString])

        #expect(try survivingPanes(tmux) == [source],
                "a pane seeded with an exec name that is not on PATH cannot survive")
    }

    // MARK: - The fix

    /// Tiled mode's "Split — Duplicate Current" (`splitPane`), on a pane whose
    /// program was typed into the shell — the common case, and the broken one.
    @Test func splitDuplicateSurvivesAndKeepsTheDirectory() throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }
        let dir = try fixtureDirectory()

        try tmux.run(["new-session", "-d", "-s", "work", "-c", dir])
        let source = try #require(try tmux.panes().first)

        // What `resolveSeed` now produces when `#{pane_start_command}` is empty:
        // the source pane's directory, and no command at all.
        try tmux.runScript([TmuxCommand.splitWindow(
            target: source, horizontal: true, path: dir, command: nil).commandString])

        let panes = try survivingPanes(tmux)
        #expect(panes.count == 2, "the duplicate must still be there, got \(panes)")
        let duplicate = try #require(panes.first { $0 != source })
        let landed = try value(tmux, "#{pane_current_path}", of: duplicate)
        #expect(landed == dir, "the duplicate must land in the seeded directory, got \(landed)")
        #expect(landed == (try value(tmux, "#{pane_current_path}", of: source)),
                "…which is the source pane's directory — that is what duplicating copies")
    }

    /// List mode's "New Window (duplicate)" (`newListWindow`) — a separate
    /// tmux call with its own seed, so it needs its own pass.
    @Test func newWindowDuplicateSurvivesAndKeepsTheDirectory() throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }
        let dir = try fixtureDirectory()

        try tmux.run(["new-session", "-d", "-s", "work", "-c", NSHomeDirectory()])
        let source = try #require(try tmux.panes().first)

        try tmux.runScript([TmuxCommand.newWindow(
            target: "work:", path: dir, command: nil).commandString])

        let panes = try survivingPanes(tmux)
        #expect(panes.count == 2, "the duplicated window must still be there, got \(panes)")
        let duplicate = try #require(panes.first { $0 != source })
        let landed = try value(tmux, "#{pane_current_path}", of: duplicate)
        #expect(landed == dir, "the new window must land in the seeded directory, got \(landed)")
        #expect(try tmux.windows().count == 2)
    }

    /// A duplicate must be the same kind of shell the source pane got — a
    /// LOGIN shell (argv[0] starts with `-`), not a nested interactive one.
    /// Passing no command is what buys this: tmux falls back to
    /// `default-command`/`default-shell`, exactly as it does for the session's
    /// first pane.
    @Test func theDuplicateIsALoginShellJustLikeTheSourcePane() throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }
        let dir = try fixtureDirectory()

        try tmux.run(["new-session", "-d", "-s", "work", "-c", dir])
        let source = try #require(try tmux.panes().first)
        try tmux.runScript([TmuxCommand.splitWindow(
            target: source, horizontal: true, path: dir, command: nil).commandString])

        let duplicate = try #require(try survivingPanes(tmux).first { $0 != source })
        let sourceArgv = try argv(of: value(tmux, "#{pane_pid}", of: source))
        let duplicateArgv = try argv(of: value(tmux, "#{pane_pid}", of: duplicate))
        #expect(sourceArgv.hasPrefix("-"), "fixture check: tmux opens its first pane as a login shell")
        #expect(duplicateArgv == sourceArgv,
                "the duplicate should be the same shell, started the same way")
    }

    /// `ps -o args=` for a pid — argv[0] included, which is the only place the
    /// login `-` shows up (`#{pane_current_command}` strips it).
    private func argv(of pid: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "args=", "-p", pid]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The failure everyone actually reported: duplicating the only pane in a
    /// window took the window with it, because tmux closes a window when its
    /// last pane exits and the duplicate died on spawn.
    @Test func duplicatingTheOnlyPaneCannotCloseTheWindow() throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }
        let dir = try fixtureDirectory()

        try tmux.run(["new-session", "-d", "-s", "work", "-c", dir])
        #expect(try tmux.windows().count == 1)
        let source = try #require(try tmux.panes().first)

        try tmux.runScript([TmuxCommand.splitWindow(
            target: source, horizontal: true, path: dir, command: nil).commandString])

        #expect(try survivingPanes(tmux).count == 2)
        #expect(try tmux.windows().count == 1, "the window must still be open")
        #expect(try tmux.panes().contains(source), "the source pane must be untouched")
    }
}
