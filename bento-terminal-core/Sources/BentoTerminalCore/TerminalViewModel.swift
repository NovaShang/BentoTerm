import Foundation
import SwiftUI
import os
import BentoTmuxKit
import BentoFoundationKit

let log = Logger(subsystem: "com.novashang.bento", category: "TerminalVM")

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
    @Published public var sessionPanes: [Pane] = []
    /// The user-facing "Tiled | List" state, recomputed from structure on
    /// every pane refresh. Degenerate (1×1) sessions present as Tiled unless
    /// the user explicitly chose List (`@bento_mode`); mixed external
    /// structures read as Tiled. See TerminalViewModel+Structure.swift.
    @Published public var sessionMode: TmuxSessionMode = .tiled
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

    /// Whether `availableTmuxSessions` reflects an answer we actually received.
    /// False until the first listing completes, and it stays false if that
    /// listing times out — because `[]` then means "we don't know", not "this
    /// host has nothing", and the two must not be confused where the list
    /// decides whether we are creating a session or joining one.
    var sessionListIsTrustworthy = false

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
    @Published public var sessionListGeneration: Int = 0

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
    nonisolated(unsafe) var rawHistory = Data()
    static let maxRawHistoryBytes = 256 * 1024

    /// Push predicted keystrokes (Mosh-style local echo) to the surface as a
    /// preedit overlay. Set by the host wiring (raw/no-tmux path only) to the
    /// active surface's `setPredictedText`. See `predictor`.
    public var onPredictionText: ((String) -> Void)?

    /// Predictive local echo for the raw path. Inert unless the feature flag is
    /// on; only ever touches an overlay, never the authoritative grid.
    lazy var predictor: PredictiveEcho = {
        let p = PredictiveEcho(enabled: Self.predictiveEchoEnabled)
        p.render = { [weak self] text in self?.onPredictionText?(text) }
        return p
    }()

    /// Feature flag (Settings / UserDefaults). Off unless explicitly enabled.
    public nonisolated static var predictiveEchoEnabled: Bool {
        UserDefaults.standard.bool(forKey: "predictive_echo_enabled")
    }

    /// Whether we're using tmux control mode
    nonisolated(unsafe) var usingTmux = false

    /// Active tmux session name (used for kill-session etc).
    @Published public var activeTmuxSessionName: String?

    /// Shell-output capture state (for `tmux ls` and similar commands run in
    /// raw shell mode before we hand off to either the terminal or tmux -CC).
    struct ShellCapture {
        var buffer: Data = Data()
        var marker: String
        /// `nil` means the end marker never arrived — see `captureShellOutput`.
        var continuation: CheckedContinuation<String?, Never>
    }
    var shellCapture: ShellCapture? {
        // Mirrored into a lock so the off-main router can consult it without
        // hopping to the main actor just to read one optional.
        didSet {
            let active = shellCapture != nil
            captureActive.withLock { $0 = active }
        }
    }
    nonisolated let captureActive = OSAllocatedUnfairLock(initialState: false)

    /// True while we're waiting on a scheduled auto-reconnect attempt. The
    /// onStateChanged hook checks this so an in-flight retry's transient
    /// `.failed` doesn't get treated as a fresh failure (and spawn nested
    /// reconnect tasks).
    var reconnectTask: Task<Void, Never>?
    var reconnectAttempt = 0
    /// The surface's last reported grid (cols, rows). Used to start the shell at
    /// the rendered size so the remote PTY width always matches the surface.
    var lastReportedSize: (cols: Int, rows: Int)?
    /// Set true by `disconnect()` / host deletion so we don't try to revive
    /// a session the user explicitly tore down.
    var userInitiatedDisconnect = false
    /// True while the app is backgrounded (or transitioning there). Used to
    /// suppress error alerts and reconnect attempts that would otherwise
    /// surface when iOS suspends the process and tears down the WS — those
    /// failures are expected and handled by `resumeFromBackground`.
    var isInBackground = false
    /// The live phase (`.tmuxReady`/`.shellReady`) captured when the session
    /// was suspended. If the transport survives the suspension (probed on
    /// resume), the phase is restored directly — no reconnect.
    var phaseBeforeSuspend: SessionPhase?
    /// Consecutive state-poll commands that timed out with no response.
    /// A transport can be half-dead in ways no layer reports: the WS answers
    /// pings but the remote shell is gone, so tmux never replies while the
    /// screen sits frozen and "connected". Two straight timeouts (~25s) is
    /// the universal tripwire — it works over any transport.
    var commandTimeoutStreak = 0
    /// Set when the transport reports `.failed` DURING a reconnect attempt.
    /// `handleUnexpectedFailure` can't act on those (a reconnect already owns
    /// recovery), but silently dropping them let a dead attempt report success:
    /// the seed burst at the end of `reattachExistingSession` is where the
    /// SSH channel actually died on the iPad, and because `isReconnecting` was
    /// still true nobody noticed until the poll watchdog fired ~48s later — then
    /// the next attempt died the same way, forever. The attempt now reads this
    /// flag and retries instead.
    var failedDuringReattach = false

    var layoutChangeDebounce: Task<Void, Never>?
    /// Retry for a raced `list-windows` parse (see `refreshWindows`).
    var windowsRefreshRetry: Task<Void, Never>?
    var statePollingTask: Task<Void, Never>?

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
    nonisolated let tmuxParseQueue = DispatchQueue(label: "com.novashang.bento.tmux-parse", qos: .userInitiated)

    /// Notifications parsed off-main are queued here and drained on the main
    /// actor in one hop, preserving total order (a %layout-change must stay
    /// ordered against the %output repaint that follows it) while coalescing
    /// bursts that would otherwise each pay their own main-actor hop.
    struct PendingTmuxNotifications {
        var queue: [TmuxNotification] = []
        var drainScheduled = false
    }
    nonisolated let pendingTmuxNotifications = OSAllocatedUnfairLock(initialState: PendingTmuxNotifications())

    /// Panes that can take output directly on the parse queue, keyed by id.
    /// Maintained on the main actor as panes come and go; read off-main here.
    nonisolated let outputSinks =
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

    func drainTmuxNotifications() {
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

    func setupCallbacks() {
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
    func routeIncomingData(_ data: Data) {
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

    func appendRawHistory(_ data: Data) {
        rawHistory.append(data)
        let overflow = rawHistory.count - Self.maxRawHistoryBytes
        if overflow > 0 {
            rawHistory.removeSubrange(0..<overflow)
        }
    }



    /// Synchronous hook invoked right after `%layout-change` geometry is applied,
    /// before the subsequent repaint output is processed. The view layer sets
    /// this to re-tile its surfaces. See `applyLayoutGeometry`.
    public var onGeometryApplied: (() -> Void)?

}
