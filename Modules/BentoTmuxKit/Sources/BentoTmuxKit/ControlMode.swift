import Foundation
import os

/// Parses and manages the tmux control-mode (`-CC`) protocol.
///
/// Commands are sent as plain text lines via stdin. Responses come back
/// wrapped in `%begin`/`%end` (or `%error`) blocks with tmux-assigned command
/// numbers. We use a FIFO queue to match responses to awaiting callers since
/// tmux's command numbers are globally incremented (not per-client).
///
/// I/O is transport-agnostic: feed bytes in via `feedData(_:)`, hook
/// `sendToSSH` to forward outgoing commands, observe parsed events via
/// `onNotification`.
public final class TmuxControlMode: @unchecked Sendable {

    /// Called for each parsed notification (output, layout changes, etc.).
    public var onNotification: (@Sendable (TmuxNotification) -> Void)?

    /// Called to send a command (with trailing newline) to the SSH channel
    /// or other transport carrying the tmux session.
    public var sendToSSH: (@Sendable (String) -> Void)?

    /// Optional log hook for sends/receives and warnings. Set this to bridge
    /// into your app's logger (`print`, `os.Logger`, swift-log, etc.). If
    /// `nil`, the parser also writes through to a default `os.Logger`
    /// (subsystem `dev.swifttmux`, category `controlmode`) so traces still
    /// land in Console.app when developing.
    public var logHandler: (@Sendable (String) -> Void)?

    private let logger = Logger(subsystem: "dev.swifttmux", category: "controlmode")

    // Response tracking: FIFO queue of continuations
    private let responseLock = OSAllocatedUnfairLock(initialState: ResponseState())

    /// One slot in the response queue. Every command that goes out — awaited or
    /// not — appends exactly one, so queue position and wire order can never
    /// diverge.
    private struct PendingEntry {
        enum Kind {
            /// A `send(_:)` caller is suspended on this slot.
            case awaiting(CheckedContinuation<TmuxCommandResponse, Never>)
            /// A fire-and-forget command: its block is consumed and dropped.
            case discard
            /// A slot whose caller already gave up and was resumed with a
            /// timeout. Kept in place so the late response lands here instead
            /// of being handed to the next command.
            case abandoned
        }
        let id: UInt64
        var kind: Kind
    }

    /// A response that never arrives leaves its placeholder in the queue for
    /// good, and from then on it eats the *next* command's block — the same
    /// shift the placeholder exists to prevent, just deferred. Bound it: a
    /// connection that has lost this many responses is already being torn down
    /// by the poll watchdog, and `reset()` clears the rest.
    private static let maxAbandonedPlaceholders = 8

    private struct ResponseState {
        var pendingQueue: [PendingEntry] = []
        var currentBlock: CommandBlock?
        var nextEntryID: UInt64 = 0
        /// True once the current connection's greeting block has been consumed.
        /// `tmux -CC new-session/attach` emits one UNSOLICITED `%begin`/`%end`
        /// block (for the implicit command) before anything else. It must never
        /// be matched against `pendingQueue` — if a caller's send lands in the
        /// queue while the greeting is still in flight, the greeting's `%end`
        /// would steal that continuation and every later response would shift
        /// by one (timeout storm → spurious reconnect loop). Cleared by
        /// `reset()` so each new connection discards exactly one block.
        var greetingConsumed = false
        var controlModeWaiters: [PendingBoolEntry] = []
        /// True once ANY byte has arrived on this connection. Distinct from
        /// `greetingConsumed`: it only says the far end is alive and talking,
        /// which is what a caller needs before typing a launch line into what
        /// it hopes is a shell.
        var sawAnyOutput = false
        var outputWaiters: [PendingBoolEntry] = []
        /// Whatever arrived on this connection BEFORE control mode started.
        ///
        /// On a healthy connection this is empty or a scrap of shell echo, and
        /// nothing reads it. It matters when the greeting never comes, because
        /// then these lines are the entire explanation: `tmux: command not
        /// found` from a host that hasn't got tmux, `ssh: Could not resolve
        /// hostname`, a refused connection, a host-key complaint. They are not
        /// protocol, so the parser has always dropped them on the floor — and
        /// the resulting failure had nothing to say for itself.
        ///
        /// Bounded, because a login shell that never reaches tmux can print
        /// without limit (a chatty MOTD, a shell that drops to an interactive
        /// prompt); the diagnosis is in the first few lines either way.
        var preGreetingLines: [String] = []
    }

    /// Lines received before control mode started — see `preGreetingLines`.
    /// Empty once tmux has greeted, which is the normal case.
    public var outputBeforeControlMode: String {
        responseLock.withLock { $0.preGreetingLines.joined(separator: "\n") }
    }

    /// Cap on `preGreetingLines`, in lines and in characters per line.
    private static let maxPreGreetingLines = 12
    private static let maxPreGreetingLineLength = 200

    private struct PendingBoolEntry {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct CommandBlock {
        let commandNumber: Int
        var lines: [String] = []
    }

    // Line buffer for incoming data
    private let bufferLock = OSAllocatedUnfairLock(initialState: Data())

