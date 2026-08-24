#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import os

private let log = Logger(subsystem: "com.novashang.bento", category: "PortForward")

/// How a forward gets onto a machine we are already logged into.
///
/// The Mac opens a remote session by handing the whole `tmux -CC …` line to the
/// real `ssh` binary, which is what makes password and 2FA hosts work at all.
/// A forward must not undo that by opening a second connection and asking for
/// the password again — so the session's own ssh is told to keep a control
/// socket, and `ssh -O forward` adds the tunnel to that existing, already
/// authenticated connection. No second login, no second 2FA code.
///
/// Each session mints its OWN socket rather than sharing one per host. Sharing
/// would make the second window a multiplexing slave of the first, and closing
/// the first window would then take the second window's session down with it.
/// A private socket per session keeps the wire behaviour exactly what it is
/// today.
@MainActor
enum SSHControlSockets {

    /// What a session learned when it adopted a socket.
    struct Adopted {
        /// Extra `ssh` arguments for the session's own invocation.
        let options: [String]
        /// `-o ControlPath=` value for later `-O forward` calls, or nil when the
        /// user's own ssh_config already names one (then ssh finds it itself).
        let controlPath: String?
    }

    /// alias → the sockets of its live sessions, newest first.
    private static var sockets: [String: [String?]] = [:]
    /// alias → whether `ssh -G` said the user configures their own ControlPath.
    private static var userConfigured: [String: Bool] = [:]

    /// Set up (or join) a control socket for a session about to connect to
    /// `alias`. Pair every call with `release`.
    static func adopt(alias: String) -> Adopted {
        if usesOwnControlPath(alias: alias) {
            // Their setup already multiplexes; joining it is what happens today,
            // and forwards can ride their master. Injecting our own path would
            // silently opt them out of their own config.
            sockets[alias, default: []].insert(nil, at: 0)
            return Adopted(options: [], controlPath: nil)
        }
        guard let path = mintSocketPath() else {
            log.error("could not create a control socket dir — forwards will need a second login")
            return Adopted(options: [], controlPath: nil)
        }
        sockets[alias, default: []].insert(path, at: 0)
        return Adopted(
            options: ["-o", "ControlMaster=auto", "-o", "ControlPath=\(path)"],
            controlPath: path)
    }

    /// The session ended: drop its socket (and the file, if we made it).
    static func release(alias: String, controlPath: String?) {
        guard var list = sockets[alias] else { return }
        if let idx = list.firstIndex(where: { $0 == controlPath }) {
            list.remove(at: idx)
        }
        if list.isEmpty { sockets[alias] = nil } else { sockets[alias] = list }
        if let controlPath { try? FileManager.default.removeItem(atPath: controlPath) }
    }

    /// Every control path worth trying for `alias`, newest session first. A
    /// `nil` element means "no `-o ControlPath`" — let ssh read the config.
    static func candidates(for alias: String) -> [String?] {
        sockets[alias] ?? []
    }

    // MARK: -

    /// Does the user's own ssh_config set a ControlPath for this host?
    ///
    /// Asked of ssh itself (`ssh -G` prints the fully resolved config) rather
    /// than by re-implementing Host patterns, Match blocks and Include. `ssh -G`
    /// omits the key entirely when it is unset, so presence is the answer.
    /// Cached: the answer does not change while the app runs, and this is on the
    /// path that builds a connection's argv.
    private static func usesOwnControlPath(alias: String) -> Bool {
        if let known = userConfigured[alias] { return known }
        let answer = resolvedConfig(alias: alias)
            .contains { line in
                let l = line.lowercased()
                return l.hasPrefix("controlpath ") && l != "controlpath none"
            }
        userConfigured[alias] = answer
        return answer
    }

    private static func resolvedConfig(alias: String) -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-G", alias]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        // `ssh -G` only parses config — except that a `Match exec` directive
        // runs a command, which can be arbitrarily slow. This is on the path
        // that builds a window, so it gets a leash.
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// A short, unique socket path. Unix socket paths cap out around 104 bytes,
    /// which is why this is `s-8hex` under a fixed directory rather than
    /// anything descriptive.
    private static func mintSocketPath() -> String? {
        let dir = NSHomeDirectory() + "/.bento/cm"
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        return "\(dir)/s-\(id)"
    }
}
#endif
