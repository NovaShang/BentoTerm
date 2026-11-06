import Foundation
import BentoFoundationKit
import BentoTmuxKit

/// What tmux sessions exist on an ssh host, asked before connecting to it.
///
/// The Mac opens a remote session by handing `ssh` the whole `tmux -CC …` line,
/// which is what makes password and 2FA hosts work — but it also means the app
/// has committed to a session name before it has seen the host. On iOS you pick
/// from a list after connecting; here the list has to come first, so it comes
/// from a separate, short-lived `ssh <alias> tmux list-sessions`.
///
/// Cheap enough to run when the host's submenu opens (one connection, ~6s ceiling, cached for a
/// few seconds so reopening the menu doesn't re-ssh), and honest when it
/// can't: a host that wants a password we don't have says so, rather than
/// showing an empty list that reads as "nothing running here".
@MainActor
public enum RemoteTmuxSessions {

    public typealias Session = TmuxSessionListing.Session
    public typealias Failure = TmuxSessionListing.Failure

    /// Cached per alias. Short: the point of the list is that it is current, and
    /// the cost of being wrong is attaching to a session that just died.
    private static var cache: [String: (stamp: Date, result: Result<[Session], Failure>)] = [:]
    private static let cacheTTL: TimeInterval = 5

    public static func cached(_ alias: String) -> Result<[Session], Failure>? {
        guard let hit = cache[alias], Date().timeIntervalSince(hit.stamp) < cacheTTL else { return nil }
        return hit.result
    }

    public static func list(alias: String) async -> Result<[Session], Failure> {
        if let hit = cached(alias) { return hit }
        let result = await run(alias: alias)
        cache[alias] = (Date(), result)
        return result
    }

    /// Drop the cache for a host — after opening a session on it, so coming
    /// straight back to the list shows the session that was just created.
    public static func invalidate(_ alias: String) { cache[alias] = nil }

    // MARK: - The call

    private static func run(alias: String) async -> Result<[Session], Failure> {
        // `$SHELL -lc` for the same reason the launch line uses it: tmux is
        // routinely in a PATH that only the login shell builds, and a
        // non-interactive ssh command does not get one.
        let remote = "$SHELL -lc 'tmux list-sessions -F \"\(TmuxSessionListing.format)\"'"
        var args = ["-o", "ConnectTimeout=6", "-o", "NumberOfPasswordPrompts=1"]

        // A password we were told to remember is a password we can use here.
        // Without one, BatchMode keeps ssh from sitting on a prompt that has no
        // window to appear in.
        let stored = MacKeychain.load(SecretKeys.sshPassword(host: alias))
        var env = ProcessInfo.processInfo.environment
        var askpass: URL?
        if let stored, let helper = try? makeAskpassHelper() {
            askpass = helper
            env["SSH_ASKPASS"] = helper.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["BENTO_SSH_PASSWORD"] = stored
        } else {
            args += ["-o", "BatchMode=yes"]
        }
        defer { if let askpass { try? FileManager.default.removeItem(at: askpass) } }

        let out = await Self.capture(["/usr/bin/ssh"] + args + [alias, remote], env: env)
        return TmuxSessionListing.result(status: out.status, stdout: out.stdout, stderr: out.stderr)
    }

    /// A one-line executable that prints the password ssh is asking for.
    ///
    /// ssh will not read a password from stdin — it opens /dev/tty — so the
    /// supported way to answer without a terminal is SSH_ASKPASS. The secret
    /// travels in the child's environment rather than in the file, so it is not
    /// left on disk even for the moment the helper exists.
    private static func makeAskpassHelper() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-askpass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let script = dir.appendingPathComponent("askpass")
        try "#!/bin/sh\nprintf '%s' \"$BENTO_SSH_PASSWORD\"\n".write(to: script, atomically: true,
                                                                    encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private struct Captured { let status: Int32; let stdout: String; let stderr: String }

    private static func capture(_ argv: [String], env: [String: String]) async -> Captured {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: argv[0])
                proc.arguments = Array(argv.dropFirst())
                proc.environment = env
                let out = Pipe(), err = Pipe()
                proc.standardOutput = out
                proc.standardError = err
                // No terminal: ssh must never try to prompt on ours.
                proc.standardInput = FileHandle.nullDevice
                do {
                    try proc.run()
                } catch {
                    continuation.resume(returning: Captured(
                        status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                continuation.resume(returning: Captured(
                    status: proc.terminationStatus,
                    stdout: String(decoding: o, as: UTF8.self),
                    stderr: String(decoding: e, as: UTF8.self)))
            }
        }
    }
}