    // Input batching: leading-edge flush, then a 16ms window that coalesces
    // burst input (paste, key repeat). `windowOpen` is true between the
    // leading flush and the trailing flush.
    private struct InputBatchState {
        var buffers: [TmuxPaneID: Data] = [:]
        var windowOpen: [TmuxPaneID: Bool] = [:]
    }
    private let inputBatchLock = OSAllocatedUnfairLock(initialState: InputBatchState())

    // All input flushes go through one serial queue so per-pane byte order
    // is preserved between the leading and trailing flush.
    private let inputFlushQueue = DispatchQueue(label: "dev.swifttmux.input-flush", qos: .userInteractive)

    public init() {}

    private func log(_ message: @autoclosure @escaping () -> String) {
        if let logHandler {
            logHandler(message())
        } else {
            // Pass the closure through to OSLog's interpolation so the string
            // is only built when debug logging is actually enabled.
            logger.debug("\(message(), privacy: .public)")
        }
    }

    // MARK: - Public API

    /// Build the shell command that launches tmux in control-mode. Send the
    /// returned string over SSH to put the remote shell into `-CC` mode.
    ///
    /// `path` / `command` seed the session when `-A` has to CREATE it (they are
    /// ignored by tmux when it attaches to an existing one, which is the
    /// behavior you want — re-attaching must not relaunch the agent).
    ///
    /// Seeding here rather than by typing a `tmux new-session -d …` script into
    /// the shell beforehand is deliberate: that script raced the freshly spawned
    /// login shell's pty, and when it lost, `-c` was dropped silently and the
    /// agent came up in the wrong directory. This line is the same write we
    /// already had to make, so there is no second chance to lose.
    public func launchCommand(
        sessionName: String? = nil,
        groupWith: String? = nil,
        path: String? = nil,
        command: String? = nil
    ) -> String {
        Self.launchCommandLine(
            sessionName: sessionName, groupWith: groupWith,
            path: path, command: command) + "\n"
    }

    /// The same launch line WITHOUT the trailing newline, for callers that hand
    /// it to something other than a shell's stdin — notably `ssh -t <host>
    /// "<line>"`, where the command is an argument and a newline in it would be
    /// a second, empty command.
    ///
    /// One builder for both so the two can never drift: `tmux` stays a bare
    /// word, resolved by the PATH of whatever shell runs the line.
    ///
    /// That bare word is NOT sufficient on its own over ssh. This line reaching
    /// a shell with the user's PATH in it is the caller's job, and an ssh
    /// argument does not get one for free — see `remoteLaunchCommandLine`,
    /// which is what an ssh caller should be using.
    public static func launchCommandLine(
        sessionName: String? = nil,
        groupWith: String? = nil,
        path: String? = nil,
        command: String? = nil
    ) -> String {
        // The shell — not tmux — expands `~`, and this string is read by the
        // shell, so quote it for the shell (see TmuxShellQuote.path). Session
        // names too: a user-picked session name is legal with spaces, and
        // spliced bare it would word-split the line and break the launch.
        let dir = path.map { " -c \(TmuxShellQuote.path($0))" } ?? ""
        let prog = command.flatMap { $0.isEmpty ? nil : " \(TmuxShellQuote.arg($0))" } ?? ""
        if let groupWith {
            let name = sessionName ?? "\(groupWith)-mobile"
            // A grouped session shares the source's windows; seeding a
            // directory or program would be meaningless (and tmux rejects the
            // combination), so those are deliberately not applied here.
            return "tmux -CC new-session -A -s \(TmuxShellQuote.arg(name)) -t \(TmuxShellQuote.arg(groupWith))"
        } else if let sessionName {
            return "tmux -CC new-session -A -s \(TmuxShellQuote.arg(sessionName))\(dir)\(prog)"
        } else {
            return "tmux -CC new-session\(dir)\(prog)"
        }
    }

    /// The launch line as an argument for `ssh -t <host> "<line>"`: the same
    /// line, wrapped so the remote runs it through a login shell.
    ///
    /// Composed here rather than at the call site so an ssh caller cannot get
    /// the launch right and the shell wrong — which is exactly what happened,
    /// and presented as `command not found: tmux` on a Mac with tmux installed
    /// (Homebrew's `tmux` is on the PATH that `~/.zprofile` builds, and an ssh
    /// command never reads it). See `TmuxShellQuote.loginShell`.
    public static func remoteLaunchCommandLine(
        sessionName: String? = nil,
        groupWith: String? = nil,
        path: String? = nil,
        command: String? = nil
    ) -> String {
        TmuxShellQuote.loginShell(running: launchCommandLine(
            sessionName: sessionName, groupWith: groupWith,
            path: path, command: command))
    }

    /// Feed raw bytes from the SSH channel into the parser.
    public func feedData(_ data: Data) {
        bufferLock.withLock { buffer in
            buffer.append(data)
        }
        if !data.isEmpty {
            let waiters = responseLock.withLock { state -> [PendingBoolEntry] in
                guard !state.sawAnyOutput else { return [] }
                state.sawAnyOutput = true
                let w = state.outputWaiters
                state.outputWaiters.removeAll()
                return w
            }
            for waiter in waiters { waiter.continuation.resume(returning: true) }
        }
        processLines()
    }

