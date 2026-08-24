#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import BentoFoundationKit
import os

private let log = Logger(subsystem: "com.novashang.bento", category: "PortForward")

/// Port forwarding on macOS: `ssh -O forward` onto the session's own control
/// socket (see `SSHControlSockets` for why that is the whole trick).
///
/// Diagnose with `log stream --predicate 'category == "PortForward"'`.
@MainActor
final class MacPortForwarder: PortForwarding {

    private var forwards: [String: PortForward] = [:]
    /// Ports promised to a forward that may not have been bound yet — two
    /// requests in the same runloop turn must not be handed the same number.
    private var claimed: Set<Int> = []

    var active: [PortForward] { Array(forwards.values) }

    // MARK: PortForwarding

    func forward(remotePort: Int, on host: LinkHost) async throws -> PortForward {
        // A local pane's `localhost` is already this machine. Nothing to tunnel,
        // and nothing to tear down later.
        guard let alias = host.remoteID else {
            return PortForward(host: host, remotePort: remotePort, localPort: remotePort)
        }
        let key = PortForward(host: host, remotePort: remotePort, localPort: remotePort).id
        if let existing = forwards[key] { return existing }

        guard LocalPortProbe.isPlausible(remotePort) else {
            throw PortForwardError.unsupported("Port \(remotePort) isn’t forwardable")
        }
        let candidates = SSHControlSockets.candidates(for: alias)
        guard !candidates.isEmpty else {
            throw PortForwardError.unsupported(
                "No live connection to \(host.label) to tunnel through")
        }
        guard let localPort = LocalPortProbe.choose(matching: remotePort, taken: claimed) else {
            throw PortForwardError.noLocalPort
        }
        claimed.insert(localPort)
        defer { claimed.remove(localPort) }

        // Newest session first. A socket whose session has since died fails
        // fast, so trying the list in order costs nothing and survives the
        // case where the pane that printed the link is not the newest one.
        var lastError = "Couldn’t reach \(host.label)"
        for controlPath in candidates {
            let result = await Self.ssh(SSHForwardCommand.forward(
                localPort: localPort, remotePort: remotePort,
                alias: alias, controlPath: controlPath))
            if result.status == 0 {
                let made = PortForward(host: host, remotePort: remotePort, localPort: localPort)
                forwards[made.id] = made
                log.log("""
                    forward \(host.label, privacy: .public) \
                    \(remotePort, privacy: .public)→\(localPort, privacy: .public)
                    """)
                return made
            }
            lastError = Self.readableFailure(result.stderr, host: host)
            log.error("forward failed: \(result.stderr, privacy: .public)")
        }
        throw PortForwardError.hostUnreachable(lastError)
    }

    func isAlive(_ forward: PortForward) async -> Bool {
        guard let alias = forward.host.remoteID else { return true }
        for controlPath in SSHControlSockets.candidates(for: alias) {
            let r = await Self.ssh(SSHForwardCommand.check(alias: alias, controlPath: controlPath))
            if r.status == 0 { return true }
        }
        return false
    }

    func close(_ forward: PortForward) {
        forwards[forward.id] = nil
        guard let alias = forward.host.remoteID else { return }
        let candidates = SSHControlSockets.candidates(for: alias)
        let localPort = forward.localPort, remotePort = forward.remotePort
        Task {
            for controlPath in candidates {
                let r = await Self.ssh(SSHForwardCommand.cancel(
                    localPort: localPort, remotePort: remotePort,
                    alias: alias, controlPath: controlPath))
                if r.status == 0 { break }
            }
        }
    }

    func closeAll(on host: LinkHost) {
        for f in forwards.values where f.host == host { close(f) }
    }

    // MARK: -

    /// ssh's own words are for ssh users; the panel says what to check instead.
    private static func readableFailure(_ stderr: String, host: LinkHost) -> String {
        let s = stderr.lowercased()
        if s.contains("address already in use") || s.contains("cannot listen to port") {
            return "That local port is taken — close whatever is using it and try again"
        }
        if s.contains("no such file or directory") || s.contains("connection refused")
            || s.contains("control socket") {
            return "The connection to \(host.label) is gone — reconnect the session"
        }
        return "Couldn’t reach \(host.label)"
    }

    private struct Run { let status: Int32; let stderr: String }

    /// `-O` talks to a local socket, so this is fast or it is broken; the
    /// timeout is only there so a wedged master cannot hang the UI's await.
    private static func ssh(_ argv: [String]) async -> Run {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                proc.arguments = argv
                let err = Pipe()
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = err
                proc.standardInput = FileHandle.nullDevice
                do { try proc.run() } catch {
                    continuation.resume(returning: Run(status: -1, stderr: "\(error)"))
                    return
                }
                let watchdog = DispatchWorkItem {
                    if proc.isRunning { proc.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 6, execute: watchdog)
                let data = err.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                watchdog.cancel()
                continuation.resume(returning: Run(
                    status: proc.terminationStatus,
                    stderr: String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }
}
#endif
