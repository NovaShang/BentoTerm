import Foundation
import SwiftUI
import os
import BentoTmuxKit
import BentoAgentKit
import BentoFoundationKit

extension TerminalViewModel {
    // MARK: - Direct Input (non-tmux fallback)

    public func sendData(_ data: Data) {
        if usingTmux, let activePaneID,
           let paneVM = paneViewModels.first(where: { $0.paneID == activePaneID }) {
            dlog("[sendData] \(data.count)B → paneVM \(activePaneID)")
            paneVM.sendInput(data)
        } else {
            dlog("[sendData] \(data.count)B → transport (usingTmux=\(usingTmux), activePaneID=\(String(describing: activePaneID)))")
            predictor.willSend(data)   // draw the prediction; doesn't alter what's sent
            transport.write(data)
        }
    }

    public func sendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendData(data)
    }

    /// Unlock the remote Mac's login keychain using stored password
    func unlockMacKeychain() async {
        guard let password = await environment.loadKeychainPassword("macKeychain:\(host.id.uuidString)") else {
            dlog("No keychain password stored")
            return
        }
        let cmd = "security unlock-keychain -p \(shellEscape(password)) ~/Library/Keychains/login.keychain-db\n"
        transport.write(cmd)
        dlog("Sent keychain unlock command")
        try? await Task.sleep(for: .milliseconds(300))
    }

    func shellEscape(_ s: String) -> String {
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
        // Half of the banner's comparison just moved (this device's grid),
        // whether or not the policy lets us declare it.
        defer { noteSizingInputsChanged() }
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
        noteSizingInputsChanged()
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
        // Declare the intent BEFORE the kill, not after.
        //
        // Killing a session usually kills the client attached to it, and over
        // ssh that ends the whole `ssh -t host "tmux -CC …"` command — so the
        // pty reaches EOF while we are still awaiting tmux's reply, several
        // hundred milliseconds before `disconnect()` below would have set this.
        // In that window an EOF reads as a dropped link, and the recovery it
        // triggers is `new-session -A`, which CREATES: Kill Session would
        // reconnect and hand back a brand-new empty session of the same name on
        // the same host. The flag is what tells the failure path this teardown
        // was asked for.
        userInitiatedDisconnect = true
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
        layoutChangeDebounce?.cancel()
        layoutChangeDebounce = nil
        windowsRefreshRetry?.cancel()
        windowsRefreshRetry = nil
        // A pending debounce would otherwise fire refreshPanes against the dead
        // service (each send pays the full 10s timeout), and queued %output
        // would still drain onto the torn-down VM.
        pendingTmuxNotifications.withLock { $0.queue.removeAll() }
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
        layoutChangeDebounce?.cancel()
        layoutChangeDebounce = nil
        windowsRefreshRetry?.cancel()
        windowsRefreshRetry = nil
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
    func reattachExistingSession() async -> Bool {
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
        await launchTmux(sessionName: name, groupWith: nil, resizeToScreen: false,
                         awaitShellFirst: true)
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
    func reseedAllPanes() async {
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

}
