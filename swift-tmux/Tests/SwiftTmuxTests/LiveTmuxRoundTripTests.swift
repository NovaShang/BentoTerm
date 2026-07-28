import Foundation
import Testing
@testable import SwiftTmux

/// End-to-end round trip against a REAL tmux server.
///
/// This is the judgement the structure work was written to pass: take an
/// ordinary `N windows × M panes` session, spread every pane into its own
/// window (what Focus does), put it back, and require the result to be
/// byte-identical in `#{window_layout}` to what we started with. The previous
/// implementation could not save a mixed shape at all, so it failed this by
/// construction — three windows came back as one.
///
/// Commands are fed through `tmux source-file`, which runs them through tmux's
/// own command parser — the same parser control mode uses. That makes this a
/// test of the exact strings `TmuxCommand.commandString` emits, quoting
/// included, not just of the planning logic. (A layout string carries braces,
/// and an unquoted brace is parsed as a command group and fails silently — the
/// bug this project has already shipped once.)
///
/// Isolation: every run gets its own `-L` socket, so it can never see, resize,
/// or kill anything in the user's real tmux server. The server is killed in a
/// `defer`.
@Suite("live tmux round trip", .enabled(if: LiveTmux.isAvailable))
struct LiveTmuxRoundTripTests {

    @Test func mixedStructureSurvivesSpreadAndRestore() throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }

        // 3 windows; the middle one split twice so it holds three panes.
        try tmux.run(["new-session", "-d", "-s", "work", "-n", "editor"])
        try tmux.run(["new-window", "-t", "work:", "-n", "server"])
        try tmux.run(["split-window", "-h", "-t", "work:server"])
        try tmux.run(["split-window", "-v", "-t", "work:server"])
        try tmux.run(["new-window", "-t", "work:", "-n", "logs"])

        let before = try tmux.windows()
        #expect(before.count == 3, "fixture should have 3 windows, got \(before.count)")
        #expect(before.contains { ($0.layout ?? "").contains("{") || ($0.layout ?? "").contains("[") },
                "fixture should contain a real split (braces/brackets in the layout)")

        // What the app records before rearranging.
        let snapshot = try tmux.snapshot()
        #expect(snapshot.windows.count == 3)
        #expect(snapshot.allPanes.count == 5)

        // --- spread: every pane but the first of each window breaks out ---
        var spread: [String] = []
        for window in snapshot.windows {
            for pane in window.panes.dropFirst() {
                spread.append(TmuxCommand.breakPane(source: pane, name: "pane").commandString)
            }
        }
        try tmux.runScript(spread)

        let spreadWindows = try tmux.windows()
        #expect(spreadWindows.count == 5, "every pane should now own a window")

        // --- restore ---
        let live = Set(try tmux.panes())
        let plan = snapshot.restorePlan(livePanes: live)
        #expect(plan.count == 3)

        for step in plan {
            var script: [String] = []
            var prev = step.base
            for pane in step.join {
                script.append(TmuxCommand.joinPane(source: pane, target: prev).commandString)
                prev = pane
            }
            if let layout = step.layout {
                script.append(
                    TmuxCommand.selectLayoutTarget(target: "\(step.base)", layout: layout).commandString)
            }
            try tmux.runScript(script)
        }

        let after = try tmux.windows()
        #expect(after.count == 3, "expected the original 3 windows, got \(after.count)")

        // The layout string is the whole claim: same geometry, same pane ids,
        // same cells. Compare as a set because window indices shift.
        let beforeLayouts = Set(before.compactMap(\.layout))
        let afterLayouts = Set(after.compactMap(\.layout))
        #expect(afterLayouts == beforeLayouts,
                "layout must round-trip exactly.\n  before: \(beforeLayouts.sorted())\n  after:  \(afterLayouts.sorted())")
    }

    /// A pane that dies while spread must not take its window's siblings with
    /// it, and must not make the restore apply a layout that no longer fits.
    @Test func restoreToleratesAPaneClosedWhileSpread() throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }

        try tmux.run(["new-session", "-d", "-s", "work", "-n", "main"])
        try tmux.run(["split-window", "-h", "-t", "work:main"])
        try tmux.run(["split-window", "-v", "-t", "work:main"])

        let snapshot = try tmux.snapshot()
        #expect(snapshot.allPanes.count == 3)

        var spread: [String] = []
        for window in snapshot.windows {
            for pane in window.panes.dropFirst() {
                spread.append(TmuxCommand.breakPane(source: pane, name: "pane").commandString)
            }
        }
        try tmux.runScript(spread)

        // Kill one of the broken-out panes.
        let victim = snapshot.windows[0].panes[1]
        try tmux.run(["kill-pane", "-t", "\(victim)"])

        let live = Set(try tmux.panes())
        #expect(!live.contains(victim))

        let plan = snapshot.restorePlan(livePanes: live)
        #expect(plan.count == 1)
        #expect(plan[0].layout == nil, "a dead pane invalidates the saved geometry")
        #expect(plan[0].join.count == 1)

        for step in plan {
            var script: [String] = []
            var prev = step.base
            for pane in step.join {
                script.append(TmuxCommand.joinPane(source: pane, target: prev).commandString)
                prev = pane
            }
            script.append(
                TmuxCommand.selectLayoutTarget(target: "\(step.base)", layout: step.layout ?? "tiled").commandString)
            try tmux.runScript(script)
        }

        let after = try tmux.windows()
        #expect(after.count == 1, "survivors should be back in one window, got \(after.count)")
        #expect(try tmux.panes().count == 2)
    }

    /// Breaking a pane out must NOT name the new window.
    ///
    /// Naming a window explicitly is what makes tmux turn `automatic-rename`
    /// off for it — permanently. The spread used to pass the pane's title as
    /// `-n`, so every broken-out window froze at whatever the agent's OSC title
    /// said at that instant, and the frozen name survived the merge back onto
    /// whichever window became the base. The toolbar then showed a title that
    /// matched no pane in that window.
    @Test func breakingPanesOutLeavesAutomaticRenameAlone() throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }

        // Deliberately NOT `-n`: naming at creation freezes automatic-rename
        // just like renaming later does, so a named fixture would poison the
        // very thing under test. (That rule is easy to miss — this test caught
        // it on its first run.)
        try tmux.run(["new-session", "-d", "-s", "work"])
        try tmux.run(["split-window", "-t", "work:"])
        try tmux.run(["split-window", "-t", "work:"])
        #expect(try tmux.capture(["show-options", "-gv", "automatic-rename"])
            .trimmingCharacters(in: .whitespacesAndNewlines) == "on")

        let snapshot = try tmux.snapshot()
        var spread: [String] = []
        for window in snapshot.windows {
            for pane in window.panes.dropFirst() {
                let cmd = TmuxCommand.breakPane(source: pane).commandString
                #expect(!cmd.contains(" -n "), "break-pane must not name the window: \(cmd)")
                spread.append(cmd)
            }
        }
        try tmux.runScript(spread)

        let flags = try tmux.capture(
            ["list-windows", "-t", "work", "-F", "#{window_index}:#{?automatic-rename,on,OFF}"])
            .split(separator: "\n").map(String.init)
        #expect(flags.count == 3)
        #expect(flags.allSatisfy { $0.hasSuffix(":on") },
                "every window must still auto-rename; got \(flags)")
    }

    /// The snapshot is stored in a tmux session option and read back through
    /// tmux's parser. This is where the brace hazard bit before.
    @Test func snapshotSurvivesStorageInATmuxOption() throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }

        try tmux.run(["new-session", "-d", "-s", "work", "-n", "main"])
        try tmux.run(["split-window", "-h", "-t", "work:main"])

        let snapshot = try tmux.snapshot()
        let encoded = try #require(snapshot.encoded())
        try tmux.runScript([
            TmuxCommand.setSessionOption(target: "work", name: "@bento_structure", value: encoded).commandString
        ])
        let read = try tmux.capture(["show-options", "-v", "-t", "work", "@bento_structure"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(TmuxStructureSnapshot.decode(read) == snapshot,
                "snapshot must survive a tmux option round trip")
    }
}

