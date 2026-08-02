#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import Darwin
import BentoTerminalCore

/// A local pseudo-terminal running a login shell, for the macOS terminal.
/// Spawns via `forkpty`, streams master-fd output to `onData`, accepts input via
/// `write`, and tracks window size via `resize`. This is the macOS counterpart
/// to iOS's SSH transport — the surface and tmux logic above it are identical.
public final class LocalPty: @unchecked Sendable {
    public var onData: ((Data) -> Void)?
    public var onExit: (() -> Void)?

    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?

    /// Serial queue that drains input to the pty master. The master fd is in
    /// blocking mode, so one large write — e.g. a several-hundred-line paste,
    /// which tmux control mode sends as a single ~87 KB `send-keys -H` line —
    /// blocks in the kernel until the slave (tmux) reads it out. Doing that on
    /// the caller's thread froze the whole app: `sendToSSH` runs inside the tmux
    /// `responseLock`, so a stalled paste write held that lock, and the next
    /// main-thread caller (pane select / keystroke, also via `responseLock`)
    /// blocked behind it — a multi-second beachball hang. Offloading here keeps
    /// every caller non-blocking; only this queue waits on a full pty buffer.
    private let writeQueue = DispatchQueue(label: "dev.bento.localpty.write")

    public init() {}

    /// Spawn the shell. `command` overrides the default login shell (e.g.
    /// `["/opt/homebrew/bin/tmux", "-CC", "new", "-A", "-s", "bento"]`).
    public func start(cols: Int, rows: Int, command: [String]? = nil) {
        // Resolve the augmented PATH in the *parent*: Foundation/allocation
        // between fork and exec is unsafe, so the child only calls setenv.
        // Appending the app's helpers/ dir lets a bare `tmux` (typed into the
        // shell to enter -CC mode) resolve to the tmux we bundle, so the app
        // works on Macs with no system tmux. A user's own tmux still wins —
        // login shells put /opt/homebrew/bin etc. ahead of this fallback.
        let childPATH = Self.pathWithBundledBin()
        // A macOS GUI app's process CWD is "/", which the shell — and therefore a
        // plain `tmux new-session` with no `-c` — would inherit, so new empty
        // sessions opened at the filesystem root. Start the shell in the user's
        // home instead (agent sessions pass their own `-c <dir>`, unaffected).
        // Resolve the C string in the PARENT — no allocation between fork & exec.
        let childHome = ProcessInfo.processInfo.environment["HOME"].flatMap { strdup($0) }

        var ws = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(cols, 1)),
                         ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = 0
        let pid = forkpty(&master, nil, nil, &ws)
        if pid < 0 { if let childHome { free(childHome) }; return }

        if pid == 0 {
            // Child: exec the shell, replacing this process image.
            if let childHome { _ = chdir(childHome) }
            let shellPath = command?.first
                ?? ProcessInfo.processInfo.environment["SHELL"]
                ?? "/bin/zsh"
            let args = command ?? [shellPath, "-l"]
            setenv("TERM", "xterm-256color", 1)
            if let childPATH { setenv("PATH", childPATH, 1) }
            var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
            argv.append(nil)
            execvp(shellPath, argv)
            _exit(1)
        }
        if let childHome { free(childHome) }   // parent no longer needs it

        masterFD = master
        childPID = pid

        let src = DispatchSource.makeReadSource(
            fileDescriptor: master,
            queue: DispatchQueue.global(qos: .userInteractive)
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(self.masterFD, &buf, buf.count)
            if n > 0 {
                let data = Data(buf[0..<n])
                // Deliver on the read queue, NOT via the main thread. Terminal
                // output has no business waiting on the UI thread: every
                // keystroke blocks main for milliseconds inside the input
                // method's synchronous IPC, and routing echoes through main
                // meant they queued behind exactly the keystroke they were
                // echoing — measured at 32x worse queueing while typing than
                // while idle. The consumer re-serializes on its own parse queue.
                self.onData?(data)
            } else {
                DispatchQueue.main.async {
            MainActor.assumeIsolated { self.handleExit() }
        }
            }
        }
        src.resume()
        readSource = src
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async { [weak self] in
            guard let self else { return }
            let fd = self.masterFD
            guard fd >= 0 else { return }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard var ptr = raw.baseAddress else { return }
                var remaining = raw.count
                // Full-write loop. A blocking write can still return short
                // (interrupted by a signal); the old `_ = write(...)` ignored
                // the count and silently dropped the tail of a large paste.
                while remaining > 0 {
                    let n = Darwin.write(fd, ptr, remaining)
                    if n > 0 {
                        ptr = ptr.advanced(by: n)
                        remaining -= n
                    } else if n < 0 && errno == EINTR {
                        continue
                    } else {
                        break   // real error, or the fd was closed under us
                    }
                }
            }
        }
    }

    public func resize(cols: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var ws = winsize(ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(cols, 1)),
                         ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, UInt(TIOCSWINSZ), &ws)
    }

    public func stop() {
        readSource?.cancel()
        readSource = nil
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        if childPID > 0 { kill(childPID, SIGTERM); childPID = -1 }
    }

    private func handleExit() {
        stop()
        onExit?()
    }

    /// The current PATH with the app's `Contents/MacOS/helpers` dir appended,
    /// or nil if the bundle layout can't be resolved (then the child keeps its
    /// inherited PATH). Appended, not prepended, so a system tmux still takes
    /// precedence — matching TmuxResolver's "prefer the user's own tmux" policy.
    private static func pathWithBundledBin() -> String? {
        guard let macOS = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let helpers = macOS.appendingPathComponent("helpers").path
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return base + ":" + helpers
    }
}
#endif