    /// Wait until the far end has produced any output at all, or `timeout`.
    ///
    /// The caller that needs this is the one about to type `tmux -CC …` into a
    /// freshly opened shell: written before the shell exists, the line is
    /// swallowed by the pty and tmux never starts — and everything downstream
    /// then talks control-mode syntax at a bare prompt. Returns whether output
    /// was seen; a silent shell still gets the launch line, as before.
    public func awaitAnyOutput(timeout: Duration = .seconds(3)) async -> Bool {
        let id: UInt64 = responseLock.withLock { state in
            state.nextEntryID += 1
            return state.nextEntryID
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let alreadySeen = responseLock.withLock { state -> Bool in
                if state.sawAnyOutput { return true }
                state.outputWaiters.append(PendingBoolEntry(id: id, continuation: continuation))
                return false
            }
            if alreadySeen { continuation.resume(returning: true); return }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                let cont = self.responseLock.withLock { state -> CheckedContinuation<Bool, Never>? in
                    guard let idx = state.outputWaiters.firstIndex(where: { $0.id == id }) else { return nil }
                    return state.outputWaiters.remove(at: idx).continuation
                }
                cont?.resume(returning: false)
            }
        }
    }

    /// Send a tmux command and await the parsed response.
    ///
    /// `timeout` bounds the wait: if no response block arrives (dead
    /// connection, desynced stream), the call returns an `isError` response
    /// instead of suspending forever — an unbounded await here is what used to
    /// wedge the reconnect loop for good. Timing out does NOT remove the slot:
    /// it is marked `.abandoned` and left in place, so a merely-slow response
    /// is absorbed by its own slot rather than shifting every later match by
    /// one. (That shift used to be accepted on the theory that a >timeout
    /// response means the stream is already broken — which stops being true on
    /// a relayed link where a 900 ms RTT makes slow responses ordinary.)
    @discardableResult
    public func send(_ command: TmuxCommand, timeout: Duration = .seconds(10)) async -> TmuxCommandResponse {
        let id: UInt64 = responseLock.withLock { state in
            state.nextEntryID += 1
            return state.nextEntryID
        }
        return await withCheckedContinuation { continuation in
            let cmdString = command.commandString + "\n"
            log("tmux send: \(cmdString.trimmingCharacters(in: .whitespacesAndNewlines))")
            // Registration and the transport write happen under ONE lock:
            // response blocks are matched to registrations strictly FIFO, so
            // wire order and registration order must never diverge (two
            // concurrent senders interleaving append/write used to swap them).
            responseLock.withLock { state in
                state.pendingQueue.append(PendingEntry(id: id, kind: .awaiting(continuation)))
                sendToSSH?(cmdString)
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.timeOutPending(id: id)
            }
        }
    }

    private func timeOutPending(id: UInt64) {
        let (cont, dropped) = responseLock.withLock {
            state -> (CheckedContinuation<TmuxCommandResponse, Never>?, Int) in
            guard let idx = state.pendingQueue.firstIndex(where: { $0.id == id }),
                  case .awaiting(let c) = state.pendingQueue[idx].kind else { return (nil, 0) }
            state.pendingQueue[idx].kind = .abandoned

            // Safety valve, see `maxAbandonedPlaceholders`.
            var dropped = 0
            while state.pendingQueue.count(where: { if case .abandoned = $0.kind { true } else { false } })
                    > Self.maxAbandonedPlaceholders,
                  let oldest = state.pendingQueue.firstIndex(where: {
                      if case .abandoned = $0.kind { true } else { false }
                  }) {
                state.pendingQueue.remove(at: oldest)
                dropped += 1
            }
            return (c, dropped)
        }
        guard let cont else { return }
        if dropped > 0 {
            log("tmux dropped \(dropped) stale placeholder(s) — the stream is losing responses, not just slow")
        }
        log("tmux send timed out waiting for response (entry \(id))")
        cont.resume(returning: TmuxCommandResponse(commandNumber: -1, isError: true, output: "timeout: no response"))
    }

    /// Wait until the current connection's greeting block has fully arrived
    /// (`%begin`…`%end` consumed), or `timeout` passes. That is the earliest
    /// safe point to start sending commands: earlier, they'd either be typed
    /// into the plain shell (tmux not attached yet) or their continuation
    /// would be stolen by the greeting's `%end`. Replaces fixed post-launch
    /// sleeps: faster when the shell is quick, tolerant when it's slow
    /// (oh-my-zsh init etc.). Returns whether the greeting was seen.
    public func awaitControlMode(timeout: Duration = .seconds(10)) async -> Bool {
        let id: UInt64 = responseLock.withLock { state in
            state.nextEntryID += 1
            return state.nextEntryID
        }
        return await withCheckedContinuation { continuation in
            let alreadySeen = responseLock.withLock { state -> Bool in
                if state.greetingConsumed { return true }
                state.controlModeWaiters.append(PendingBoolEntry(id: id, continuation: continuation))
                return false
            }
            if alreadySeen {
                continuation.resume(returning: true)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                let cont = self.responseLock.withLock { state -> CheckedContinuation<Bool, Never>? in
                    guard let idx = state.controlModeWaiters.firstIndex(where: { $0.id == id }) else { return nil }
                    return state.controlModeWaiters.remove(at: idx).continuation
                }
                cont?.resume(returning: false)
            }
        }
    }

