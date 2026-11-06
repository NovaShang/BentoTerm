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

    private let book = PortForwardBook<Void>()

    var active: [PortForward] { book.active }

    // MARK: PortForwarding

    func forward(remotePort: Int, on host: LinkHost) async throws -> PortForward {
        try await book.forward(
            remotePort: remotePort, on: host,
            connection: { alias in
                let candidates = SSHControlSockets.candidates(for: alias)
                return candidates.isEmpty ? nil : (alias: alias, sockets: candidates)
            },
            open: { ride, made in
                // Newest session first. A socket whose session has since died
                // fails fast, so trying the list in order costs nothing and
                // survives the case where the pane that printed the link is not
                // the newest one.
                var lastError = PortForwardError.couldNotReach(host)
                for controlPath in ride.sockets {
                    let result = await Self.ssh(SSHForwardCommand.forward(
                        localPort: made.localPort, remotePort: made.remotePort,
                        alias: ride.alias, controlPath: controlPath))
                    if result.status == 0 { return }
                    lastError = Self.readableFailure(result.stderr, host: host)
                    log.error("forward failed: \(result.stderr, privacy: .public)")
                }
                throw lastError
            })
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
        book.remove(forward)
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
        for f in book.forwards(on: host) { close(f) }
    }

    // MARK: -

    /// ssh's own words are for ssh users; the panel says what to check instead.
    private static func readableFailure(_ stderr: String, host: LinkHost) -> PortForwardError {
        let s = stderr.lowercased()
        if s.contains("address already in use") || s.contains("cannot listen to port") {
            return .hostUnreachable("That local port is taken — close whatever is using it and try again")
        }
        if s.contains("no such file or directory") || s.contains("connection refused")
            || s.contains("control socket") {
            return .hostUnreachable("The connection to \(host.label) is gone — reconnect the session")
        }
        return .couldNotReach(host)
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
