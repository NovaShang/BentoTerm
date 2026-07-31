import Foundation
import SwiftUI
import os
import SwiftTmux

private let log = Logger(subsystem: "com.novashang.bento", category: "TerminalVM")

/// Optional file sink for the core package's `dlog`. Core logs default to
/// os_log only, which is invisible in the app's pullable `debug.log` — set
/// this once at app start (before any terminal work) to mirror every core
/// log line into the host app's file logger so real-device incidents can be
/// diagnosed from a single file pull.
public nonisolated(unsafe) var coreDlogFileSink: (@Sendable (String) -> Void)?

/// Package-local debug log (the app's global `dlog` lives in the iOS target).
func dlog(_ s: String) {
    log.debug("\(s, privacy: .public)")
    coreDlogFileSink?(s)
}

// File diagnostics ordering surface-lifecycle vs seed-feed events (os_log
// debug doesn't reliably reach `log show`). Off by default; opt in per-run
// with BENTO_DIAG=1 to trace to /tmp/bento-diag.log.
let _diagEnabled = ProcessInfo.processInfo.environment["BENTO_DIAG"] == "1"
let _diagLock = NSLock()
func DIAG(_ s: @autoclosure () -> String) {
    guard _diagEnabled else { return }
    _diagLock.lock(); defer { _diagLock.unlock() }
    let line = String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, s())
    let url = URL(fileURLWithPath: "/tmp/bento-diag.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.data(using: .utf8)?.write(to: url)
    }
}

/// User's choice for how to start a session on the host.
public enum TmuxStartChoice: Hashable {
    /// Don't use tmux — plain shell.
    case noTmux
    /// Create or attach to a session by name (no grouping).
    case createOrAttach(name: String)
    /// Create a grouped session that mirrors `target` (shared with desktop).
    case shareWithDesktop(target: String)
    /// Spin up a detached tmux session matching `spec` (working dir, agent
    /// command, layout), then attach in control mode.
    case createAgent(spec: AgentSpec)
}

/// High-level session phase. Distinct from low-level SSH state.
public enum SessionPhase: Equatable {
    case sshConnecting       // SSH handshake in progress
    case choosingSession     // SSH up; user picking tmux mode
    case starting            // applying choice (e.g. running tmux -CC)
    case shellReady          // non-tmux: plain shell live
    case tmuxReady           // tmux multiplexer live
    case suspended           // app backgrounded; SSH may be dead, tmux still alive on server
    case ended
}

@MainActor
public final class TerminalViewModel: ObservableObject {
    @Published public var connectionState: TerminalConnectionState = .disconnected
    @Published public var errorMessage: String?
    @Published public var showError = false
    /// True while an auto-reconnect loop is in flight (after a drop, or on
    /// foreground resume). Drives a "Reconnecting…" banner so the UI is never
    /// silently frozen — distinct from `phase`, which churns through
    /// `.sshConnecting`/`.starting` during each attempt.
    @Published public var isReconnecting = false
    @Published public var paneViewModels: [PaneViewModel] = []
    @Published public var activePaneID: TmuxPaneID?
    /// The currently zoomed pane (tmux `window_zoomed_flag`), or nil. When set,
    /// the tiled host shows only this pane filling the window.
    @Published public var zoomedPaneID: TmuxPaneID?
    @Published public var windows: [TmuxWindow] = []
    /// Every pane in the session across ALL windows (session-wide `list-panes
    /// -s`), refreshed together with `paneViewModels`. Powers the hierarchical
    /// structure model: window list items, per-window agent status, and the
    /// spread/merge structure ops. `paneViewModels` stays scoped to the current
    /// window (only its panes have live surfaces).
    @Published public private(set) var sessionPanes: [Pane] = []
    /// The user-facing "Tiled | List" state, recomputed from structure on
    /// every pane refresh. Degenerate (1×1) sessions present as Tiled unless
    /// the user explicitly chose List (`@bento_mode`); mixed external
    /// structures read as Tiled. See TerminalViewModel+Structure.swift.
    @Published public internal(set) var sessionMode: TmuxSessionMode = .tiled
    /// The user's last explicit mode choice, mirrored from the session's
    /// `@bento_mode` tmux option (server-side, shared by all devices).
    var savedModePreference: TmuxSessionMode?
    /// One-shot latch for the initial `@bento_mode` read.
    var modePreferenceLoaded = false
    /// The session's current window (drives the active tab highlight).
    @Published public var activeWindowID: TmuxWindowID?
    /// Who governs the tmux window's size (see `TerminalSizingMode`). Held on
    /// the SERVER (`window-size`) and adopted on attach by `adoptSizingPolicy`,
    /// so two devices sharing a session agree instead of overwriting each other.
    @Published public var sizingMode: TerminalSizingMode = .tracking
    /// The device owning a `.thisDevice` session's size, nil under the
    /// client-derived policies. Non-nil and not us = this device must not push
    /// a size at all.
    @Published public var sizingOwner: TmuxSizingOwner?
    /// This client's tmux client name (its tty), re-read on every attach — tmux
    /// hands out a new one each time, which is why ownership is re-claimed
    /// rather than remembered.
    var myTmuxClientName: String?
    /// The last grid this device measured for itself, recorded even when the
    /// policy forbids pushing it. Claiming ownership later has to resize the
    /// window to OUR size, and on macOS `idealTerminalSize` is a placeholder —
    /// the real grid only ever arrives through `resizeTmuxClient`.
    var lastTmuxClientSize: (cols: Int, rows: Int)?

    /// Whether THIS device is the one that claimed the size. Survives app
    /// restarts (per session) so the owner can re-claim under its new client
    /// name after a reconnect instead of losing the session to whoever
    /// attaches next.
    var claimedSizeOwnership: Bool {
        get {
            guard let session = activeTmuxSessionName else { return false }
            return UserDefaults.standard.bool(forKey: "sizingOwner.\(session)")
        }
        set {
            guard let session = activeTmuxSessionName else { return }
            UserDefaults.standard.set(newValue, forKey: "sizingOwner.\(session)")
        }
    }

    /// True when this device is the size owner. Under `.thisDevice` every other
    /// device is a passenger: tmux's `manual` already ignores their
    /// `refresh-client`, and we don't even send it.
    public var sizingOwnerIsMe: Bool {
        guard let owner = sizingOwner, let me = myTmuxClientName else { return false }
        return owner.client == me
    }
    @Published public var isTmuxReady = false

    /// Where we are in the session lifecycle.
    @Published public var phase: SessionPhase = .sshConnecting

    /// Sessions discovered via `tmux ls` after SSH is up.
    @Published public var availableTmuxSessions: [String] = []
    @Published public var sessionsLoading: Bool = false

    /// Bumped every time `availableTmuxSessions` is re-read from the attached
    /// tmux server over the CONTROL CHANNEL — i.e. once per answered
    /// `list-sessions`, from the server this connection is actually on.
    ///
    /// This is what tells a window whether its own session still exists.
    /// Previously that answer came from a global `tmux ls` poll of the LOCAL
    /// machine, pushed into every window: correct only as long as every window
    /// was local, and silently fatal once one wasn't — a remote session is
    /// never in the local list, so its window counted four straight misses and
    /// closed itself after about twenty seconds. Counting *this* list makes
    /// remote and local the same case instead of two.
    @Published public private(set) var sessionListGeneration: Int = 0

    /// Incremented on each state poll cycle to trigger SwiftUI re-render
    @Published public var stateVersion: Int = 0

    /// Per-pane state for EVERY pane in the session (all windows), computed by
    /// the one detection pipeline in `updatePaneStates`. Current-window panes
    /// mirror their PaneViewModel's `paneState`; background-window panes are
    /// classified the same way (control mode streams their output and titles).
    /// This is what `windowState` aggregates, so the List sidebar/tabs judge a
    /// window exactly like the Tiled pane chrome judges a pane. Repaints ride
    /// `stateVersion`.
    var paneStates: [TmuxPaneID: PaneState] = [:]

    /// Session-wide "done, unseen" flag per pane (an agent that finished its
    /// turn while its window was unfocused → the blue "done" check). Mirrors
    /// `PaneViewModel.agentFinishedUnseen` for the current window's live panes
    /// and extends the same rule to background-window panes, so the List sidebar
    /// can flag a window you're not looking at. Filled by `updatePaneStates`.
    var paneDoneUnseen: [TmuxPaneID: Bool] = [:]

    /// Live agent activity across the current window's panes — drives the macOS
    /// toolbar's center summary ("N working · M waiting"). Counts only recognized
    /// coding-agent panes (claude/codex/…), not plain shells. (tmux -CC streams
    /// the active window only, so background windows aren't included yet.)
    @Published public var agentsWorking: Int = 0
    @Published public var agentsWaiting: Int = 0
    /// Agent panes that finished their turn while unfocused (the "done, unseen"
    /// blue state) — drives the session tab's blue status dot.
    @Published public var agentsDoneUnseen: Int = 0

    public let host: Host
    let transport: TerminalTransport
    /// The live transport, exposed for app-level features that need
    /// transport-specific capabilities (path-preview's file fetch picks its
    /// source off the concrete SSH client, which can open an SFTP channel;
    /// a local pty cannot). Core stays agnostic.
    public var activeTransport: TerminalTransport { transport }
    let tmuxService = TmuxControlMode()
    public let stateDetection = StateDetectionService()
    let environment: TerminalEnvironment

    /// For non-tmux fallback: direct terminal data callback. Setting this
    /// replays the full history buffer so a re-bound TerminalView repaints
    /// scrollback instead of showing an empty screen until the next byte.
    public nonisolated(unsafe) var onRawDataReceived: (@Sendable (Data) -> Void)? {
        didSet {
            guard let onRawDataReceived, !rawHistory.isEmpty else { return }
            onRawDataReceived(rawHistory)
        }
    }

    /// Rolling buffer of raw shell bytes (non-tmux mode). Capped. Marked
    /// nonisolated(unsafe) so the `onRawDataReceived` didSet (also
    /// nonisolated) can read it — all real access happens on MainActor.
    nonisolated(unsafe) private var rawHistory = Data()
    private static let maxRawHistoryBytes = 256 * 1024

    /// Push predicted keystrokes (Mosh-style local echo) to the surface as a
    /// preedit overlay. Set by the host wiring (raw/no-tmux path only) to the
    /// active surface's `setPredictedText`. See `predictor`.
    public var onPredictionText: ((String) -> Void)?

    /// Predictive local echo for the raw path. Inert unless the feature flag is
    /// on; only ever touches an overlay, never the authoritative grid.
    private lazy var predictor: PredictiveEcho = {
        let p = PredictiveEcho(enabled: Self.predictiveEchoEnabled)
        p.render = { [weak self] text in self?.onPredictionText?(text) }
        return p
    }()

