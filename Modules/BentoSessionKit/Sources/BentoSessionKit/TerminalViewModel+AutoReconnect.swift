import Foundation
import SwiftUI
import os
import BentoTmuxKit
import BentoFoundationKit

extension TerminalViewModel {
    // MARK: - Auto-reconnect

    /// Decide what to do when the SSH transport reports `.failed` mid-session.
    /// User-initiated tear-downs and pre-handshake failures surface the error
    /// to the user as before; transient failures during an established
    /// session (Wi-Fi blip, half-open WS, CF DO recycle) schedule a quiet
    /// reconnect with backoff.
    func handleUnexpectedFailure(message: String) {
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
        // What to say when we have nothing better. A failure before the session
        // exists is a bring-up problem and reads as one; "the connection was
        // lost" would describe a session that never started.
        var fallback = message
        switch phase {
        case .tmuxReady, .shellReady:
            recoverable = true
        case .starting:
            // `.starting` means the session has not come up yet. For a login
            // shell that is a blip during launch and worth retrying — the shell
            // is real, tmux is merely late.
            //
            // For a transport that IS the tmux invocation it means the remote
            // command died before tmux ever greeted: no tmux on the host, an
            // alias that doesn't resolve, a connection refused. None of those
            // get better by being retried every 15 seconds, and the loop would
            // bury the one useful thing we have — what the remote actually
            // said — under an endless "reconnecting". Report it instead.
            recoverable = !transport.startsInTmuxControlMode
            if !recoverable { fallback = "Couldn’t start tmux on \(host.name)." }
        case .sshConnecting, .choosingSession, .suspended, .ended:
            recoverable = false
        }
        guard recoverable else {
            failWithRemoteDiagnosis(
                fallback: fallback,
                // Only the tmux-never-started branch above rewrites `fallback`;
                // the others are carrying a transport message that is already
                // its own explanation.
                hint: fallback == message ? nil : tmuxStartupHint)
            return
        }
        scheduleReconnect()
    }

    /// What to check when tmux never greeted, or nil when the far side named a
    /// failure that has nothing to do with tmux (a refused connection, a
    /// host-key complaint, `Permission denied`) — a tmux suggestion under one
    /// of those is just noise on top of the real answer.
    var tmuxStartupHint: String? {
        // Judge on the RAW tail, not the line-buffered lines: a connection stuck
        // on `host's password: ` has no newline to make that text a line, so the
        // line view reads as "the remote said nothing" and this hint used to
        // blame tmux for an unanswered password prompt. (That prompt now gets
        // its own sheet, so reaching here means it went unanswered.)
        let remote = tmuxService.rawTextBeforeControlMode.lowercased()
        if let prompt = detectSSHAuthPrompt(inTailOf: tmuxService.rawTextBeforeControlMode) {
            return "\(host.name) is still waiting on: \(prompt.text)"
        }
        guard remote.isEmpty || remote.contains("tmux") else { return nil }
        return """
            Check that tmux is installed on \(host.name) and on the PATH your \
            login shell builds:

            ssh \(host.name) '$SHELL -lc "command -v tmux"'
            """
    }

    /// Surface a bring-up failure, preferring whatever the far side said over
    /// our own guess at it.
    ///
    /// `ssh` and the remote shell write the actual diagnosis to stderr —
    /// `tmux: command not found`, `Could not resolve hostname`, `Permission
    /// denied (publickey)`, a host-key warning — and it arrives on the same pty
    /// as the control-mode stream. The parser drops it, being unparseable
    /// protocol, so every one of those failures used to present as the same
    /// blank window. `outputBeforeControlMode` keeps it; this is where it is
    /// spent.
    func failWithRemoteDiagnosis(fallback: String, hint: String? = nil) {
        // First diagnosis wins. The pty's EOF and the greeting timeout describe
        // the same failure from two ends, and the EOF gets there ~12s earlier;
        // letting the later one through would only overwrite it with a vaguer
        // version of itself.
        guard !showError else { return }
        let remote = tmuxService.outputBeforeControlMode
            .trimmingCharacters(in: .whitespacesAndNewlines)
        dlog("session bring-up failed: \(fallback) | remote said: \(remote.isEmpty ? "<nothing>" : remote)")
        // Order: our summary, then what the far side actually said, then what to
        // check. The remote's own words are the most specific thing on screen
        // and must not be buried under a suggestion.
        errorMessage = [fallback, remote.isEmpty ? nil : remote, hint]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        showError = true
        phase = .ended
        // Stop retrying. This verdict can be reached from inside the reconnect
        // loop (an attempt that got a connection but no tmux), and the loop's
        // policy is otherwise to retry every 15s forever — correct for a
        // network that might come back, wrong for a host that has no tmux on
        // it, where it would just spawn an ssh a minute behind a dialog the
        // user has already read. Cancelling is safe from within: the loop
        // checks `Task.isCancelled` each pass, and its own `defer` clears
        // `reconnectTask`.
        reconnectTask?.cancel()
        isReconnecting = false
        statePollingTask?.cancel()
        statePollingTask = nil
    }

    /// Start a reconnect loop. Idempotent: a no-op while one is already running,
    /// backgrounded, or after a user-initiated tear-down. Drives `isReconnecting`
    /// so the UI shows progress instead of a frozen pane.
    func scheduleReconnect() {
        guard reconnectTask == nil, !userInitiatedDisconnect, !isInBackground else { return }
        reconnectAttempt = 0
        isReconnecting = true
        errorMessage = nil
        showError = false
        // The state poll (which re-derives it) is about to stop, so retire the
        // take-over banner here rather than leave a claim about a session we
        // are no longer attached to.
        noteSizingInputsChanged()
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    /// Reconnect with exponential backoff until the session is back or the
    /// attempt budget is spent. On giving up it surfaces an actionable error
    /// (the alert offers Retry → `retry()`), never a silent dead state.
    func runReconnectLoop() async {
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
    func noteCommandTimeout() {
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

}