// MARK: - Isolated tmux server harness

struct LiveTmux {
    let socket: String

    static var isAvailable: Bool {
        (try? LiveTmux.which()) != nil
    }

    static func which() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", "tmux"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, !out.isEmpty else {
            throw Failure("tmux not installed")
        }
        return out
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    init() throws {
        _ = try LiveTmux.which()
        // A dedicated socket: this server shares nothing with the user's.
        socket = "bento-test-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0..<UInt32.max))"
    }

    func shutdown() {
        _ = try? capture(["kill-server"])
    }

    @discardableResult
    func run(_ args: [String]) throws -> String {
        try capture(args)
    }

    /// Feed command STRINGS through tmux's own parser, the way control mode
    /// does — this is what makes the test cover quoting.
    func runScript(_ commands: [String]) throws {
        guard !commands.isEmpty else { return }
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bento-tmux-\(UUID().uuidString).conf")
        try (commands.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let out = try capture(["source-file", file.path])
        guard out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure("tmux rejected a command: \(out)\nscript:\n\(commands.joined(separator: "\n"))")
        }
    }

    func capture(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try LiveTmux.which())
        // `-L` gives this server its own socket; `-f /dev/null` keeps it from
        // loading the user's ~/.tmux.conf. Both matter: the first means the test
        // can never touch a real session, the second means the result does not
        // depend on whatever the developer happens to have configured (a stray
        // warning from that file was the first thing this harness tripped on).
        p.arguments = ["-L", socket, "-f", "/dev/null"] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func windows() throws -> [TmuxWindow] {
        let fmt = TmuxCommand.listWindows(target: "work").commandString
        // Reuse the app's own format string and parser so the test can't drift
        // from what the app actually asks tmux for.
        let args = LiveTmux.splitTmuxArgs(fmt)
        return TmuxParsers.parseWindowList(try capture(args))
    }

    func panes() throws -> [TmuxPaneID] {
        let out = try capture(["list-panes", "-s", "-t", "work", "-F", "#{pane_id}"])
        return out.split(separator: "\n").compactMap { TmuxPaneID(string: String($0)) }
    }

    /// Build the same snapshot the app builds from a live session.
    func snapshot() throws -> TmuxStructureSnapshot {
        let wins = try windows()
        return TmuxStructureSnapshot(windows: try wins.map { window in
            let ids = try capture(["list-panes", "-t", "\(window.id)", "-F", "#{pane_id}"])
                .split(separator: "\n").compactMap { TmuxPaneID(string: String($0)) }
            return .init(index: window.index, name: window.name, layout: window.layout, panes: ids)
        })
    }

    /// Split a tmux command string into argv, honoring the single quotes
    /// `escapeArg` emits (the CLI takes argv; only source-file takes a string).
    static func splitTmuxArgs(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuote = false
        var any = false
        for ch in s {
            if ch == "'" { inQuote.toggle(); any = true; continue }
            if ch == " ", !inQuote {
                if any || !current.isEmpty { args.append(current) }
                current = ""; any = false
                continue
            }
            current.append(ch)
        }
        if any || !current.isEmpty { args.append(current) }
        return args
    }
}