    /// Feature flag (Settings / UserDefaults). Off unless explicitly enabled.
    public nonisolated static var predictiveEchoEnabled: Bool {
        UserDefaults.standard.bool(forKey: "predictive_echo_enabled")
    }

    /// Whether we're using tmux control mode
    nonisolated(unsafe) private(set) var usingTmux = false

    /// Active tmux session name (used for kill-session etc).
    @Published public private(set) var activeTmuxSessionName: String?

    /// Shell-output capture state (for `tmux ls` and similar commands run in
    /// raw shell mode before we hand off to either the terminal or tmux -CC).
    private struct ShellCapture {
        var buffer: Data = Data()
        var marker: String
        var continuation: CheckedContinuation<String, Never>
    }
    private var shellCapture: ShellCapture? {
        // Mirrored into a lock so the off-main router can consult it without
        // hopping to the main actor just to read one optional.
        didSet {
            let active = shellCapture != nil
            captureActive.withLock { $0 = active }
        }
    }
    private nonisolated let captureActive = OSAllocatedUnfairLock(initialState: false)

    /// True while we're waiting on a scheduled auto-reconnect attempt. The
    /// onStateChanged hook checks this so an in-flight retry's transient
    /// `.failed` doesn't get treated as a fresh failure (and spawn nested
    /// reconnect tasks).
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    /// The surface's last reported grid (cols, rows). Used to start the shell at
    /// the rendered size so the remote PTY width always matches the surface.
    private var lastReportedSize: (cols: Int, rows: Int)?
    /// Set true by `disconnect()` / host deletion so we don't try to revive
    /// a session the user explicitly tore down.
    private var userInitiatedDisconnect = false
    /// True while the app is backgrounded (or transitioning there). Used to
    /// suppress error alerts and reconnect attempts that would otherwise
    /// surface when iOS suspends the process and tears down the WS — those
    /// failures are expected and handled by `resumeFromBackground`.
    private var isInBackground = false
    /// The live phase (`.tmuxReady`/`.shellReady`) captured when the session
    /// was suspended. If the transport survives the suspension (probed on
    /// resume), the phase is restored directly — no reconnect.
    private var phaseBeforeSuspend: SessionPhase?
    /// Consecutive state-poll commands that timed out with no response.
    /// A transport can be half-dead in ways no layer reports: the WS answers
    /// pings but the remote shell is gone, so tmux never replies while the
    /// screen sits frozen and "connected". Two straight timeouts (~25s) is
    /// the universal tripwire — it works over any transport.
    private var commandTimeoutStreak = 0
    /// Set when the transport reports `.failed` DURING a reconnect attempt.
    /// `handleUnexpectedFailure` can't act on those (a reconnect already owns
    /// recovery), but silently dropping them let a dead attempt report success:
    /// the seed burst at the end of `reattachExistingSession` is where the
    /// SSH channel actually died on the iPad, and because `isReconnecting` was
    /// still true nobody noticed until the poll watchdog fired ~48s later — then
    /// the next attempt died the same way, forever. The attempt now reads this
    /// flag and retries instead.
    private var failedDuringReattach = false

    private var layoutChangeDebounce: Task<Void, Never>?
    /// Retry for a raced `list-windows` parse (see `refreshWindows`).
    private var windowsRefreshRetry: Task<Void, Never>?
    private var statePollingTask: Task<Void, Never>?

    public init(host: Host, transport: TerminalTransport, environment: TerminalEnvironment) {
        self.host = host
        self.transport = transport
        self.environment = environment
        tmuxService.logHandler = { dlog($0) }
        setupCallbacks()
    }

    /// tmux control-mode parsing (line splitting, %output unescaping) runs
    /// here, off the main actor, so heavy TUI output cannot delay keyDown
    /// handling. Serial → preserves byte order.
    private nonisolated let tmuxParseQueue = DispatchQueue(label: "com.novashang.bento.tmux-parse", qos: .userInitiated)

    /// Notifications parsed off-main are queued here and drained on the main
    /// actor in one hop, preserving total order (a %layout-change must stay
    /// ordered against the %output repaint that follows it) while coalescing
    /// bursts that would otherwise each pay their own main-actor hop.
    private struct PendingTmuxNotifications {
        var queue: [TmuxNotification] = []
        var drainScheduled = false
    }
    private nonisolated let pendingTmuxNotifications = OSAllocatedUnfairLock(initialState: PendingTmuxNotifications())

    /// Panes that can take output directly on the parse queue, keyed by id.
    /// Maintained on the main actor as panes come and go; read off-main here.
    private nonisolated let outputSinks =
        OSAllocatedUnfairLock(initialState: [TmuxPaneID: @Sendable (Data) -> Void]())

    nonisolated func setOutputSink(_ pane: TmuxPaneID, _ sink: (@Sendable (Data) -> Void)?) {
        outputSinks.withLock { $0[pane] = sink }
    }

    nonisolated private func enqueueTmuxNotification(_ notification: TmuxNotification) {
        // Fast path: `%output` for a bound pane, with the queue empty and no
        // drain pending, cannot overtake anything — there is nothing ahead of
        // it to overtake. Deliver it on this queue and skip the main thread
        // entirely.
        //
        // The emptiness test is what preserves ordering. tmux's `%layout-change`
        // must still be applied before the `%output` that follows it (resize
        // correctness depends on it); the moment anything is queued or a drain
        // is scheduled, output goes back through the queue and stays behind it.
        // Both the test and the append happen under the same lock, so output
        // cannot slip past a notification enqueued concurrently.
        if case .output(let pane, let data) = notification {
            let sink: (@Sendable (Data) -> Void)? = pendingTmuxNotifications.withLockUnchecked { state in
                guard state.queue.isEmpty, !state.drainScheduled else { return nil }
                return outputSinks.withLock { $0[pane] }
            }
            if let sink {
                sink(data)
                return
            }
        }

        let scheduleDrain = pendingTmuxNotifications.withLockUnchecked { state -> Bool in
            state.queue.append(notification)
            if state.drainScheduled { return false }
            state.drainScheduled = true
            return true
        }
        guard scheduleDrain else { return }
        DispatchQueue.main.async { [weak self] in
            self?.drainTmuxNotifications()
        }
    }

    private func drainTmuxNotifications() {
        let batch = pendingTmuxNotifications.withLockUnchecked { state -> [TmuxNotification] in
            state.drainScheduled = false
            let queue = state.queue
            state.queue.removeAll(keepingCapacity: true)
            return queue
        }

        // Merge consecutive .output runs for the same pane into a single
        // feed; everything else is handled in arrival order.
        var i = 0
        while i < batch.count {
            if case .output(let pane, let first) = batch[i] {
                var data = first
                var j = i + 1
                while j < batch.count, case .output(let nextPane, let more) = batch[j], nextPane == pane {
                    data.append(more)
                    j += 1
                }
                handleTmuxNotification(.output(pane: pane, data: data))
                i = j
            } else {
                handleTmuxNotification(batch[i])
                i += 1
            }
        }
    }