    /// Discard all connection-scoped parser state. Call whenever the byte
    /// stream restarts (transport reconnect). Two failure modes otherwise
    /// survive into the new connection:
    ///   1. A response block truncated by the drop (`%begin` seen, `%end`
    ///      lost) leaves `currentBlock` set, so every non-`%output`
    ///      notification of the new stream is swallowed as block content.
    ///      (`%output` itself takes the raw fast path and keeps flowing.)
    ///   2. Continuations queued by the dead connection consume the new
    ///      connection's response blocks FIFO — post-reconnect commands
    ///      starve or receive the wrong block, so `refreshPanes` rebuilds
    ///      pane view-models from garbage while surfaces stay bound to the
    ///      old instances: input still works, rendering is dead.
    public func reset() {
        bufferLock.withLock { $0.removeAll(keepingCapacity: false) }
        let (orphans, waiters, outputWaiters) = responseLock.withLock { state -> ([PendingEntry], [PendingBoolEntry], [PendingBoolEntry]) in
            let o = state.pendingQueue
            let w = state.controlModeWaiters
            let outW = state.outputWaiters
            state.pendingQueue.removeAll()
            state.controlModeWaiters.removeAll()
            state.currentBlock = nil
            state.greetingConsumed = false
            state.sawAnyOutput = false
            state.outputWaiters.removeAll()
            state.preGreetingLines.removeAll()
            return (o, w, outW)
        }
        if !orphans.isEmpty || !waiters.isEmpty {
            log("tmux parser reset: dropping \(orphans.count) pending command(s), \(waiters.count) waiter(s)")
        }
        // `.discard` and `.abandoned` slots have nobody waiting on them.
        for entry in orphans {
            guard case .awaiting(let cont) = entry.kind else { continue }
            cont.resume(returning: TmuxCommandResponse(commandNumber: -1, isError: true, output: "connection reset"))
        }
        for waiter in waiters {
            waiter.continuation.resume(returning: false)
        }
        for waiter in outputWaiters {
            waiter.continuation.resume(returning: false)
        }
    }

