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

    /// Pinning a session's size has to survive other clients.
    ///
    /// The old "Fit Session to This Window" pushed one `refresh-client -C` and
    /// looked like it did nothing: tmux derives a window's size from its
    /// clients, and under the default `window-size latest` the most recently
    /// used client wins, so the push was undone immediately. A pin therefore
    /// has to switch `window-size` to `manual` — only then does `resize-window`
    /// stick.
    @Test func pinningSizeHoldsOnlyUnderManualWindowSize() throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }

        try tmux.run(["new-session", "-d", "-s", "work", "-x", "200", "-y", "50"])
        let window = try #require(try tmux.windows().first)

        // Default policy: the size is derived, so a manual resize does not hold.
        #expect(try tmux.capture(["show-options", "-gv", "window-size"])
            .trimmingCharacters(in: .whitespacesAndNewlines) == "latest")

        try tmux.runScript([
            TmuxCommand.setWindowOption(name: "window-size", value: "manual").commandString,
            TmuxCommand.resizeWindow(window: window.id, width: 120, height: 30).commandString,
        ])
        #expect(try tmux.size(of: window.id) == "120x30")

        // A different requested size must not move it while pinned.
        try tmux.runScript([
            TmuxCommand.resizeWindow(window: window.id, width: 90, height: 20).commandString
        ])
        #expect(try tmux.size(of: window.id) == "90x20",
                "resize-window is the ONE thing allowed to move a pinned window")

        // Back to tracking: the option returns and clients govern again.
        try tmux.runScript([
            TmuxCommand.setWindowOption(name: "window-size", value: "latest").commandString
        ])
        #expect(try tmux.capture(["show-options", "-wv", "-t", "\(window.id)", "window-size"])
            .trimmingCharacters(in: .whitespacesAndNewlines) == "latest")
    }

    /// Two devices on one session, which is where every sizing decision
    /// actually gets tested. Both clients here are real control-mode clients
    /// (the same `-CC` attach the app makes) at DIFFERENT sizes, because the
    /// whole question is what tmux does when they disagree.
    ///
    /// The three claims the Session Size menu makes, in order:
    ///   - `smallest` → the window is the minimum over attached clients, so
    ///     neither device is clipped and no keystroke can flip it;
    ///   - `manual` → one recorded owner governs and the OTHER client's
    ///     `refresh-client` can no longer move the window (this is the only
    ///     policy where "exactly one device decides" is literally true);
    ///   - leaving `manual` hands the session back to the clients.
    @Test(.enabled(if: LiveTmux.canAttachRealClients))
    func sizingPolicyDecidesWhichClientGoverns() throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }

        try tmux.run(["new-session", "-d", "-s", "work", "-x", "200", "-y", "50"])
        let window = try #require(try tmux.windows().first)

        let big = try tmux.attachControlClient(cols: 140, rows: 40)
        let small = try tmux.attachControlClient(cols: 100, rows: 30)
        defer { big.terminate(); small.terminate() }
        try tmux.waitForClients(2)

        // --- smallest: the minimum, regardless of who was used last ---
        try tmux.runScript([
            TmuxCommand.setWindowOption(name: "window-size", value: "smallest").commandString
        ])
        var settled = try tmux.waitForSize(window.id, "100x30")
        var actual = try tmux.size(of: window.id)
        #expect(settled, "smallest must clamp to the smaller client; got \(actual)")

        // --- manual + resize-window: one owner, and only that owner ---
        try tmux.runScript([
            TmuxCommand.setWindowOption(name: "window-size", value: "manual").commandString,
            TmuxCommand.resizeWindow(window: window.id, width: 140, height: 40).commandString,
        ])
        #expect(try tmux.size(of: window.id) == "140x40")

        // The other client re-announcing itself must NOT move the window — this
        // is what makes an iPad's attach stop reflowing the Mac.
        try tmux.send(small, TmuxCommand.refreshClient(width: 100, height: 30).commandString)
        let held = try tmux.holdsSize(window.id, "140x40")
        actual = try tmux.size(of: window.id)
        #expect(held, "under manual no client may resize the window; got \(actual)")

        // The policy is server state, so the OTHER device can read back both
        // the policy and who owns it — that read is what replaced each device
        // re-asserting its own local preference on every attach.
        try tmux.runScript([
            TmuxCommand.setSessionOption(name: "@bento_size_owner", value: "/dev/ttys012|Shang iPad Air").commandString
        ])
        #expect(try tmux.capture(LiveTmux.splitTmuxArgs(
            TmuxCommand.showWindowOption(window: window.id, name: "window-size").commandString))
            .trimmingCharacters(in: .whitespacesAndNewlines) == "manual")
        #expect(try tmux.capture(LiveTmux.splitTmuxArgs(
            TmuxCommand.showSessionOption(name: "@bento_size_owner").commandString))
            .trimmingCharacters(in: .whitespacesAndNewlines) == "/dev/ttys012|Shang iPad Air")

        // --- release: the clients govern again ---
        try tmux.runScript([
            TmuxCommand.setWindowOption(name: "window-size", value: "smallest").commandString
        ])
        settled = try tmux.waitForSize(window.id, "100x30")
        #expect(settled, "leaving manual must hand the size back to the clients")
    }

    /// Ownership is keyed on the tmux client name, and released when that name
    /// stops appearing in `list-clients`. Both halves have to line up or an
    /// owner that walked away would clamp the session forever: the name a
    /// client reports for itself (`#{client_name}`) must be the same string
    /// `list-clients` prints, and it must disappear when the client does.
    @Test(.enabled(if: LiveTmux.canAttachRealClients))
    func clientNameIsTheOwnershipKeyAndDisappearsOnDetach() throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }

        try tmux.run(["new-session", "-d", "-s", "work", "-x", "200", "-y", "50"])
        let client = try tmux.attachControlClient(cols: 120, rows: 40)
        try tmux.waitForClients(1)

        let names = try tmux.clientNames()
        #expect(names.count == 1)
        let name = try #require(names.first)
        // `#{client_name}` — what the owning device records — is that same name.
        let reported = try tmux.capture(["display-message", "-p", "-t", name, "#{client_name}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(reported == name, "ownership key must round-trip: \(reported) vs \(name)")

        client.terminate()
        var gone = false
        for _ in 0..<30 where !gone {
            gone = try !tmux.clientNames().contains(name)
            if !gone { usleep(100_000) }
        }
        #expect(gone, "a detached client must leave list-clients, or its claim never releases")
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

    func size(of window: TmuxWindowID) throws -> String {
        try capture(["display-message", "-p", "-t", "\(window)", "#{window_width}x#{window_height}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Real control-mode clients
    //
    // Sizing is the one behaviour that cannot be tested without clients: every
    // policy is a rule about how tmux combines them. These attach the same way
    // the app does (`-CC` over pipes, then `refresh-client -C` to declare a
    // size), so the test exercises tmux's real arbitration rather than a model
    // of it.

    /// `tmux -CC` still calls `tcgetattr`, so a client needs a REAL pty — over
    /// plain pipes it exits with "Inappropriate ioctl for device" and never
    /// attaches. `script` is the portable way to hand it one (the app gets its
    /// pty from SSH instead).
    static var canAttachRealClients: Bool {
        isAvailable && FileManager.default.isExecutableFile(atPath: "/usr/bin/script")
    }

    func attachControlClient(cols: Int, rows: Int) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", try LiveTmux.which(),
                       "-L", socket, "-f", "/dev/null", "-CC", "attach", "-t", "work"]
        p.standardInput = Pipe()
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        // Drain stdout or the client blocks once the pipe buffer fills.
        let out = (p.standardOutput as! Pipe).fileHandleForReading
        out.readabilityHandler = { _ = $0.availableData }
        try send(p, TmuxCommand.refreshClient(width: cols, height: rows).commandString)
        return p
    }

    /// Write a command line to a control-mode client's stdin — exactly how the
    /// app talks to tmux.
    func send(_ client: Process, _ command: String) throws {
        guard let pipe = client.standardInput as? Pipe else { return }
        try pipe.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    }

    func clientNames() throws -> [String] {
        let out = try capture(LiveTmux.splitTmuxArgs(TmuxCommand.listClients.commandString))
        // Same split the app uses: the name is a tty path, so cut at the LAST
        // colon to leave the session field behind.
        return out.split(separator: "\n").compactMap { line in
            guard let cut = line.lastIndex(of: ":") else { return nil }
            let name = String(line[line.startIndex..<cut])
            return name.isEmpty ? nil : name
        }
    }

    func waitForClients(_ count: Int, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try clientNames().count >= count { return }
            usleep(50_000)
        }
        throw Failure("only \(try clientNames().count) of \(count) clients attached in time")
    }

    /// Poll until the window reaches `expected` — tmux applies a policy change
    /// on its own event loop, so an immediate read races it.
    func waitForSize(_ window: TmuxWindowID, _ expected: String, timeout: TimeInterval = 5) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try size(of: window) == expected { return true }
            usleep(50_000)
        }
        return false
    }

    /// The inverse assertion: the size must STAY put for a while. Used where
    /// the claim is that something can no longer move the window.
    func holdsSize(_ window: TmuxWindowID, _ expected: String, for seconds: TimeInterval = 0.6) throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try size(of: window) != expected { return false }
            usleep(50_000)
        }
        return true
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