    private func setupCallbacks() {
        transport.onStateChanged = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.connectionState = state
                if case .failed(let msg) = state {
                    self.handleUnexpectedFailure(message: msg)
                } else if case .connected = state {
                    // Successful (re)connect — clear the backoff counter.
                    self.reconnectAttempt = 0
                }
            }
        }

        transport.onDataReceived = { [weak self] data in
            self?.routeIncomingBytes(data)
        }

        tmuxService.onNotification = { [weak self] notification in
            self?.enqueueTmuxNotification(notification)
        }

        tmuxService.sendToSSH = { [weak self] string in
            guard let data = string.data(using: .utf8) else { return }
            self?.transport.write(data)
        }
    }

    /// Entry point for every byte arriving from the transport, on whatever
    /// thread the transport delivers on.
    ///
    /// Everything funnels through the serial parse queue first, so byte order
    /// survives regardless of which branch a chunk takes. In the steady state
    /// (tmux control mode, no capture in flight) the bytes are parsed right
    /// there and never touch the main thread — that is the path a keystroke's
    /// echo takes, and keeping it off main is what stops echoes from queueing
    /// behind the keystroke that produced them.
    ///
    /// Capture mode and raw-shell mode still hop to main. Neither can overlap
    /// with tmux mode (`captureShellOutput` runs before `launchTmux` sets
    /// `usingTmux`), so no chunk can take the fast path while another is still
    /// in flight on the slow one.
    nonisolated private func routeIncomingBytes(_ data: Data) {
        tmuxParseQueue.async { [weak self] in
            guard let self else { return }
            if self.usingTmux, !self.captureActive.withLock({ $0 }) {
                self.tmuxService.feedData(data)
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.routeIncomingData(data) }
            }
        }
    }

    /// Route a chunk of bytes to the right consumer based on phase. Main-actor
    /// only; the tmux steady state no longer reaches this (see
    /// `routeIncomingBytes`).
    private func routeIncomingData(_ data: Data) {
        // Capture mode (running a one-shot shell command silently).
        if var capture = shellCapture {
            capture.buffer.append(data)
            shellCapture = capture
            if let str = String(data: capture.buffer, encoding: .utf8),
               str.contains(capture.marker) {
                let result = str
                let cont = capture.continuation
                shellCapture = nil
                cont.resume(returning: result)
            }
            return
        }

        if usingTmux {
            // Parse off the main actor — under heavy TUI output the protocol
            // parse is the main thread's biggest contender with keyDown.
            // Only reachable if the mode flipped while a chunk was already on
            // the slow path; the steady state parses in `routeIncomingBytes`.
            let service = tmuxService
            tmuxParseQueue.async { service.feedData(data) }
            return
        }

        // Non-tmux: forward to single-pane terminal — but only after the user
        // has explicitly picked the no-tmux option. Until then we drop, so
        // shell prompts and our `tmux ls` output don't pollute the screen.
        if phase == .shellReady {
            // Reconcile predictions against the echo BEFORE it renders, so a
            // confirmed char's overlay is retired as the real byte paints over it.
            predictor.didReceive(data)
            appendRawHistory(data)
            onRawDataReceived?(data)
        }
    }

    private func appendRawHistory(_ data: Data) {
        rawHistory.append(data)
        let overflow = rawHistory.count - Self.maxRawHistoryBytes
        if overflow > 0 {
            rawHistory.removeSubrange(0..<overflow)
        }
    }

    // MARK: - Connect

    public func connect() async {
        userInitiatedDisconnect = false
        // NOTE: do NOT cancel `reconnectTask` here. `connect()` is called from
        // inside the reconnect loop (via `reattachExistingSession`); cancelling
        // would kill the loop mid-flight, so a single failed attempt would give
        // up instead of retrying with backoff. The loop owns `reconnectTask`;
        // user-initiated tear-downs cancel it in `disconnect()`.
        rawHistory.removeAll(keepingCapacity: true)
        guard let startedSize = await bringUpTransport() else { return }

        // A transport that starts `tmux -CC` itself has NO shell on the other
        // end — every write below is a line of text typed at a control-mode
        // stream. Skip straight out and let `applyTmuxChoice` await the
        // greeting. (The keychain unlock and the marker-bracketed `tmux ls` in
        // `refreshTmuxSessions` are both shell commands; over `ssh -t host
        // "tmux -CC …"` they would be typed into the protocol.)
        if transport.startsInTmuxControlMode {
            phase = .starting
            return
        }

        // Wait briefly for the shell prompt to settle.
        try? await Task.sleep(for: .milliseconds(500))

        // Re-assert the surface's real grid now that the channel is connected.
        // A resize that fired while the transport was still connecting gets
        // dropped — there is no channel yet to carry it — leaving the remote PTY a
        // different width than what we render — the shell drew its prompt at the
        // wrong width and only re-lays-out on SIGWINCH. Re-sending the size here
        // delivers that SIGWINCH so the prompt/TUI redraws at the rendered grid.
        if let s = lastReportedSize, s.cols != startedSize.cols || s.rows != startedSize.rows {
            dlog("post-connect resize to \(s.cols)x\(s.rows) (shell started at \(startedSize.cols)x\(startedSize.rows))")
            transport.resize(cols: s.cols, rows: s.rows)
        }

        // Optional: unlock keychain BEFORE listing sessions, so the next
        // command sees a stable shell.
        if host.unlockMacKeychain {
            await unlockMacKeychain()
        }

        // Move to choosing-session phase and load the session list.
        phase = .choosingSession
        await refreshTmuxSessions()
    }

    /// Bring the transport up and start the PTY at the rendered size. Shared
    /// by first connect (which continues into session discovery) and reattach
    /// (which skips straight to the tmux attach). Returns the size the shell
    /// was started at, or nil if the transport failed to connect.
    private func bringUpTransport() async -> (cols: Int, rows: Int)? {
        errorMessage = nil
        showError = false
        phase = .sshConnecting
        dlog("Connecting to \(self.host.hostname):\(self.host.port)")
        await transport.connect(host: host)

        guard case .connected = transport.state else {
            dlog("SSH connection failed: \(String(describing: self.transport.state))")
            return nil
        }

        // Start the shell at the surface's last reported grid if we have one
        // (it's authoritative); else fall back to the screen estimate. This
        // keeps the remote PTY width == the rendered grid even when the
        // surface's resize fired before the transport finished connecting.
        let screenSize = lastReportedSize ?? idealTerminalSize()
        dlog("startShell \(screenSize.cols)x\(screenSize.rows) (lastReported=\(String(describing: lastReportedSize)))")
        transport.startShell(cols: screenSize.cols, rows: screenSize.rows)
        return screenSize
    }

    /// Calculate ideal cols×rows to fill the screen. Used only for the initial
    /// SSH PTY size (before SwiftTerm has laid out) and the user-triggered
    /// "reset client size" button. Once SwiftTerm is rendering, its own
    /// `sizeChanged` callback drives all subsequent resizes — that path is
    /// authoritative and avoids any drift from this best-effort estimate.
    ///
    /// Uses the user-selected terminal font, not SF Mono, since custom fonts
    /// (Maple / JetBrains) have noticeably different advance widths. Does not
    /// round-up the cell width — Int() truncation already underestimates cols
    /// slightly; further ceil() would compound the loss.
    private func idealTerminalSize() -> (cols: Int, rows: Int) {
        environment.idealTerminalSize()
    }

    // MARK: - Session Picker

    /// Run `tmux ls` and parse the output into a list of session names.
    public func refreshTmuxSessions() async {
        // Concurrent refreshes (e.g. a menu re-resolving on every display)
        // stack rapid-fire list-sessions on the control channel — drop the
        // duplicates while one is already in flight.
        guard !sessionsLoading else { return }
        sessionsLoading = true
        defer { sessionsLoading = false }

        // If we're already attached via tmux -CC, the SSH channel is owned by
        // the control-mode protocol and we can't run raw shell. Query the
        // server directly via the control command instead.
        if usingTmux {
            let response = await tmuxService.send(.listSessions)
            guard !response.isError else {
                dlog("list-sessions (control) error: \(response.output)")
                return
            }
            // Format: `$id:name` per line (set by Command.listSessions).
            availableTmuxSessions = response.output
                .split(separator: "\n")
                .compactMap { line -> String? in
                    // Anything not `$id:…` is channel noise (stray pane
                    // output has been observed in responses), not a session.
                    guard line.hasPrefix("$") else { return nil }
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    return String(parts[1])
                }
            dlog("Found tmux sessions (control): \(self.availableTmuxSessions)")
            // Answered by the server this connection is attached to — the only
            // list that can speak for this window's session.
            sessionListGeneration &+= 1
            return
        }

        // Bracket the tmux output with start + end markers. Each marker is
        // assembled from two halves so the PTY echo of the command line
        // (which renders both halves with a quote-and-space between them)
        // can never match the concatenated form. Only the runtime `printf`
        // produces a contiguous marker — so we can confidently slice the
        // output between markers to get a clean list of sessions, no matter
        // what OSC / CSI / syntax-highlight garbage the shell injected.
        let token = String(UUID().uuidString.prefix(8))
        let startA = "__SPK_S_\(token)_"
        let startB = "_GO__"
        let startMarker = startA + startB
        let endA = "__SPK_E_\(token)_"
        let endB = "_DONE__"
        let endMarker = endA + endB
        let cmd =
            "printf '\\n%s%s\\n' '\(startA)' '\(startB)';" +
            " tmux ls 2>/dev/null;" +
            " printf '%s%s\\n' '\(endA)' '\(endB)'\n"
        let output = await captureShellOutput(cmd: cmd, marker: endMarker, timeoutMs: 5000)
        availableTmuxSessions = TmuxParsers.parseTmuxLs(output, startMarker: startMarker, endMarker: endMarker)
        dlog("Found tmux sessions: \(self.availableTmuxSessions)")
    }

    /// Send a shell command and capture all output until `marker` is observed
    /// (or until timeout). Output is consumed silently and not forwarded to
    /// the terminal.
    private func captureShellOutput(cmd: String, marker: String, timeoutMs: Int) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            shellCapture = ShellCapture(buffer: Data(), marker: marker, continuation: continuation)
            transport.write(cmd)

            // Timeout: if marker doesn't appear, return whatever we have.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                guard let self else { return }
                await MainActor.run {
                    if let capture = self.shellCapture {
                        let str = String(data: capture.buffer, encoding: .utf8) ?? ""
                        self.shellCapture = nil
                        capture.continuation.resume(returning: str)
                    }
                }
            }
        }
    }

    // Parsers / ANSI stripping live in the SwiftTmux package now.

    /// Apply the user's session choice. Called from the session picker UI.
    public func applyTmuxChoice(_ choice: TmuxStartChoice) async {
        phase = .starting
        switch choice {
        case .noTmux:
            // Move into shell-only mode: subsequent SSH data flows to the
            // single-pane terminal. Send a `clear` so the screen starts fresh
            // (the previous `tmux ls` output that we silently captured won't
            // appear on screen, but the cursor state is well-defined).
            phase = .shellReady
            transport.write("clear\n")
        case .createOrAttach(let name):
            // Only force the tmux client viewport to the phone screen when
            // we're CREATING a brand-new session — i.e. the name wasn't in
            // the just-fetched `tmux ls` output. On attach we want to keep
            // the existing session's server-side geometry; the canvas can
            // overflow the phone viewport and the user pans/zooms to see.
            // `resizeToScreen` forces the client viewport to this device's
            // screen, and is only ever right when we CREATED the session —
            // shrinking one that already exists would shrink it for every other
            // client too.
            //
            // Knowing which happened relies on the `tmux ls` that `connect()`
            // ran first. A transport that starts `tmux -CC` itself has no such
            // list (there was no shell to ask), and an empty list must not be
            // read as "the session is new" — that is precisely the case where
            // it is most likely to be an existing session on a machine that has
            // been running for weeks. Leave the geometry alone; the pty was
            // opened at the rendered grid, so the attach already reports a
            // sensible client size.
            let isAttachToExisting =
                transport.startsInTmuxControlMode || availableTmuxSessions.contains(name)
            await launchTmux(
                sessionName: name,
                groupWith: nil,
                resizeToScreen: !isAttachToExisting
            )
        case .shareWithDesktop(let target):
            await launchTmux(sessionName: "\(target)-mobile", groupWith: target, resizeToScreen: false)
        case .createAgent(let spec):
            // Seed the session on the -CC launch line itself, then build out the
            // extra panes over control mode.
            //
            // This used to type a `tmux new-session -d …; tmux split-window …`
            // script into the shell first and sleep 1s before attaching. That
            // raced the freshly spawned login shell's pty: when the write landed
            // before the pty was ready the line was mangled, `-c <dir>` went with
            // it, and the agent came up in the app's cwd instead of the folder
            // the user picked — silently, because nothing reads a shell's stderr
            // here. Everything below is either a write we had to make anyway or a
            // control-mode command with a response we can log.
            dlog("Creating agent session \(spec.sessionName) (\(spec.layout.paneCount) panes)")
            // An explicit directory AND command, chosen deliberately in the
            // wizard — the most reusable launch there is, and the reason the
            // recents list exists. Recorded here rather than at the macOS
            // window so the iPad wizard feeds the same list.
            PaletteRecents.shared.recordLaunchIfUseful(
                dir: spec.workingDir, command: spec.agentCommand)
            await launchTmux(
                sessionName: spec.sessionName,
                groupWith: nil,
                resizeToScreen: false,
                path: spec.workingDir,
                command: spec.agentCommand
            )
            await applyAgentLayout(spec)
        }
    }

    /// Add the spec's extra panes once control mode is up, so each split is a
    /// tracked command with a real response instead of text typed at a shell.
    ///
    /// Splits deliberately pass no path: `split-window` already defaults to
    /// `-c '#{pane_current_path}'`, which tmux expands server-side against the
    /// source pane — the first pane, which the launch line put in the right
    /// directory. Re-sending the path here would be worse than redundant, since
    /// control mode has no shell to expand a leading `~`.
    private func applyAgentLayout(_ spec: AgentSpec) async {
        let extraPanes = max(spec.layout.paneCount - 1, 0)
        guard extraPanes > 0 || spec.layout.tmuxLayoutName != nil else { return }

        let program: SpawnCommand? = spec.agentCommand.isEmpty ? nil : .shell(spec.agentCommand)
        for i in 0..<extraPanes {
            let resp = await tmuxService.send(.splitWindow(horizontal: true, command: program))
            if resp.isError {
                dlog("createAgent: split \(i + 1)/\(extraPanes) failed: \(resp.output)")
            }
        }
        if let layoutName = spec.layout.tmuxLayoutName {
            let resp = await tmuxService.send(
                .selectLayoutTarget(target: "\(spec.sessionName):", layout: layoutName))
            if resp.isError { dlog("createAgent: select-layout failed: \(resp.output)") }
        }
        await refreshPanes()
        await refreshWindows()
    }

    private func launchTmux(
        sessionName: String,
        groupWith: String?,
        resizeToScreen: Bool,
        path: String? = nil,
        command: String? = nil
    ) async {
        usingTmux = true
        activeTmuxSessionName = sessionName

        // When the transport carried the `tmux -CC` invocation as its own
        // argument, tmux is already coming up and there is nothing to type —
        // writing the launch line here would send it *through* control mode as
        // pane input. See `TerminalTransport.startsInTmuxControlMode` for why
        // that shape exists at all (it is what makes a host that prompts for a
        // password or a 2FA code work).
        if transport.startsInTmuxControlMode {
            dlog("tmux -CC launched by the transport itself — awaiting greeting")
        } else {
            let launchCmd = tmuxService.launchCommand(
                sessionName: sessionName, groupWith: groupWith, path: path, command: command)
            dlog("Launching tmux: \(launchCmd.trimmingCharacters(in: .whitespacesAndNewlines))")
            transport.write(launchCmd)
        }

        // Wait for the -CC greeting (its first %begin) instead of a fixed
        // sleep: commands sent before tmux attaches would be typed into the
        // plain shell. Faster than 1s when the shell is quick, tolerant when
        // it's slow (fresh login shell runs the full zshrc first).
        let sawGreeting = await tmuxService.awaitControlMode(timeout: .seconds(12))
        if !sawGreeting {
            dlog("tmux -CC greeting not seen within 12s — proceeding anyway")
        }

        // Only resize the tmux client viewport when we created a new
        // standalone session, since shrinking a shared session would also
        // shrink the desktop's view.
        if resizeToScreen {
            let screen = idealTerminalSize()
            dlog("Setting tmux client size to \(screen.cols)x\(screen.rows)")
            tmuxService.sendFireAndForget(.refreshClient(width: screen.cols, height: screen.rows))
            try? await Task.sleep(for: .milliseconds(300))
        }

        dlog("Querying tmux panes and windows...")
        await refreshPanes()
        await refreshWindows()
        dlog("tmux ready: \(self.paneViewModels.count) panes, \(self.windows.count) windows")

        isTmuxReady = true
        phase = .tmuxReady
        // The sizing policy lives on the tmux server (`window-size`), so a
        // reconnect has to re-assert it — otherwise a pinned session silently
        // goes back to tracking the first client that touches it.
        restoreSizingMode(for: sessionName)
        startStatePolling()
        // Warm the session list so Move-to-Session menus (which resolve
        // synchronously from this cache) have targets on their FIRST open —
        // attaching straight to a remembered session (reconnects, and any
        // launch that already knows the name) skips the picker that would
        // otherwise have filled it.
        Task { await refreshTmuxSessions() }
    }

    // MARK: - tmux Notifications

    private func handleTmuxNotification(_ notification: TmuxNotification) {
        switch notification {
        case .output(let pane, let data):
            if let paneVM = paneViewModels.first(where: { $0.paneID == pane }) {
                paneVM.feedData(data)
            }
            stateDetection.recordOutput(pane: pane, data: data)

        case .layoutChange(_, let layout):
            // Apply the new pane geometry SYNCHRONOUSLY from the layout string.
            // tmux delivers %layout-change BEFORE the program's post-SIGWINCH
            // repaint %output in this same ordered stream, so resizing the
            // surfaces now guarantees they are at the new size when that repaint
            // is fed to ghostty. The previous debounced (300ms) list-panes path
            // left surfaces at the OLD size while the program repainted at the
            // NEW width → the repaint wrapped into the stale grid and stayed
            // garbled until the next resize. The debounced refresh still runs for
            // the rest of the metadata (titles, commands, mouse flags, added /
            // removed panes, active / zoom state).
            applyLayoutGeometry(layout)
            layoutChangeDebounce?.cancel()
            layoutChangeDebounce = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await refreshPanes()
            }

        case .windowAdd(let win):
            DIAG("[DUP] %window-add \(win)")
            Task { await refreshWindows() }

        case .windowClose(let win):
            DIAG("[DUP] %window-close \(win)  ← tmux reports this window's last pane exited")
            Task {
                await refreshWindows()
                await refreshPanes()
            }

        case .windowRenamed(let winID, let name):
            if let idx = windows.firstIndex(where: { $0.id == winID }) {
                windows[idx].name = name
            }

        case .sessionChanged(_, let name):
            // The control client attached to a different session (e.g. via the
            // top-bar session switcher). Adopt the new name and re-sync windows
            // and panes — the new session has different pane IDs, so the surfaces
            // must be rebuilt from the fresh list.
            activeTmuxSessionName = name
            Task {
                await refreshWindows()
                await refreshPanes()
            }

        case .sessionRenamed(let name):
            activeTmuxSessionName = name

        case .paneModeChanged(let pane, _):
            if let paneVM = paneViewModels.first(where: { $0.paneID == pane }) {
                let state = stateDetection.detectState(pane: pane, currentCommand: paneVM.pane.currentCommand, title: paneVM.pane.title)
                paneVM.paneState = state
                paneStates[pane] = state   // keep the window-dot aggregate in step
                stateVersion += 1
            }
            // tmux's notification carries only the pane id — not which mode — so
            // re-list to pick up `pane_in_mode`. Without this the copy-mode badge
            // would wait for the 2s poll, which is long enough for the pane to
            // look broken (scrolling does nothing, no explanation).
            Task { await refreshPanes() }

        case .clientDetached(let client):
            handleClientDetached(client)

        case .exit:
            usingTmux = false
            isTmuxReady = false
            phase = .ended
        }
    }

    // MARK: - Pane Management

    /// Strip tmux control-mode chatter that the parser can fold into a
    /// `capture-pane` response when a transport read splits the stream mid-line
    /// during a session switch (see ControlMode.handleLine). Feeding those lines to the
    /// surface paints raw protocol text — "%output %5 \033[…", "%begin/%end",
    /// "%layout-change …" — over the pane (BUG-007, iOS-mostly). Real captured
    /// screen content never begins with one of these exact markers, so dropping
    /// them is safe and only removes the interleaved junk. Cheap no-op when the
    /// capture has no '%' at all (the common case).
    static func stripControlModeChatter(_ text: String) -> String {
        guard text.utf8.contains(UInt8(ascii: "%")) else { return text }
        let markers = ["%output %", "%begin ", "%end ", "%error ",
                       "%layout-change ", "%window-add ", "%window-close ",
                       "%window-renamed ", "%window-pane-changed", "%unlinked-window-",
                       "%session-changed ", "%sessions-changed", "%pane-mode-changed ",
                       "%client-session-changed", "%config-error", "%exit",
                       "%pause", "%continue", "%subscription-changed"]
        // A line is chatter if it starts with a marker, OR (BUG-007) a marker
        // hides behind a leading NON-PRINTABLE escape/control junk prefix. The
        // non-printable anchor is what keeps real captured content — which starts
        // with a printable glyph — safe even if it contains a marker as substring.
        func isChatter(_ line: Substring) -> Bool {
            if markers.contains(where: { line.hasPrefix($0) }) { return true }
            guard let first = line.unicodeScalars.first,
                  first.value < 0x20 || first.value == 0x7f else { return false }
            let trimmed = line.drop { ch in
                ch.unicodeScalars.allSatisfy { $0.value < 0x20 || $0.value == 0x7f }
            }
            return markers.contains { trimmed.hasPrefix($0) }
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.contains(where: isChatter) else {
            return text   // nothing to strip — preserve the string exactly
        }
        return lines.filter { !isChatter($0) }.joined(separator: "\n")
    }

    public func refreshPanes() async {
        // Session-wide (-s): one command feeds both models — `sessionPanes`
        // (all windows, for the structure/list layer) and `paneViewModels`
        // (current window only, the panes with live surfaces).
        let response = await tmuxService.send(.listPanes(sessionWide: true))
        guard !response.isError else {
            dlog("list-panes error: \(response.output)")
            if response.output.hasPrefix("timeout") { noteCommandTimeout() }
            return
        }
        commandTimeoutStreak = 0

        let allPanes = TmuxParsers.parsePaneList(response.output)
        // Current window's panes via each line's own window_active flag — no
        // dependence on separately-refreshed (possibly stale) window state.
        let panes = allPanes.filter(\.inActiveWindow)
        dlog("Parsed \(allPanes.count) panes (\(panes.count) in active window): \(panes.map { "\($0.id) \($0.width)x\($0.height) at \($0.x),\($0.y)" })")

        // A live tmux session always has at least one pane. An empty parse here
        // is never real state — under fast input the `list-panes` response gets
        // raced/interleaved with `%output` and `parsePaneList` drops every line
        // (it `compactMap`s unparseable lines to nothing). Applying that empty
        // result would wipe `paneViewModels`, tearing down EVERY ghostty surface
        // (black screen + broken responder chain → each keystroke beeps) until
        // the next refresh rebuilds them. Real session/window teardown arrives
        // via `.exit` / `.windowClose`, which change `phase` — so while we still
        // hold panes and the session is live, treat empty as a transient glitch:
        // skip the destructive update and re-fetch shortly.
        // (No isTmuxReady condition: during a REATTACH isTmuxReady is still
        // false while panes are populated — applying an empty parse there
        // would wipe the view-models the surfaces are bound to, which is
        // exactly the "input works, rendering dead" zombie.)
        // A clean response parses every non-empty line; a shortfall means the
        // body was interleaved with %output (see refreshWindows) — partial
        // results would silently drop panes, so treat them like empty.
        let paneLineCount = response.output.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if panes.isEmpty || allPanes.count != paneLineCount, !paneViewModels.isEmpty, usingTmux {
            log.warning("refreshPanes: ignored raced list-panes parse (\(allPanes.count, privacy: .public)/\(paneLineCount, privacy: .public) lines, have \(self.paneViewModels.count, privacy: .public) panes) — re-fetching")
            DIAG("[DUP] refreshPanes DEFER raced parse (\(allPanes.count)/\(paneLineCount) lines) — re-fetch in 250ms; shared layoutChangeDebounce token")
            layoutChangeDebounce?.cancel()
            layoutChangeDebounce = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await refreshPanes()
            }
            return
        }
        // [DUP] The applied set. If a duplicated pane appears in one line then a
        // LATER line (a stale list-panes issued before it existed) omits it,
        // updatePaneViewModels → syncPanes tears its surface down = "闪一下就关掉".
        let dropped = Set(sessionPanes.map(\.id)).subtracting(allPanes.map(\.id))
        DIAG("[DUP] refreshPanes APPLY all=[\(allPanes.map { "\($0.id)" }.joined(separator: ","))] active=[\(panes.map { "\($0.id)" }.joined(separator: ","))]\(dropped.isEmpty ? "" : " DROPPED=[\(dropped.map { "\($0)" }.joined(separator: ","))]")")
        if sessionPanes != allPanes { sessionPanes = allPanes }
        updatePaneViewModels(panes)
        recomputeSessionMode()
    }

    public func refreshWindows() async {
        let response = await tmuxService.send(.listWindows())
        guard !response.isError else { return }
        let parsed = TmuxParsers.parseWindowList(response.output)

        // Under heavy output (e.g. the repaint burst right after select-window
        // resizes the newly-current window) the command response can get
        // interleaved with `%output`, so lines drop or split and the parse
        // comes back partial/empty — same race as refreshPanes' empty-parse
        // guard. Applying a partial list here shrinks `windows`, which
        // e.g. hides the phone's window tab bar until something else happens
        // to refresh. A CLEAN response parses every non-empty line as a
        // window and is never empty on a live session — anything else is
        // corrupt: keep the current list and re-fetch shortly.
        let lineCount = response.output.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if usingTmux, !windows.isEmpty, parsed.count != lineCount || parsed.isEmpty {
            log.warning("refreshWindows: ignored corrupt list-windows parse (\(parsed.count, privacy: .public)/\(lineCount, privacy: .public) lines, have \(self.windows.count, privacy: .public)) — re-fetching")
            windowsRefreshRetry?.cancel()
            windowsRefreshRetry = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await refreshWindows()
            }
            return
        }
        if windows != parsed { windows = parsed }
        let newActiveWindowID = windows.first(where: { $0.isActive })?.id ?? activeWindowID
        if activeWindowID != newActiveWindowID { activeWindowID = newActiveWindowID }
    }

    /// Apply pane geometry parsed from a `%layout-change` layout string to the
    /// existing panes, immediately, so their ghostty surfaces resize before the
    /// program's repaint output arrives. Updates only geometry (the layout string
    /// carries no command/title/mouse/active info) on panes we already have; new
    /// or removed panes are reconciled by the debounced `refreshPanes`.
    private func applyLayoutGeometry(_ layout: String) {
        let geom = TmuxParsers.parsePaneGeometry(layout)
        guard !geom.isEmpty else { return }
        var changed = false
        for g in geom {
            guard let vm = paneViewModels.first(where: { $0.paneID == g.id }) else { continue }
            var p = vm.pane
            guard p.width != g.width || p.height != g.height || p.x != g.x || p.y != g.y else { continue }
            p.width = g.width; p.height = g.height; p.x = g.x; p.y = g.y
            vm.updatePane(p)
            changed = true
        }
        // Resize surfaces SYNCHRONOUSLY now (not via the async $paneViewModels
        // publisher), so they are at the new size before the program's repaint
        // %output — the next notification on this main-actor stream — is fed to
        // ghostty. Each pane already exists (geometry-only change), so the host
        // just re-runs layoutCells; added / removed panes are handled by the
        // debounced refreshPanes.
        if changed { onGeometryApplied?() }
    }

    /// Synchronous hook invoked right after `%layout-change` geometry is applied,
    /// before the subsequent repaint output is processed. The view layer sets
    /// this to re-tile its surfaces. See `applyLayoutGeometry`.
    public var onGeometryApplied: (() -> Void)?

    private func updatePaneViewModels(_ panes: [Pane]) {
        // Snapshot BEFORE updatePane mutates the reused instances, so the
        // no-change gate below compares against what was actually published.
        let oldVMs = paneViewModels
        let oldPanes = oldVMs.map(\.pane)

        var newViewModels: [PaneViewModel] = []
        var newPaneIDs: [TmuxPaneID] = []

        for pane in panes {
            if let existing = paneViewModels.first(where: { $0.paneID == pane.id }) {
                existing.updatePane(pane)
                if existing.isActive != pane.isActive { existing.isActive = pane.isActive }
                newViewModels.append(existing)
            } else {
                let vm = PaneViewModel(pane: pane, tmuxService: tmuxService)
                vm.isActive = pane.isActive
                newViewModels.append(vm)
                newPaneIDs.append(pane.id)
                // Lets `%output` for this pane bypass the main thread entirely
                // (see enqueueTmuxNotification). `feedData` is nonisolated and
                // internally locked, so the parse queue can call it directly.
                setOutputSink(pane.id) { [weak vm] data in vm?.feedData(data) }
                DIAG("newVM \(pane.id) \(pane.width)x\(pane.height)")
            }
        }

        // Drop sinks for panes that went away, so a dead pane's bytes don't keep
        // a view model alive or land on a surface that's being torn down.
        let liveIDs = Set(newViewModels.map(\.paneID))
        for old in oldVMs where !liveIDs.contains(old.paneID) {
            setOutputSink(old.paneID, nil)
        }

        // Equality-gate the array publish: the 2s poll usually returns the same
        // panes with the same data, and every republish makes the hosts re-run
        // syncPanes/layout. Identical = same instances in the same order, no
        // new panes, and no per-pane data change.
        let identical = newPaneIDs.isEmpty
            && newViewModels.count == oldVMs.count
            && zip(newViewModels, oldVMs).allSatisfy { $0 === $1 }
            && panes == oldPanes
        if !identical { paneViewModels = newViewModels }

        if !newPaneIDs.isEmpty {
            Task {
                await seedNewPanes(newPaneIDs)
            }
        }

        if let active = panes.first(where: { $0.isActive }) {
            if activePaneID != active.id { activePaneID = active.id }
            // window_zoomed_flag is per-window; the zoomed pane is the active one.
            let newZoom = active.isZoomed ? active.id : nil
            if zoomedPaneID != newZoom { zoomedPaneID = newZoom }
        } else {
            if zoomedPaneID != nil { zoomedPaneID = nil }
        }
    }

    /// Seed freshly-created panes' surfaces with their current screen content
    /// (capture-pane snapshot), then refresh the state pipeline. Extracted from
    /// `updatePaneViewModels`.
    /// How far back a fresh surface is seeded from tmux's history, in lines.
    ///
    /// This used to be one screenful, which meant a pane's scrollback effectively
    /// began at the moment its surface was created — and surfaces are recreated
    /// whenever the pane set changes (`GhosttyTiledPaneHost.syncPanes` tears them
    /// down), so **every window switch threw the scrollback away**. Nothing that
    /// reads backwards worked past that line: scrolling up, turn navigation,
    /// scroll-review-compose, and now ⌘F.
    ///
    /// tmux clamps `-S` to whatever history actually exists, so this is a ceiling,
    /// not a cost floor — an idle shell pane still seeds a few dozen lines, and an
    /// alt-screen TUI has no history at all. The ceiling matters for a pane that
    /// really has scrolled a lot: the capture is one control-mode response, so a
    /// deep one adds latency to the window switch that reveals it. 2000 = tmux's
    /// own default `history-limit`. Override without a rebuild via the
    /// `terminal_seed_history_lines` default.
    /// 2000 = tmux's own default `history-limit`, over a local pty where the
    /// capture is a pipe read.
    ///
    /// Over a network link it is a very different bill: the same capture is
    /// decrypted and drained on the main thread (iOS does all of that there),
    /// it is paid again on every window switch, and `escapes: true` inflates a
    /// colorful agent pane several-fold. So a remote link seeds a few screens —
    /// enough that scrolling back and ⌘F still find something, not enough to
    /// stall an attach on a phone.
    var seedHistoryLines: Int {
        let v = UserDefaults.standard.integer(forKey: "terminal_seed_history_lines")
        if v > 0 { return v }
        return transport.isLocalLink ? 2000 : 400
    }

    private func seedNewPanes(_ ids: [TmuxPaneID]) async {
        for paneVM in paneViewModels where ids.contains(paneVM.paneID) {
            let screen = paneVM.pane.height > 0 ? paneVM.pane.height : 50
            let lines = max(screen, seedHistoryLines)
            // Seed the fresh surface with the pane's current screen.
            // `escapes: true` keeps SGR color/style codes so a freshly
            // shown pane (e.g. after a window switch) seeds in full color
            // instead of plain text that then flashes when the live
            // %output repaints. Detection (recordOutput below) strips
            // ANSI anyway, so the escapes are harmless there.
            //
            // capture-pane can race the select-window %output burst
            // (timeout, or a parse that comes back empty): a lost seed
            // leaves the new surface blank until the TUI happens to
            // repaint a region — the "white screen, only updated parts
            // show" on a window switch. Retry a few times on
            // error/empty so the seed actually lands.
            var seeded = false
            for attempt in 0..<3 {
                let resp = await tmuxService.send(.capturePane(id: paneVM.paneID, lines: lines, escapes: true))
                let text = resp.isError ? "" : Self.stripControlModeChatter(resp.output)
                DIAG("seed \(paneVM.paneID) attempt \(attempt): err=\(resp.isError) bytes=\(text.utf8.count)")
                guard !resp.isError, !text.isEmpty else {
                    try? await Task.sleep(for: .milliseconds(120))
                    continue
                }
                let termText = text.replacingOccurrences(of: "\n", with: "\r\n")
                if let data = termText.data(using: .utf8) {
                    paneVM.feedData(data)
                    DIAG("seed \(paneVM.paneID) FED bytes=\(data.count)")
                }
                if let rawData = text.data(using: .utf8) {
                    stateDetection.recordOutput(pane: paneVM.paneID, data: rawData)
                }
                // Restore the caret to the pane's REAL cursor. capture-pane returns
                // the screen rows WITH trailing blank lines below a short prompt;
                // fed as \r\n-terminated rows they park the caret at the bottom of
                // the captured region, not where tmux's cursor actually is. A
                // freshly-split pane then shows its prompt at the top but the caret
                // at the window bottom (other tmux clients don't text-seed, so they
                // render fine). An explicit CUP to tmux's #{cursor_y} #{cursor_x} —
                // 0-based, so +1 for the 1-based CSI — fixes shells and TUIs alike.
                // Fields are SPACE-separated, never ";": ";" is tmux's command
                // separator and would split display-message into two commands; the
                // space also makes the format a quoted single arg (see escapeArg).
                let cur = await tmuxService.send(.displayMessage(format: "#{cursor_y} #{cursor_x}", target: paneVM.paneID))
                let fields = cur.isError ? [] : cur.output
                    .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
                if fields.count == 2, let cy = Int(fields[0]), let cx = Int(fields[1]),
                   let cup = "\u{1b}[\(cy + 1);\(cx + 1)H".data(using: .utf8) {
                    paneVM.feedData(cup)
                    DIAG("seed \(paneVM.paneID) CURSOR restore y=\(cy) x=\(cx)")
                }
                seeded = true
                break
            }
            if !seeded {
                DIAG("seed \(paneVM.paneID) gave up (error/empty)")
            }
        }
        await updatePaneStates()
    }

    // MARK: - Actions

    // MARK: - tmux copy-mode
    //
    // Bento does NOT implement copy-mode: everything it exists for in a bare
    // terminal (scrollback, keyboard selection, rectangle select) is already
    // native here, because each pane has a real terminal surface with a real
    // scrollback. What IS needed is not being broken when a pane enters the mode
    // from somewhere else — another client, a script, the user's own binding.

    /// Scroll a pane that tmux has in copy-mode. Positive `rows` = toward older
    /// output.
    public func scrollCopyMode(_ pane: TmuxPaneID, rows: Int) {
        guard rows != 0 else { return }
        tmuxService.sendFireAndForget(.copyModeCommand(
            pane: pane,
            command: rows > 0 ? "scroll-up" : "scroll-down",
            count: abs(rows)))
    }

    /// Leave copy-mode. `cancel` is a copy-mode COMMAND, so it works whether the
    /// user's mode keys are vi or emacs — sending a literal `q` would not.
    public func exitCopyMode(_ pane: TmuxPaneID) {
        tmuxService.sendFireAndForget(.copyModeCommand(pane: pane, command: "cancel"))
        Task { await refreshPanes() }
    }

    public func splitPane(horizontal: Bool) {
        if let activePaneID {
            tmuxService.sendFireAndForget(.selectPane(id: activePaneID))
        }
        tmuxService.sendFireAndForget(.splitWindow(target: activePaneID, horizontal: horizontal))
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await refreshPanes()
        }
    }

    public func selectPane(_ paneID: TmuxPaneID) {
        guard usingTmux else { return }
        tmuxService.sendFireAndForget(.selectPane(id: paneID))
        activePaneID = paneID
        for vm in paneViewModels {
            vm.isActive = (vm.paneID == paneID)
            // Focusing a pane = seeing it → clear the "done, unseen" badge.
            if vm.paneID == paneID, vm.agentFinishedUnseen {
                vm.agentFinishedUnseen = false
            }
        }
    }

    public func resizePaneBy(_ paneID: TmuxPaneID, direction: String, amount: Int) {
        tmuxService.sendFireAndForget(.resizePaneBy(id: paneID, direction: direction, amount: amount))
    }

    public func toggleZoom(_ paneID: TmuxPaneID) {
        tmuxService.sendFireAndForget(.zoomPane(id: paneID))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshPanes()
        }
    }

    public func closePane(_ paneID: TmuxPaneID) {
        tmuxService.sendFireAndForget(.killPane(id: paneID))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshPanes()
        }
    }

    /// Swap a pane with its previous/next neighbor (tmux `swap-pane -U/-D`,
    /// same as tmux's `{`/`}` bindings). The resulting %layout-change moves
    /// each surface to its pane's new geometry — content follows pane IDs, so
    /// no repaint is needed beyond tmux's own resize output.
    public func swapPane(_ paneID: TmuxPaneID, up: Bool) {
        guard usingTmux else { return }
        tmuxService.sendFireAndForget(up ? .swapPaneUp(id: paneID) : .swapPaneDown(id: paneID))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshPanes()
        }
    }

    /// Swap two specific panes (drag a pane's title bar onto another pane's
    /// CENTER drop zone).
    public func swapPanes(_ source: TmuxPaneID, with destination: TmuxPaneID) {
        guard usingTmux, source != destination else { return }
        tmuxService.sendFireAndForget(.swapPanes(source: source, destination: destination))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshPanes()
        }
    }

    /// Dock `source` against one edge of `target` (drag onto an EDGE drop
    /// zone): tmux re-splits the target along that axis and moves the dragged
    /// pane into the new half, which lands focused (no -d on move-pane).
    public func movePane(_ source: TmuxPaneID, splitting target: TmuxPaneID,
                         horizontal: Bool, before: Bool) {
        guard usingTmux, source != target else { return }
        tmuxService.sendFireAndForget(.movePane(
            source: source, target: target, horizontal: horizontal, before: before))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshPanes()
        }
    }

    /// Force a pane's detection profile (pane menu → Change Profile); nil =
    /// auto-detect. Takes effect on the next detection tick.
    public func setPaneProfile(_ profileID: String?, for paneID: TmuxPaneID) {
        stateDetection.setProfileOverride(profileID, for: paneID)
    }

    public func paneProfile(for paneID: TmuxPaneID) -> String? {
        stateDetection.profileOverride(for: paneID)
    }

    /// Rename a pane (sets `pane_title`, shown in the pane title bar / List rows).
    public func renamePane(_ paneID: TmuxPaneID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tmuxService.sendFireAndForget(.setPaneTitle(id: paneID, title: trimmed))
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await refreshPanes()
        }
    }

    /// Switch the attached control client to another tmux session on the same
    /// host (PRD §3.6 session switcher). tmux replies with %session-changed,
    /// which re-syncs windows/panes; we also refresh defensively in case the
    /// notification is missed.
    public func switchSession(_ name: String) {
        guard usingTmux, name != activeTmuxSessionName else { return }
        tmuxService.sendFireAndForget(.switchClient(session: name))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshWindows()
            await refreshPanes()
        }
    }

    /// Rename the attached tmux session (the toolbar's "Rename Session…").
    public func renameSession(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usingTmux, !trimmed.isEmpty, trimmed != activeTmuxSessionName else { return }
        tmuxService.sendFireAndForget(.renameSession(name: trimmed))
        activeTmuxSessionName = trimmed   // optimistic; %session-renamed reconciles
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await refreshTmuxSessions()
        }
    }

    public func newWindow(name: String? = nil) {
        tmuxService.sendFireAndForget(.newWindow(name: name))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshWindows()
            await refreshPanes()
        }
    }

    /// Rename the active tmux window (the session menu's "Rename Window…").
    public func renameWindow(to newName: String) {
        guard let id = activeWindowID else { return }
        renameWindow(id, to: newName)
    }

    /// Rename a specific window — the sidebar's per-row "Rename Window…".
    ///
    /// Note this turns tmux's `automatic-rename` off for that window, which is
    /// what the user is asking for by naming it: the name stops tracking the
    /// running command and starts meaning what they typed.
    public func renameWindow(_ id: TmuxWindowID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usingTmux, !trimmed.isEmpty else { return }
        tmuxService.sendFireAndForget(.renameWindow(id: id, name: trimmed))
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await refreshWindows()
        }
    }

    /// Close the active tmux window. Closing the session's last window ends the
    /// session (tmux semantics).
    public func closeWindow() {
        guard let id = activeWindowID else { return }
        closeWindow(id)
    }

    /// Close a specific window (List mode's per-row close). Kills its
    /// processes; closing the session's last window ends the session.
    public func closeWindow(_ id: TmuxWindowID) {
        guard usingTmux else { return }
        tmuxService.sendFireAndForget(.killWindow(id: id))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshWindows()
            await refreshPanes()
        }
    }

    public func selectWindow(_ windowID: TmuxWindowID) {
        tmuxService.sendFireAndForget(.selectWindow(id: windowID))
        // Reflect the switch immediately (the tab highlight shouldn't wait for
        // the refresh round-trip); refreshWindows below reconciles authoritatively.
        activeWindowID = windowID
        for i in windows.indices { windows[i].isActive = (windows[i].id == windowID) }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await refreshPanes()
            await refreshWindows()
        }
    }

    // MARK: - Direct Input (non-tmux fallback)

    public func sendData(_ data: Data) {
        if usingTmux, let activePaneID,
           let paneVM = paneViewModels.first(where: { $0.paneID == activePaneID }) {
            paneVM.sendInput(data)
        } else {
            predictor.willSend(data)   // draw the prediction; doesn't alter what's sent
            transport.write(data)
        }
    }

    public func sendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendData(data)
    }

    /// Unlock the remote Mac's login keychain using stored password
    private func unlockMacKeychain() async {
        guard let password = await environment.loadKeychainPassword("macKeychain:\(host.id.uuidString)") else {
            dlog("No keychain password stored")
            return
        }
        let cmd = "security unlock-keychain -p \(shellEscape(password)) ~/Library/Keychains/login.keychain-db\n"
        transport.write(cmd)
        dlog("Sent keychain unlock command")
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func resizeTerminal(cols: Int, rows: Int) {
        // Remember the surface's authoritative grid so a (re)connect can start
        // the shell at the SAME size. Without this, a resize that fires before
        // the transport finishes connecting is lost, and startShell falls back
        // to the ideal/default size — leaving the remote PTY a different width
        // than what's rendered (e.g. an 80×24 PTY behind a 41-column surface),
        // so the prompt/TUI wraps wrong.
        if cols > 0, rows > 0 { lastReportedSize = (cols, rows) }
        transport.resize(cols: cols, rows: rows)
    }

    /// Resize the tmux control-mode client viewport. Tmux propagates this to
    /// each visible pane (SIGWINCH on the remote shell). Used when the visible
    /// area changes for a single-pane / zoomed / focused session so the active
    /// pane fills exactly the area above the keyboard — same UX as non-tmux.
    ///
    /// Gated on the sizing mode HERE rather than at each call site: a policy has
    /// to hold against every path that could push a size (live resize, zoom,
    /// font change, keyboard avoidance), and one of them being missed is what a
    /// half-applied policy looks like.
    ///
    /// Under `latest` and `smallest` every client SHOULD keep declaring its own
    /// grid — that is the input tmux computes from, and `smallest` needs all of
    /// them to be current. Under `manual` only the owner speaks, via
    /// `resize-window`; `refresh-client -C` is ignored by tmux there, which is
    /// what made the old one-shot "fit" silently do nothing.
    public func resizeTmuxClient(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        lastTmuxClientSize = (cols, rows)
        guard usingTmux else { return }
        switch sizingMode {
        case .tracking, .smallest:
            tmuxService.sendFireAndForget(.refreshClient(width: cols, height: rows))
        case .thisDevice:
            guard sizingOwnerIsMe else { return }
            // Keep our client viewport honest too, so `#{client_width}` and any
            // later switch back to a client-derived policy start from the truth.
            tmuxService.sendFireAndForget(.refreshClient(width: cols, height: rows))
            Task { [weak self] in await self?.pushOwnedWindowSize() }
        }
    }

    /// Change who governs the window size, persist it, and put the matching
    /// policy into tmux. See `TerminalSizingMode` for why this is a state.
    public func setSizingMode(_ mode: TerminalSizingMode) {
        sizingMode = mode
        if let session = activeTmuxSessionName {
            TerminalSizingMode.store(mode, for: session)
        }
        Task { [weak self] in
            guard let self else { return }
            await self.applySizingMode(mode)
            // Leaving `manual` must re-assert this client immediately, or the
            // window keeps whatever the owner froze it at until something else
            // happens to resize.
            if mode != .thisDevice { self.resetTmuxClientToDeviceSize() }
        }
    }

    /// Adopt the session's server-side sizing policy on attach. Named for what
    /// it does NOT do: the old `restoreSizingMode` re-asserted this device's
    /// local preference onto the server, so whichever device attached last won
    /// — and an iPad in a reconnect loop overwrote the Mac's choice every ~50s.
    func restoreSizingMode(for session: String) {
        // Show the last mode we saw immediately; the server read replaces it.
        sizingMode = TerminalSizingMode.stored(for: session) ?? .tracking
        Task { [weak self] in await self?.adoptSizingPolicy() }
    }

    /// User-triggered: make the session fit THIS device. Under a client-derived
    /// policy that is a `refresh-client` re-announcement (needed because our
    /// automatic pushes are deduplicated, so a shrink by another client would
    /// otherwise never be answered). Under `manual` it means "take the size
    /// over", since a `refresh-client` there is ignored by tmux.
    public func resetTmuxClientToDeviceSize() {
        guard usingTmux else { return }
        if sizingMode == .thisDevice, !sizingOwnerIsMe {
            setSizingMode(.thisDevice)
            return
        }
        let (cols, rows) = lastTmuxClientSize ?? idealTerminalSize()
        tmuxService.sendFireAndForget(.refreshClient(width: cols, height: rows))
        if sizingMode == .thisDevice {
            Task { [weak self] in await self?.pushOwnedWindowSize() }
        }
    }

    /// Kill THIS window's session, over this window's own control channel.
    ///
    /// The channel is the only thing that knows which tmux server the session
    /// is on. Shelling out to the local `tmux` binary instead — which is what
    /// the macOS window used to do — kills whatever the *local* server has by
    /// that name, and for a session on an ssh host that is a different session
    /// with different processes in it.
    ///
    /// It is `async` because the fire-and-forget version raced: `disconnect()`
    /// tears the pty down, and a `kill-session` still sitting in the write
    /// buffer died with it, leaving the session alive and the next poll
    /// resurrecting it. Awaiting the response means tmux has acted (or the
    /// send timed out, on a connection already broken enough that the session
    /// is unreachable anyway) before anything is torn down.
    public func killSession() async {
        if usingTmux, let name = activeTmuxSessionName {
            let resp = await tmuxService.send(.killSession(name: name), timeout: .seconds(5))
            // tmux commonly kills the client along with the session, so a
            // timeout here is expected rather than a failure — log, don't warn.
            if resp.isError { dlog("kill-session \(name): \(resp.output)") }
        }
        disconnect()
    }

    public func disconnect() {
        userInitiatedDisconnect = true
        isReconnecting = false
        reconnectTask?.cancel()
        reconnectTask = nil
        statePollingTask?.cancel()
        statePollingTask = nil
        transport.disconnect()
        // Fail any in-flight tmux commands and drop parser state so a later
        // fresh connect on this VM starts clean.
        let service = tmuxService
        tmuxParseQueue.async { service.reset() }
        let priorName = activeTmuxSessionName ?? ""
        usingTmux = false
        isTmuxReady = false
        phase = .ended
        paneViewModels = []
        rawHistory.removeAll(keepingCapacity: false)
        environment.onSessionUpdate(host.id, priorName, 0, "")
    }

    /// Called when the app enters background. SSH will die naturally when iOS
    /// suspends the process; we just cancel the polling loop and mark the
    /// phase. tmux on the server keeps the session alive — re-attach on resume.
    public func suspendForBackground() {
        isInBackground = true
        // Any in-flight reconnect must be cancelled — it will only burn the
        // backoff counter while the process is suspended, surfacing a bogus
        // "Lost connection" alert when the user unlocks.
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        isReconnecting = false
        statePollingTask?.cancel()
        statePollingTask = nil
        // Suspend regardless of phase. If the WS already died mid-handshake
        // we still want resume to retry rather than show an alert.
        // Remember where we were: if the socket survives the suspension,
        // resume restores this phase directly instead of reconnecting.
        switch phase {
        case .tmuxReady, .shellReady:
            phaseBeforeSuspend = phase
            phase = .suspended
        case .starting, .sshConnecting, .choosingSession:
            phaseBeforeSuspend = nil
            phase = .suspended
        case .suspended, .ended:
            break
        }
    }

    /// Called when the app returns to foreground. Revive the session if the
    /// live connection is gone. We recover from any non-live state — not just
    /// `.suspended` — because a reconnect that failed *before* the user
    /// backgrounded can leave `phase` stuck at `.sshConnecting`/`.ended`, and a
    /// foreground is exactly when the user expects a retry.
    public func resumeFromBackground() async {
        isInBackground = false
        switch phase {
        case .tmuxReady, .shellReady, .starting, .choosingSession:
            // Already live, or a connect is already progressing — nothing to do.
            return
        case .suspended, .ended, .sshConnecting:
            break
        }
        // Fast path: the socket usually SURVIVES a background suspension (iOS
        // freezes the process; it does not close TCP). Probe it — if alive,
        // keep the connection: output that queued while frozen flushes through
        // on its own, nothing was torn down, resume is instant. Tearing down a
        // healthy connection here was the main source of "reconnects on every
        // unlock even though nothing was wrong".
        if phase == .suspended, let prior = phaseBeforeSuspend,
           case .connected = transport.state {
            if await transport.probeLiveness() {
                dlog("resume: connection survived suspension — restoring \(String(describing: prior)), no reconnect")
                phaseBeforeSuspend = nil
                phase = prior
                if prior == .tmuxReady {
                    startStatePolling()
                    // Catch up on anything that changed while frozen (layout,
                    // new/killed panes) — output already replays by itself.
                    Task {
                        await self.refreshPanes()
                        await self.refreshWindows()
                    }
                }
                return
            }
            dlog("resume: probe failed — socket died during suspension")
        }
        phaseBeforeSuspend = nil
        dlog("Resuming session for \(self.host.hostname) (\(String(describing: self.phase)) → reconnect)")
        scheduleReconnect()
    }

    /// Run a fresh SSH connect and re-attach to whatever tmux session was
    /// active (if any). Returns whether the session came back up. Used only by
    /// the auto-reconnect loop.
    ///
    /// We do NOT wipe `paneViewModels` here: that briefly empties the list and
    /// then refills it with the same IDs in one synchronous hop, which the host
    /// coalesces into "no change" and so never rebinds the surfaces — they stay
    /// wired to the discarded PaneViewModel instances while live `%output` lands
    /// in fresh, surface-less ones (history fills but nothing paints, the
    /// "looks dead after reconnect" bug). Keeping the list lets
    /// `updatePaneViewModels` reuse the existing instances by ID, so each
    /// surface's binding — and its replayed history — survives the reconnect.
    @discardableResult
    private func reattachExistingSession() async -> Bool {
        // NOTE: we do NOT call transport.disconnect() here. Connecting already
        // replaces the previous client, and the transport gates every client
        // callback on "am I still the active client?" (SSHService compares
        // ObjectIdentifier) — so a discarded client can never deliver a stale
        // `.failed` that would spuriously re-trigger reconnect (the "constantly
        // reconnecting" loop). Tearing down via disconnect()'s deferred Task
        // instead raced the fresh client.
        usingTmux = false
        isTmuxReady = false
        failedDuringReattach = false
        // Stop the pollers FIRST. The reconnect path (unlike disconnect/
        // suspend) used to leave state polling running, so list-panes kept
        // firing into the half-built connection — typed into the raw shell
        // before tmux -CC starts, with each orphaned continuation queueing up
        // in front of the new session's real responses (off-by-N mismatch,
        // timeout storm, watchdog re-reconnect loop). launchTmux restarts
        // polling once the session is actually ready.
        statePollingTask?.cancel()
        statePollingTask = nil
        layoutChangeDebounce?.cancel()
        layoutChangeDebounce = nil
        // The dead connection's protocol state is garbage: a truncated
        // response block and orphaned continuations would swallow the new
        // stream's notifications / steal its responses (the "input works but
        // nothing renders" zombie). Reset ON the parse queue so it runs after
        // any stale feedData already enqueued there — the new connection's
        // bytes can only be enqueued later, so ordering is safe.
        let service = tmuxService
        tmuxParseQueue.async { service.reset() }

        guard await bringUpTransport() != nil else { return false }

        guard let name = activeTmuxSessionName else {
            // Raw-shell session: the fresh shell already streams to the
            // surface once the phase is live again.
            phase = .shellReady
            return !failedDuringReattach
        }
        // Skip session discovery entirely — we know the session name, and
        // `tmux -CC new-session -A` attaches-or-creates in one step.
        // resizeToScreen:false preserves the session's server-side geometry.
        await launchTmux(sessionName: name, groupWith: nil, resizeToScreen: false)
        if isTmuxReady {
            await reseedAllPanes()
        }
        // `isTmuxReady` only says the attach handshake worked. The seed above
        // is the heaviest burst this connection ever carries, and on the iPad
        // it is exactly where the socket kept dying — leaving a session
        // that looks ready but never receives another byte. Treat a failure
        // anywhere in this attempt as a failed attempt so the loop retries now
        // rather than after the poll watchdog eventually notices.
        if failedDuringReattach {
            dlog("reattach: transport failed mid-attempt (likely during seed) — not reporting success")
            return false
        }
        return isTmuxReady
    }

    /// After a reattach, the reused PaneViewModels' surfaces still show the
    /// pre-suspend screen — tmux does not repaint static content for a new
    /// control client, so anything that changed while we were gone would be
    /// missing until the program next redraws. Re-seed every pane with a
    /// capture-pane snapshot (clear + home first, so the snapshot REPLACES the
    /// stale screen instead of appending below it).
    private func reseedAllPanes() async {
        for paneVM in paneViewModels {
            // Deliberately ONE SCREEN, unlike the fresh-pane seed
            // (`seedHistoryLines`): these surfaces are REUSED and already hold
            // the history from before the suspend. A deep capture here would feed
            // all of it a second time and leave the scrollback duplicated — the
            // clear+home below only clears the visible screen, not the scrollback
            // above it.
            let lines = paneVM.pane.height > 0 ? paneVM.pane.height : 50
            let resp = await tmuxService.send(.capturePane(id: paneVM.paneID, lines: lines, escapes: true))
            guard !resp.isError else { continue }
            let clean = Self.stripControlModeChatter(resp.output)
            let termText = clean.replacingOccurrences(of: "\n", with: "\r\n")
            var data = Data("\u{1b}[2J\u{1b}[H".utf8)
            data.append(Data(termText.utf8))
            paneVM.feedData(data)
            if let raw = clean.data(using: .utf8) {
                stateDetection.recordOutput(pane: paneVM.paneID, data: raw)
            }
        }
        await updatePaneStates()
    }

    // MARK: - Auto-reconnect

    /// Decide what to do when the SSH transport reports `.failed` mid-session.
    /// User-initiated tear-downs and pre-handshake failures surface the error
    /// to the user as before; transient failures during an established
    /// session (Wi-Fi blip, half-open WS, CF DO recycle) schedule a quiet
    /// reconnect with backoff.
    private func handleUnexpectedFailure(message: String) {
        guard !userInitiatedDisconnect else { return }
        // A reconnect loop is already running and owns recovery — its own
        // attempts surface transient `.failed` states we must not treat as
        // fresh failures (they'd spawn a duplicate error alert). Record it
        // though: an attempt that brought tmux up and THEN lost the socket
        // (mid-seed) must not be reported as a success.
        guard !isReconnecting else {
            failedDuringReattach = true
            return
        }
        // If the app is backgrounded (lock screen, app switcher) the WS is
        // expected to die. Absorb the failure silently and let
        // `resumeFromBackground` retry on unlock.
        if isInBackground || phase == .suspended {
            reconnectTask?.cancel()
            reconnectTask = nil
            phase = .suspended
            return
        }
        let recoverable: Bool
        switch phase {
        case .tmuxReady, .shellReady, .starting:
            recoverable = true
        case .sshConnecting, .choosingSession, .suspended, .ended:
            recoverable = false
        }
        guard recoverable else {
            errorMessage = message
            showError = true
            return
        }
        scheduleReconnect()
    }

    /// Start a reconnect loop. Idempotent: a no-op while one is already running,
    /// backgrounded, or after a user-initiated tear-down. Drives `isReconnecting`
    /// so the UI shows progress instead of a frozen pane.
    private func scheduleReconnect() {
        guard reconnectTask == nil, !userInitiatedDisconnect, !isInBackground else { return }
        reconnectAttempt = 0
        isReconnecting = true
        errorMessage = nil
        showError = false
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    /// Reconnect with exponential backoff until the session is back or the
    /// attempt budget is spent. On giving up it surfaces an actionable error
    /// (the alert offers Retry → `retry()`), never a silent dead state.
    private func runReconnectLoop() async {
        defer {
            isReconnecting = false
            reconnectTask = nil
        }
        while !Task.isCancelled {
            if userInitiatedDisconnect || isInBackground { return }
            reconnectAttempt += 1
            dlog("auto-reconnect attempt \(self.reconnectAttempt)")
            if await reattachExistingSession() {
                reconnectAttempt = 0
                return
            }
            if Task.isCancelled || userInitiatedDisconnect || isInBackground { return }
            // Fast backoff (1/2/4/8s) for the first attempts, then settle into a
            // steady 15s cadence FOREVER. The old behavior gave up after 5
            // attempts with a dead-end alert — but the outage that strands a
            // phone (asleep in a pocket, off Wi-Fi, roaming onto cellular) has
            // no upper bound, so any fixed budget just guarantees a corpse
            // screen: the "reconnecting 卡住" the user actually experienced.
            // The tmux session is still there whenever the network returns.
            // Backgrounding still cancels the loop.
            let delaySec = reconnectAttempt >= 5 ? 15 : 1 << (reconnectAttempt - 1)
            dlog("reconnect failed; retrying in \(delaySec)s")
            try? await Task.sleep(for: .seconds(delaySec))
        }
    }

    /// Two consecutive poll commands got no response: the session is dead in
    /// a way no transport layer reported. Force the reconnect path — it tears
    /// the half-dead connection down and attaches a fresh shell.
    private func noteCommandTimeout() {
        commandTimeoutStreak += 1
        guard commandTimeoutStreak >= 2 else { return }
        // Only spend the streak on an attempt that can actually run. Resetting
        // before the guard threw the tripwire away whenever we happened to be
        // mid-reconnect or not yet `.tmuxReady`, so a wedged session needed
        // FOUR timeouts (~48s on the iPad log) instead of two to be noticed.
        guard phase == .tmuxReady, !isReconnecting, !isInBackground, !userInitiatedDisconnect else { return }
        commandTimeoutStreak = 0
        dlog("tmux stopped answering (2 consecutive command timeouts) — forcing reconnect")
        scheduleReconnect()
    }

    /// User-driven retry from the connection-error alert: clear the give-up
    /// state and start a fresh reconnect loop.
    public func retry() {
        guard !isReconnecting else { return }
        userInitiatedDisconnect = false
        scheduleReconnect()
    }

    // MARK: - State Detection

    private func startStatePolling() {
        // Idempotent: never stack a second poller — each leaked poller adds
        // another list-panes every 2s and floods the response queue.
        statePollingTask?.cancel()
        statePollingTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { break }
                // Re-query panes so per-pane mouse-mode flags (mouse_any/sgr) stay
                // current — tmux -CC never streams the program's mouse-enable, so
                // polling list-panes is how the GUI learns to forward the mouse.
                await self.refreshPanes()
                await self.updatePaneStates()
                // Every third tick (~6s), re-read the session list from THIS
                // connection's server. One extra `list-sessions` per window is
                // cheap even over ssh, and it is what lets a window notice that
                // its session was killed from somewhere else — on whichever
                // machine that session actually lives.
                tick += 1
                if tick % 3 == 0 { await self.refreshTmuxSessions() }
            }
        }
    }

    private func updatePaneStates() async {
        var changed = false
        var awaitingCount = 0
        var sawNewAwaiting = false
        var latestPrompt = ""
        var agentWorking = 0
        var agentWaiting = 0
        var agentDoneUnseen = 0

        var newStates: [TmuxPaneID: PaneState] = [:]
        var newDone: [TmuxPaneID: Bool] = [:]

        for paneVM in paneViewModels {
            let current = paneVM.paneState
            let (newState, isAgent) = await classifyPane(
                id: paneVM.paneID, command: paneVM.pane.currentCommand,
                title: paneVM.pane.title ?? "", current: current)
            newStates[paneVM.paneID] = newState

            if paneVM.paneState != newState {
                // Transition INTO awaiting/blocked — fire haptic + snippet.
                if case .awaitingInput = newState {
                    sawNewAwaiting = true
                    let snippet = stateDetection.recentText(for: paneVM.paneID, lines: 3)
                    if !snippet.isEmpty { latestPrompt = snippet }
                }
                paneVM.paneState = newState
                changed = true
            }

            if updateSeen(paneVM, from: current, to: newState, isAgent: isAgent) {
                changed = true
            }
            newDone[paneVM.paneID] = paneVM.agentFinishedUnseen

            if case .awaitingInput = paneVM.paneState {
                awaitingCount += 1
            }

            // Tally agent activity for the toolbar's center summary.
            if isAgent {
                if paneVM.agentFinishedUnseen { agentDoneUnseen += 1 }
                switch paneVM.paneState {
                case .working:       agentWorking += 1
                case .awaitingInput: agentWaiting += 1
                case .idle:          break
                }
            }
        }

        // Background-window panes (no live surface / PaneViewModel) go through
        // the SAME pipeline, so the window list's state can't disagree with what
        // the Tiled chrome would show. They're never focused, so "done, unseen"
        // is judged with isFocused:false. Replacing the whole dicts also drops
        // entries for panes that closed.
        let live = Set(paneViewModels.map(\.paneID))
        for pane in sessionPanes where !live.contains(pane.id) {
            let current = paneStates[pane.id] ?? .idle
            let (state, isAgent) = await classifyPane(
                id: pane.id, command: pane.currentCommand,
                title: pane.title ?? "", current: current)
            newStates[pane.id] = state
            if paneStates[pane.id] != state { changed = true }

            let done = Self.doneUnseen(isAgent: isAgent, isFocused: false,
                                       current: current, newState: state,
                                       prev: paneDoneUnseen[pane.id] ?? false)
            newDone[pane.id] = done
            if (paneDoneUnseen[pane.id] ?? false) != done { changed = true }
        }
        paneStates = newStates
        paneDoneUnseen = newDone

        if changed {
            stateVersion += 1
        }
        if agentsWorking != agentWorking { agentsWorking = agentWorking }
        if agentsWaiting != agentWaiting { agentsWaiting = agentWaiting }
        if agentsDoneUnseen != agentDoneUnseen { agentsDoneUnseen = agentDoneUnseen }
        if sawNewAwaiting {
            environment.onAwaitingTriggered()
        }
        // Fan into SessionManager so the aggregate Live Activity recomputes
        // across all live sessions.
        environment.onSessionUpdate(host.id, activeTmuxSessionName ?? "", awaitingCount, latestPrompt)
    }

    /// THE per-pane state judgment — the single pipeline behind both the Tiled
    /// pane chrome and the List window dots. Recognized coding agents go through
    /// the region/priority rule engine (title is the cheap pass; a spinner
    /// resolves to .working with no tmux round-trip — otherwise capture the live
    /// screen and re-classify). Everything else stays on the legacy
    /// activity/profile path.
    private func classifyPane(id: TmuxPaneID, command: String?, title: String,
                              current: PaneState) async -> (state: PaneState, isAgent: Bool) {
        switch stateDetection.classifyAgent(command: command, title: title, snapshot: nil,
                                            pane: id, current: current) {
        case .notAgent:
            return (stateDetection.detectState(pane: id, currentCommand: command, title: title), false)
        case .state(let s):
            return (s, true)
        case .needsSnapshot:
            let snap = await captureSnapshot(id)
            if case .state(let s) = stateDetection.classifyAgent(
                command: command, title: title, snapshot: snap, pane: id, current: current) {
                return (s, true)
            }
            return (current, true)
        }
    }

    /// Fetch a pane's live visible screen (no scrollback, plain text) for the
    /// agent rule engine. nil on error.
    private func captureSnapshot(_ id: TmuxPaneID) async -> String? {
        let resp = await tmuxService.send(.capturePane(id: id, lines: nil))
        return resp.isError ? nil : resp.output
    }

    /// Maintain the "done, unseen" flag. An agent pane that transitions into
    /// .idle while unfocused becomes done(unseen); focusing it or leaving idle
    /// clears it. Returns true if the flag changed (so the UI repaints).
    @discardableResult
    private func updateSeen(_ paneVM: PaneViewModel, from current: PaneState,
                            to newState: PaneState, isAgent: Bool) -> Bool {
        let want = Self.doneUnseen(isAgent: isAgent, isFocused: paneVM.isActive,
                                   current: current, newState: newState,
                                   prev: paneVM.agentFinishedUnseen)
        guard paneVM.agentFinishedUnseen != want else { return false }
        paneVM.agentFinishedUnseen = want
        return true
    }

    /// Pure "done, unseen" transition, shared by live and background panes: an
    /// agent pane that goes idle while UNFOCUSED becomes done; staying idle
    /// keeps the memory; focusing it or leaving idle clears it.
    static func doneUnseen(isAgent: Bool, isFocused: Bool, current: PaneState,
                           newState: PaneState, prev: Bool) -> Bool {
        guard isAgent, isIdle(newState), !isFocused else { return false }
        return isIdle(current) ? prev : true
    }

    private static func isIdle(_ s: PaneState) -> Bool {
        if case .idle = s { return true }
        return false
    }
}