    /// Send a tmux command without waiting for response. The response arrives
    /// but is discarded — via a `.discard` slot in the same queue, so it can
    /// only ever consume its *own* block.
    ///
    /// This used to be a counter that `finishBlock` checked *before* the queue,
    /// which reversed the order whenever a fire-and-forget was issued while an
    /// awaited command was still in flight: the earlier command's block was
    /// dropped as if it belonged to the fire-and-forget, and its caller was
    /// handed the next one. On a LAN that window is a few milliseconds; on a
    /// relayed link it is a large fraction of the 2 s poll period, which is
    /// most of a user's taps.
    public func sendFireAndForget(_ command: TmuxCommand) {
        let cmdString = command.commandString + "\n"
        let sent = responseLock.withLock { state -> Bool in
            guard state.greetingConsumed else { return false }
            state.nextEntryID += 1
            state.pendingQueue.append(PendingEntry(id: state.nextEntryID, kind: .discard))
            sendToSSH?(cmdString)
            return true
        }
        if sent {
            log("tmux send (fire): \(cmdString.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            log("tmux dropped pre-greeting command: \(cmdString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Send raw bytes to a pane (for terminal input). Uses `send-keys -H`
    /// (hex mode) so any byte — including `\r`, `\n`, `\x1b` — survives
    /// without breaking the tmux protocol.
    ///
    /// Leading-edge flush: the first bytes of a burst go out immediately so
    /// interactive keystrokes pay no latency; bytes arriving within the next
    /// 16ms are coalesced into one trailing flush (paste, key repeat).
    public func sendData(to pane: TmuxPaneID, data: Data) {
        let opensWindow = inputBatchLock.withLock { state -> Bool in
            state.buffers[pane, default: Data()].append(data)
            if state.windowOpen[pane] == true {
                return false
            }
            state.windowOpen[pane] = true
            return true
        }

        guard opensWindow else { return }
        inputFlushQueue.async { [weak self] in
            self?.flushInputBuffer(for: pane, closeWindow: false)
        }
        inputFlushQueue.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
            self?.flushInputBuffer(for: pane, closeWindow: true)
        }
    }

    private func flushInputBuffer(for pane: TmuxPaneID, closeWindow: Bool) {
        let data = inputBatchLock.withLock { state -> Data? in
            if closeWindow {
                state.windowOpen[pane] = false
            }
            guard let buffer = state.buffers.removeValue(forKey: pane), !buffer.isEmpty else {
                return nil
            }
            return buffer
        }

        guard let data else { return }
        // Byte-table hex encoding (lowercase, 2 digits, space-separated):
        // avoids a String(format:) allocation per byte on the keystroke/paste
        // hot path.
        var hex = [UInt8]()
        hex.reserveCapacity(data.count * 3)
        for b in data {
            if !hex.isEmpty { hex.append(0x20) }
            hex.append(Self.hexDigits[Int(b >> 4)])
            hex.append(Self.hexDigits[Int(b & 0x0F)])
        }
        let cmd = "send-keys -t \(pane) -H \(String(decoding: hex, as: UTF8.self))\n"
        // send-keys gets a (empty) %begin/%end response like any command.
        // Sending it UNREGISTERED desynced the FIFO response matching: every
        // keystroke/focus-report flush donated an empty block to whichever
        // send() was pending — display-message callers (path-preview cwd,
        // duplicate-window seeds) mostly received ⟨⟩ instead of their output.
        // Dropped, not queued, until tmux has greeted. Between `usingTmux`
        // going true and the greeting arriving, this channel is still a plain
        // shell — a scroll fling here typed hundreds of `send-keys` lines at a
        // zsh prompt, each echoing `command not found` back into the parser.
        let sent = responseLock.withLock { state -> Bool in
            guard state.greetingConsumed else { return false }
            state.nextEntryID += 1
            state.pendingQueue.append(PendingEntry(id: state.nextEntryID, kind: .discard))
            sendToSSH?(cmd)
            return true
        }
        if !sent { log("tmux dropped pre-greeting pane input (\(data.count) bytes)") }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    // MARK: - Line Processing

    private static let outputPrefix = Array("%output ".utf8) // 8 bytes
    private static let newlineByte: UInt8 = 0x0A
    private static let crByte: UInt8 = 0x0D
    private static let spaceByte: UInt8 = 0x20

    /// Control-mode notifications that are valid at ANY point in the stream —
    /// including interleaved inside another command's `%begin`…`%end` block.
    /// tmux emits these out-of-band (most visibly the repaint / `%layout-change`
    /// burst that follows `select-window`), so they must be dispatched rather
    /// than folded into the command's output. Excludes `%begin`/`%end`/`%error`
    /// (block framing) and `%output` (raw fast path in `handleLine`); the string
    /// `%output ` is kept so a fallback string-path output still routes out.
    private static let notificationPrefixes = [
        "%output ", "%layout-change ", "%window-add ", "%window-close ",
        "%window-renamed ", "%window-pane-changed", "%unlinked-window-add",
        "%unlinked-window-close", "%session-changed ", "%session-renamed ",
        "%sessions-changed", "%pane-mode-changed ", "%client-session-changed",
        "%client-detached ", "%config-error", "%exit",
        "%paste-buffer-changed ", "%paste-buffer-deleted ",
    ]

    /// Recognised `%` markers used to realign a line that arrives with
    /// leading junk (stray DCS / shell echo) outside a block.
    private static let realignPrefixes = ["%begin ", "%output ", "%end ", "%error ",
                                          "%session", "%layout-change ", "%window-", "%pane-",
                                          "%exit", "%unlinked-", "%client-", "%config-",
                                          "%paste-buffer-"]

    private func isOutOfBandNotification(_ line: String) -> Bool {
        for prefix in Self.notificationPrefixes where line.hasPrefix(prefix) { return true }
        return false
    }

    /// Whether `line` is the `%end`/`%error` that closes the block numbered
    /// `commandNumber` — matched on the NUMBER tmux echoes back
    /// (`%end <timestamp> <number> <flags>`), not merely on the prefix.
    ///
    /// The prefix alone is not enough, because a command's own output can
    /// legitimately contain a line that starts with `%end `: `show-buffer` of a
    /// pasted transcript, or `capture-pane` of a pane that has tmux protocol on
    /// screen. Closing on that truncates the response AND leaves the real `%end`
    /// to arrive with no block open — which then consumes the NEXT command's
    /// pending queue entry and shifts every later response by one. That FIFO
    /// skew is the ancestor of a whole family of "impossible" bugs (a
    /// display-message caller receiving another command's text), so the frame is
    /// matched exactly rather than guessed.
    private static func closesBlock(_ line: String, commandNumber: Int) -> Bool {
        guard line.hasPrefix("%end ") || line.hasPrefix("%error ") else { return false }
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        // Malformed framing (no number) still closes: an unclosed block would
        // hang every caller behind it, which is worse than a truncated one.
        guard parts.count >= 3, let num = Int(parts[2]) else { return true }
        return num == commandNumber
    }

    /// Markers used to realign a notification that arrived INSIDE a block behind a
    /// leading escape/control junk prefix. Deliberately TIGHTER than
    /// `realignPrefixes` — each carries its structural sigil (`%output %`, window
    /// `@` / session `$` ids, or a trailing space) so a captured screen line that
    /// merely contains e.g. the text "%output" is not mistaken for protocol.
    private static let inBlockRealignMarkers = [
        "%output %", "%begin ", "%end ", "%error ", "%layout-change ",
        "%window-add @", "%window-close @", "%window-renamed @",
        "%window-pane-changed @", "%unlinked-window-add @", "%unlinked-window-close @",
        "%session-changed $", "%session-renamed $", "%sessions-changed",
        "%pane-mode-changed %", "%client-session-changed ", "%client-detached ",
        "%config-error ", "%exit",
        "%paste-buffer-changed ", "%paste-buffer-deleted ",
    ]

    /// If `line` begins with a NON-PRINTABLE escape/control byte — stray DCS/CSI
    /// residue that transport framing can splice onto a control-mode notification
    /// (the "tmux -CC chatter in the pane" on a session switch, BUG-007) — and a
    /// recognised protocol marker follows that junk, return the line realigned to
    /// the marker; otherwise nil. The non-printable-first-byte anchor is the whole
    /// point: genuine captured content starts with a printable glyph, so a
    /// captured line that merely CONTAINS "%end " as a substring is never realigned
    /// (and so never truncates the response — the trap the outside-block realign
    /// avoids by staying outside blocks).
    private static func realignJunkPrefixed(_ line: String) -> String? {
        guard let first = line.unicodeScalars.first,
              first.value < 0x20 || first.value == 0x7f else { return nil }
        guard let range = inBlockRealignMarkers.lazy.compactMap({ line.range(of: $0) }).first,
              range.lowerBound != line.startIndex else { return nil }
        return String(line[range.lowerBound...])
    }

    private func processLines() {
        // Take the lock once: extract everything up to the last complete line
        // and scan it locally, instead of a lock + Data slice per line.
        let block: Data? = bufferLock.withLock { (buffer: inout Data) -> Data? in
            guard let lastNewline = buffer.lastIndex(of: Self.newlineByte) else {
                return nil
            }
            let complete = Data(buffer[buffer.startIndex...lastNewline])
            if lastNewline == buffer.index(before: buffer.endIndex) {
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer = Data(buffer[(lastNewline + 1)...])
            }
            return complete
        }
        guard let block else { return }

        // Find all newline offsets in one unsafe-bytes pass (memchr), then
        // hand out one subdata per line.
        var lineRanges: [Range<Int>] = []
        block.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var start = 0
            while start < count {
                guard let found = memchr(base + start, Int32(Self.newlineByte), count - start) else { break }
                var end = UnsafeRawPointer(found) - base
                if end > start, base.load(fromByteOffset: end - 1, as: UInt8.self) == Self.crByte {
                    lineRanges.append(start..<(end - 1))
                } else {
                    lineRanges.append(start..<end)
                }
                end += 1
                start = end
            }
        }

        for range in lineRanges {
            // Zero-copy slice: `block` is freshly built (startIndex == 0) so
            // the memchr offsets are valid Data indices. Downstream never
            // retains the slice (String(data:)/Data(...) copy), so the block's
            // storage is released after the loop.
            handleLine(block[range])
        }
    }

    private func handleLine(_ lineData: Data) {
        // Fast path: %output uses raw-byte parsing to preserve multi-byte
        // UTF-8 sequences. String round-trips would mangle box-drawing
        // characters and other non-ASCII output.
        if lineData.count > 8, lineData.starts(with: Self.outputPrefix) {
            parseOutputRaw(lineData)
            return
        }

        let line: String
        if let str = String(data: lineData, encoding: .utf8) {
            line = str
        } else {
            line = String(data: lineData, encoding: .isoLatin1) ?? ""
        }

        // Inside a command's `%begin`…`%end` block, tmux can still interleave
        // out-of-band notifications — most visibly the repaint / `%layout-change`
        // burst that follows `select-window`. They are NOT part of the command's
        // output: folding them into the block corrupts the response, so
        // `capture-pane` seeds a ghostty surface with raw protocol text (the
        // "tmux -CC chatter in the pane" on a window switch) and
        // list-panes/list-windows silently drop lines. Route those out-of-band;
        // keep only genuine output in the block. Match on the RAW line — the
        // leading-junk realignment below must not run inside a block, or a
        // captured line that merely CONTAINS "%end " as a substring would
        // truncate the response early.
        if let open = responseLock.withLock({ $0.currentBlock?.commandNumber }) {
            if Self.closesBlock(line, commandNumber: open) {
                finishBlock(line: line, isError: line.hasPrefix("%error"))
            } else if isOutOfBandNotification(line) {
                parseLine(line)
            } else if let realigned = Self.realignJunkPrefixed(line) {
                // A notification arrived inside the block behind an escape/control
                // junk prefix, so the strict checks above missed it. Route its
                // clean form the same way — instead of folding raw protocol text
                // into the response (BUG-007). A stray framing marker we can't
                // re-inject (e.g. a bare %begin from a lost %end) is dropped rather
                // than painted; the eventual %end still closes this block.
                if Self.closesBlock(realigned, commandNumber: open) {
                    finishBlock(line: realigned, isError: realigned.hasPrefix("%error"))
                } else if isOutOfBandNotification(realigned) {
                    parseLine(realigned)
                }
            } else {
                responseLock.withLock { state in state.currentBlock?.lines.append(line) }
            }
            return
        }

        // Outside a block: a stray DCS / shell echo can prefix a real
        // notification; realign to the first recognised `%` marker before dispatch.
        var cleaned = line
        if let range = Self.realignPrefixes.lazy.compactMap({ cleaned.range(of: $0) }).first {
            if range.lowerBound != cleaned.startIndex {
                cleaned = String(cleaned[range.lowerBound...])
            }
        }

        recordIfBeforeControlMode(cleaned)
        parseLine(cleaned)
    }

    /// Keep non-protocol lines that arrive before the greeting, so a connection
    /// that never reaches control mode can say why. See `preGreetingLines`.
    private func recordIfBeforeControlMode(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // A `%` line is protocol, not diagnosis, even out here.
        guard !text.isEmpty, !text.hasPrefix("%") else { return }
        responseLock.withLock { state in
            guard !state.greetingConsumed,
                  state.preGreetingLines.count < Self.maxPreGreetingLines else { return }
            state.preGreetingLines.append(String(text.prefix(Self.maxPreGreetingLineLength)))
        }
    }

    /// Parse `%output` directly from raw bytes, preserving UTF-8 integrity.
    /// Format: `%output %<id> <escaped_data>`.
    private func parseOutputRaw(_ lineData: Data) {
        let afterPrefix = lineData.dropFirst(8)
        guard let spaceIndex = afterPrefix.firstIndex(of: Self.spaceByte) else { return }
        let paneBytes = afterPrefix[afterPrefix.startIndex..<spaceIndex]
        guard let paneStr = String(data: paneBytes, encoding: .ascii),
              let paneID = TmuxPaneID(string: paneStr) else { return }

        // Slice, not copy: unescapeTmuxOutputBytes reads via withUnsafeBytes
        // (never Data indices) and returns a fresh Data, so a non-zero
        // startIndex is safe and nothing retains the slice.
        let unescaped = unescapeTmuxOutputBytes(afterPrefix[(spaceIndex + 1)...])
        onNotification?(.output(pane: paneID, data: unescaped))
    }

    /// Unescape tmux output working directly on raw bytes. tmux escapes
    /// bytes < 32 and backslash as `\XXX` (three octal digits).
    ///
    /// Single unsafe-bytes pass: spans between backslashes are bulk-copied
    /// (memchr + buffer append) instead of byte-at-a-time `Data.append`,
    /// which dominated the main-thread profile under heavy TUI output.
    private func unescapeTmuxOutputBytes(_ input: Data) -> Data {
        let backslash: UInt8 = 0x5C // '\'
        let asciiZero: UInt8 = 0x30 // '0'

        return input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            guard let rawBase = raw.baseAddress else { return Data() }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            let count = raw.count
            var out = [UInt8]()
            out.reserveCapacity(count)
            var i = 0

            while i < count {
                // Bulk-copy the run of literal bytes up to the next backslash.
                let next: Int
                if let found = memchr(base + i, Int32(backslash), count - i) {
                    next = UnsafeRawPointer(found) - rawBase
                } else {
                    next = count
                }
                if next > i {
                    out.append(contentsOf: UnsafeBufferPointer(start: base + i, count: next - i))
                    i = next
                }
                guard i < count else { break }

                // base[i] is a backslash; decode `\XXX` if three octal digits follow.
                if i + 3 < count {
                    let d0 = base[i + 1]
                    let d1 = base[i + 2]
                    let d2 = base[i + 3]
                    if d0 >= asciiZero, d0 <= asciiZero + 7,
                       d1 >= asciiZero, d1 <= asciiZero + 7,
                       d2 >= asciiZero, d2 <= asciiZero + 7 {
                        out.append((d0 - asciiZero) &* 64 &+ (d1 - asciiZero) &* 8 &+ (d2 - asciiZero))
                        i += 4
                        continue
                    }
                }
                out.append(backslash)
                i += 1
            }
            return Data(out)
        }
    }

    /// Dispatch a single control-mode line as a notification / block frame.
    /// Block accumulation (and routing out-of-band notifications past an
    /// in-flight block) is handled upstream in `handleLine`.
    private func parseLine(_ line: String) {
        // %output first and unlogged (it never was); everything else logs
        // before dispatch, as before.
        if line.hasPrefix("%output ") {
            parseOutput(line)
            return
        }

        log("tmux recv: \(line)")

        if line.hasPrefix("%begin ") {
            parseBegin(line)
        } else if line.hasPrefix("%layout-change ") {
            parseLayoutChange(line)
        } else if line.hasPrefix("%window-add ") {
            parseWindowAdd(line)
        } else if line.hasPrefix("%window-close ") {
            parseWindowClose(line)
        } else if line.hasPrefix("%window-renamed ") {
            parseWindowRenamed(line)
        } else if line.hasPrefix("%session-changed ") {
            parseSessionChanged(line)
        } else if line.hasPrefix("%session-renamed ") {
            parseSessionRenamed(line)
        } else if line.hasPrefix("%pane-mode-changed ") {
            parsePaneModeChanged(line)
        } else if line.hasPrefix("%paste-buffer-changed ") {
            let name = String(line.dropFirst("%paste-buffer-changed ".count))
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { onNotification?(.pasteBufferChanged(name: name)) }
        } else if line.hasPrefix("%client-detached ") {
            let client = String(line.dropFirst("%client-detached ".count))
                .trimmingCharacters(in: .whitespaces)
            if !client.isEmpty { onNotification?(.clientDetached(client: client)) }
        } else if line.hasPrefix("%exit") {
            let reason = line.count > 5 ? String(line.dropFirst(6)) : nil
            onNotification?(.exit(reason: reason))
        } else if line.hasPrefix("%paste-buffer-deleted") ||
                  line.hasPrefix("%sessions-changed") ||
                  line.hasPrefix("%unlinked-window-add") ||
                  line.hasPrefix("%unlinked-window-close") ||
                  line.hasPrefix("%window-pane-changed") ||
                  line.hasPrefix("%client-session-changed") ||
                  line.hasPrefix("%config-error") {
            log("tmux ignored notification: \(line.prefix(60))")
        } else {
            // Ignore unrecognized lines (e.g. DCS sequences, echo)
        }
    }

    // MARK: - Notification Parsers

    private func parseOutput(_ line: String) {
        let rest = String(line.dropFirst(8))
        guard let spaceIdx = rest.firstIndex(of: " ") else { return }
        let paneStr = String(rest[rest.startIndex..<spaceIdx])
        let escapedData = String(rest[rest.index(after: spaceIdx)...])

        guard let paneID = TmuxPaneID(string: paneStr) else { return }
        let data = unescapeTmuxOutput(escapedData)
        onNotification?(.output(pane: paneID, data: data))
    }

    private func parseBegin(_ line: String) {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, let cmdNum = Int(parts[2]) else {
            log("Invalid %begin: \(line)")
            return
        }
        responseLock.withLock { state in
            state.currentBlock = CommandBlock(commandNumber: cmdNum)
        }
    }

    private func finishBlock(line: String, isError: Bool) {
        let (block, continuation, waiters) = responseLock.withLock { state -> (CommandBlock?, CheckedContinuation<TmuxCommandResponse, Never>?, [PendingBoolEntry]) in
            guard let block = state.currentBlock else { return (nil, nil, []) }
            state.currentBlock = nil

            // The first block of a connection is the -CC greeting (tmux's
            // response to the implicit new-session/attach command, which no
            // send() issued). Consume it without touching the pending queue —
            // matching it FIFO would hand its (empty) output to the first real
            // caller and shift every later response by one. Its completion is
            // also the "control mode is ready" signal awaitControlMode waits on.
            if !state.greetingConsumed {
                state.greetingConsumed = true
                let w = state.controlModeWaiters
                state.controlModeWaiters.removeAll()
                return (nil, nil, w)
            }

            guard !state.pendingQueue.isEmpty else { return (block, nil, []) }
            switch state.pendingQueue.removeFirst().kind {
            case .awaiting(let cont): return (block, cont, [])
            // Fire-and-forget, or a caller that already timed out: consume the
            // block so it cannot shift the next command's match, and drop it.
            case .discard, .abandoned: return (block, nil, [])
            }
        }

        for waiter in waiters {
            waiter.continuation.resume(returning: true)
        }

        guard let block else { return }

        let response = TmuxCommandResponse(
            commandNumber: block.commandNumber,
            isError: isError,
            output: block.lines.joined(separator: "\n")
        )

        log("tmux response #\(block.commandNumber) (error=\(isError)): \(response.output.prefix(200))")

        if let continuation {
            continuation.resume(returning: response)
        }
    }

    private func parseLayoutChange(_ line: String) {
        let parts = line.split(separator: " ")
        guard parts.count >= 3,
              let winID = TmuxWindowID(string: String(parts[1])) else { return }
        let layout = String(parts[2])
        onNotification?(.layoutChange(window: winID, layout: layout))
    }

    private func parseWindowAdd(_ line: String) {
        let parts = line.split(separator: " ")
        guard parts.count >= 2,
              let winID = TmuxWindowID(string: String(parts[1])) else { return }
        onNotification?(.windowAdd(window: winID))
    }

    private func parseWindowClose(_ line: String) {
        let parts = line.split(separator: " ")
        guard parts.count >= 2,
              let winID = TmuxWindowID(string: String(parts[1])) else { return }
        onNotification?(.windowClose(window: winID))
    }

    private func parseWindowRenamed(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 3,
              let winID = TmuxWindowID(string: String(parts[1])) else { return }
        let name = String(parts[2])
        onNotification?(.windowRenamed(window: winID, name: name))
    }

    private func parseSessionChanged(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 3,
              let sesID = TmuxSessionID(string: String(parts[1])) else { return }
        let name = String(parts[2])
        onNotification?(.sessionChanged(session: sesID, name: name))
    }

    private func parseSessionRenamed(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 3 else { return }
        let name = String(parts[2])
        onNotification?(.sessionRenamed(name: name))
    }

    private func parsePaneModeChanged(_ line: String) {
        let parts = line.split(separator: " ")
        guard parts.count >= 2,
              let paneID = TmuxPaneID(string: String(parts[1])) else { return }
        let mode = parts.count >= 3 ? String(parts[2]) : ""
        onNotification?(.paneModeChanged(pane: paneID, mode: mode))
    }

    // MARK: - Output Unescaping (string path)

    private func unescapeTmuxOutput(_ escaped: String) -> Data {
        let backslash = UInt8(ascii: "\\")
        let zero = UInt8(ascii: "0")

        return escaped.utf8.withContiguousStorageIfAvailable { buf -> Data in
            unescapeBytes(buf, backslash: backslash, asciiZero: zero)
        } ?? {
            let bytes = Array(escaped.utf8)
            return bytes.withUnsafeBufferPointer { buf in
                unescapeBytes(buf, backslash: backslash, asciiZero: zero)
            }
        }()
    }

    private func unescapeBytes(_ buf: UnsafeBufferPointer<UInt8>, backslash: UInt8, asciiZero: UInt8) -> Data {
        var result = Data(capacity: buf.count)
        var i = 0
        let count = buf.count

        while i < count {
            let byte = buf[i]
            if byte == backslash, i + 3 < count {
                let d0 = buf[i + 1]
                let d1 = buf[i + 2]
                let d2 = buf[i + 3]
                if d0 >= asciiZero, d0 <= asciiZero + 7,
                   d1 >= asciiZero, d1 <= asciiZero + 7,
                   d2 >= asciiZero, d2 <= asciiZero + 7 {
                    let value = (d0 - asciiZero) &* 64 + (d1 - asciiZero) &* 8 + (d2 - asciiZero)
                    result.append(value)
                    i += 4
                    continue
                }
            }
            result.append(byte)
            i += 1
        }

        return result
    }
}
