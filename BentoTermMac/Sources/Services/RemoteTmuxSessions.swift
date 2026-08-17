import Foundation
import BentoFoundationKit

/// What tmux sessions exist on an ssh host, asked before connecting to it.
///
/// The Mac opens a remote session by handing `ssh` the whole `tmux -CC …` line,
/// which is what makes password and 2FA hosts work — but it also means the app
/// has committed to a session name before it has seen the host. On iOS you pick
/// from a list after connecting; here the list has to come first, so it comes
/// from a separate, short-lived `ssh <alias> tmux list-sessions`.
///
/// Cheap enough to run on a drill-in (one connection, ~6s ceiling, cached for a
/// few seconds so re-rendering the palette doesn't re-ssh), and honest when it
/// can't: a host that wants a password we don't have says so, rather than
/// showing an empty list that reads as "nothing running here".
@MainActor
public enum RemoteTmuxSessions {

    public struct Session: Equatable, Sendable {
        public let name: String
        public let windows: Int
        /// Someone (maybe another machine) has a client on it right now.
        public let attached: Bool

        public init(name: String, windows: Int, attached: Bool) {
            self.name = name
            self.windows = windows
            self.attached = attached
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// ssh could not authenticate without asking a human.
        case needsCredentials
        /// tmux is not installed, or not on the login shell's PATH.
        case noTmux
        /// tmux is there, but no server is running — no sessions yet.
        case noSessions
        /// Anything else: unreachable, host-key trouble, timeout.
        case unreachable(String)

        /// One line, for the row that stands in for the list.
        public var message: String {
            switch self {
            case .needsCredentials:
                return "Needs a password — connect once and save it to list sessions here"
            case .noTmux: return "tmux isn’t installed on this host"
            case .noSessions: return "No tmux sessions running"
            case .unreachable(let why): return why
            }
        }
    }

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
        let remote = "$SHELL -lc 'tmux list-sessions -F \"#{session_name}|#{session_windows}|#{session_attached}\"'"
        var args = ["-o", "ConnectTimeout=6", "-o", "NumberOfPasswordPrompts=1"]

        // A password we were told to remember is a password we can use here.
        // Without one, BatchMode keeps ssh from sitting on a prompt that has no
        // window to appear in.
        let stored = MacKeychain.load("sshPassword:\(alias)")
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
        return parse(status: out.status, stdout: out.stdout, stderr: out.stderr)
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

    // MARK: - Reading the answer

    /// Pure, so the cases that matter can be tested without an ssh host.
    public static func parse(status: Int32, stdout: String, stderr: String) -> Result<[Session], Failure> {
        let sessions = stdout
            .split(separator: "\n")
            .compactMap { line -> Session? in
                // Split from the right: the two trailing fields are numbers we
                // wrote, and a session name is allowed to contain the separator.
                let f = line.split(separator: "|", omittingEmptySubsequences: false)
                guard f.count >= 3 else { return nil }
                let name = f.dropLast(2).joined(separator: "|")
                guard !name.isEmpty else { return nil }
                return Session(name: name,
                               windows: Int(f[f.count - 2]) ?? 1,
                               attached: (Int(f[f.count - 1]) ?? 0) > 0)
            }
        if !sessions.isEmpty { return .success(sessions) }

        let err = stderr.lowercased()
        // ssh's own failures come back as 255; anything else is the remote
        // command's own exit code, and tmux is the only thing we ran.
        if err.contains("permission denied") || err.contains("no supported authentication")
            || err.contains("password") {
            return .failure(.needsCredentials)
        }
        if err.contains("host key verification failed") {
            return .failure(.unreachable("Host key verification failed"))
        }
        if err.contains("command not found") || err.contains("no such file") {
            return .failure(.noTmux)
        }
        if err.contains("no server running") || err.contains("error connecting to") {
            return .failure(.noSessions)
        }
        if status == 0 { return .failure(.noSessions) }
        let firstLine = stderr.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return .failure(.unreachable(firstLine?.isEmpty == false ? firstLine! : "Couldn’t reach this host"))
    }
}
