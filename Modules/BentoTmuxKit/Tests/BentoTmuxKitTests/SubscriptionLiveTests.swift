import Foundation
import Testing
@testable import BentoTmuxKit

/// The working-directory push, end to end against a REAL tmux control client.
///
/// There is no OS event for "a process changed its cwd", so the only way the
/// Files tree can follow `cd` without polling is tmux's own subscription:
/// `refresh-client -B` makes the server re-check a format about once a second
/// and push `%subscription-changed` when the value moves. This drives the app's
/// exact command string and parser over a `-CC` client (private `-L` socket,
/// `-f /dev/null`, as everywhere in the live suites) and requires the `cd` to
/// arrive as a notification for the right pane — with a path that has a space
/// and a colon in it, the two characters the parse has to survive.
@Suite("live tmux — cwd subscription", .enabled(if: LiveTmux.canAttachRealClients))
struct SubscriptionLiveTests {

    @Test func cdInAPaneIsPushed() async throws {
        let tmux = try LiveTmux()
        defer { tmux.shutdown() }

        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bento sub:\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // tmux reports the REAL path (/var → /private/var on macOS).
        let dir: String = {
            guard let r = realpath(base.path, nil) else { return base.path }
            defer { free(r) }
            return String(cString: r)
        }()

        // /bin/sh, not the developer's login shell: nothing from ~/.zshrc can
        // change directory behind the test's back.
        try tmux.run(["new-session", "-d", "-s", "work", "-x", "80", "-y", "24", "/bin/sh"])
        let pane = try #require(try tmux.panes().first)

        let (service, collector) = makeService()
        let client = try tmux.attachParsingControlClient(into: service)
        defer { client.terminate() }
        #expect(await service.awaitControlMode(timeout: .seconds(5)), "control client never greeted")

        let resp = await service.send(
            .subscribe(name: "bento_cwd", target: "%*", format: "#{pane_current_path}"),
            timeout: .seconds(5))
        #expect(!resp.isError, "tmux refused the subscription: \(resp.output)")

        try tmux.run(["send-keys", "-t", "\(pane)", "cd '\(dir)'", "Enter"])

        // tmux checks subscriptions on a one-second timer; allow a few ticks.
        let deadline = Date().addingTimeInterval(6)
        var seen: [String] = []
        while Date() < deadline {
            seen = collector.notifications.compactMap {
                if case .subscriptionChanged("bento_cwd", pane, let value) = $0 { return value }
                return nil
            }
            if seen.contains(dir) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(seen.contains(dir), "expected a push of \(dir) for \(pane); saw \(seen)")

        // Re-subscribing under the same name must report the UNCHANGED value
        // again — the session-switch path relies on it to refill panes whose
        // directories were pruned while another session was attached.
        let before = seen.count
        #expect(!(await service.send(
            .subscribe(name: "bento_cwd", target: "%*", format: "#{pane_current_path}"),
            timeout: .seconds(5))).isError)
        let again = Date().addingTimeInterval(4)
        while Date() < again {
            seen = collector.notifications.compactMap {
                if case .subscriptionChanged("bento_cwd", pane, let value) = $0 { return value }
                return nil
            }
            if seen.count > before { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(seen.count > before && seen.last == dir,
                "re-subscribing should re-report \(dir); saw \(seen)")
    }
}

extension LiveTmux {
    /// A `-CC` client whose output is parsed by a real `TmuxControlMode`, and
    /// whose commands go out through it — the app's own path, minus the app.
    func attachParsingControlClient(into service: TmuxControlMode) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", try LiveTmux.which(),
                       "-L", socket, "-f", "/dev/null", "-CC", "attach", "-t", "work"]
        let stdin = Pipe()
        let stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = Pipe()
        let writer = stdin.fileHandleForWriting
        service.sendToSSH = { command in
            try? writer.write(contentsOf: Data(command.utf8))
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { service.feedData(data) }
        }
        try p.run()
        return p
    }
}
