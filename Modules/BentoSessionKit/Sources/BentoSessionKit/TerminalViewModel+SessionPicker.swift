import Foundation
import SwiftUI
import os
import BentoTmuxKit
import BentoFoundationKit

extension TerminalViewModel {
    // MARK: - Session Picker

    /// List the server's sessions into `availableTmuxSessions`.
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
            // Lines that aren't rows (stray pane output has been observed in
            // responses) fail the parser's numeric tail and are skipped.
            availableTmuxSessions = TmuxSessionListing.parse(response.output).map(\.name)
            sessionListIsTrustworthy = true
            dlog("Found tmux sessions (control): \(self.availableTmuxSessions)")
            // Answered by the server this connection is attached to — the only
            // list that can speak for this window's session.
            sessionListGeneration &+= 1
            return
        }

        // Typed into the shell, bracketed by markers so the answer can be cut
        // out of whatever OSC / CSI / syntax-highlight noise the shell injects.
        let probe = TmuxSessionListing.MarkerProbe()
        guard let output = await captureShellOutput(cmd: probe.command, marker: probe.endMarker,
                                                    timeoutMs: 5000) else {
            // Leave `availableTmuxSessions` alone. An empty list here does not
            // mean "this host has no sessions" — and `applyTmuxChoice` reads it
            // to decide whether it is creating a session or joining one, so a
            // wrong empty answer makes it resize an EXISTING session to this
            // device, shrinking the viewport for every other client attached to
            // it. Staleness is strictly safer than a fabricated empty.
            dlog("tmux ls timed out — keeping the previous session list")
            return
        }
        // The shell answered, so the list speaks for the host even when it is
        // empty — no server, or no tmux (the launch says so itself).
        switch probe.result(of: output) {
        case .success(let sessions):
            availableTmuxSessions = sessions.map(\.name)
        case .failure(let failure):
            availableTmuxSessions = []
            if failure != .noSessions { dlog("tmux ls: \(failure.message)") }
        }
        sessionListIsTrustworthy = true
        dlog("Found tmux sessions: \(self.availableTmuxSessions)")
    }

    /// Send a shell command and capture all output until `marker` is observed
    /// Output is consumed silently and not forwarded to the terminal.
    ///
    /// Returns `nil` if the marker never arrived. That is deliberately NOT the
    /// same as an empty result: this used to return whatever partial bytes had
    /// accumulated, so a slow login was indistinguishable from a host with
    /// nothing on it — and the caller then acted on the empty answer. See
    /// `refreshTmuxSessions`.
    func captureShellOutput(cmd: String, marker: String, timeoutMs: Int) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            shellCapture = ShellCapture(buffer: Data(), marker: marker, continuation: continuation)
            transport.write(cmd)

            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                guard let self else { return }
                await MainActor.run {
                    if let capture = self.shellCapture {
                        dlog("shell capture timed out after \(timeoutMs)ms with "
                            + "\(capture.buffer.count) byte(s) and no end marker")
                        self.shellCapture = nil
                        capture.continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    // Parsers / ANSI stripping live in the SwiftTmux package now.

    /// Apply the user's session choice. Called from the session picker UI.
    public func applyTmuxChoice(_ choice: TmuxStartChoice) async {
        phase = .starting
        // The kind is known HERE, from the choice — before the handshake that
        // `isTmuxReady` reports on, and independently of whether it succeeds.
        // That is the whole point: chrome that asks "is this tmux" gets an
        // answer while the session is still connecting.
        kind = .tmux
        switch choice {
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
                transport.startsInTmuxControlMode
                || !sessionListIsTrustworthy
                || availableTmuxSessions.contains(name)
            await launchTmux(
                sessionName: name,
                groupWith: nil,
                resizeToScreen: !isAttachToExisting
            )
        case .shareWithDesktop(let target):
            await launchTmux(sessionName: "\(target)-mobile", groupWith: target, resizeToScreen: false)
        }
    }

    func launchTmux(
        sessionName: String,
        groupWith: String?,
        resizeToScreen: Bool,
        awaitShellFirst: Bool = false
    ) async {
        usingTmux = true
        activeTmuxSessionName = sessionName
        // Normally already set by `applyTmuxChoice`. Re-asserted because a
        // reattach can reach this directly, and a session that is launching
        // tmux is a tmux session whatever route it took.
        kind = .tmux

        // When the transport carried the `tmux -CC` invocation as its own
        // argument, tmux is already coming up and there is nothing to type —
        // writing the launch line here would send it *through* control mode as
        // pane input. See `TerminalTransport.startsInTmuxControlMode` for why
        // that shape exists at all (it is what makes a host that prompts for a
        // password or a 2FA code work).
        if transport.startsInTmuxControlMode {
            dlog("tmux -CC launched by the transport itself — awaiting greeting")
        } else {
            // A reattach opens the shell and types this line in the same hop —
            // no `tmux ls`, no picker, nothing that would have proved a shell
            // is there yet. Written into a pty that has not finished spawning,
            // the line is swallowed, tmux never starts, and everything below
            // ends up speaking control-mode syntax at a bare prompt (observed:
            // `zsh: command not found: send-keys` on repeat, a session that
            // reports ready, and a reconnect loop that cannot converge).
            // A silent shell still gets the line, as before.
            if awaitShellFirst, !(await tmuxService.awaitAnyOutput(timeout: .seconds(3))) {
                dlog("no shell output within 3s of startShell — writing the launch line anyway")
            }
            let launchCmd = tmuxService.launchCommand(
                sessionName: sessionName, groupWith: groupWith)
            dlog("Launching tmux: \(launchCmd.trimmingCharacters(in: .whitespacesAndNewlines))")
            transport.write(launchCmd)
        }

        // Wait for the -CC greeting (its first %begin) instead of a fixed
        // sleep: commands sent before tmux attaches would be typed into the
        // plain shell. Faster than 1s when the shell is quick, tolerant when
        // it's slow (fresh login shell runs the full zshrc first).
        // 12s is the right patience for "tmux isn't coming" and the wrong
        // patience for "ssh is asking for a password" — the second one waits on
        // a person. See `awaitGreetingAllowingAuthPrompts`.
        let sawGreeting = await awaitGreetingAllowingAuthPrompts(timeout: .seconds(12))
        if !sawGreeting {
            // No greeting, and the transport IS the tmux invocation: there is
            // no shell on the far side to have been slow, so tmux is not coming
            // and everything below would be commands written into a closed pty.
            //
            // What used to happen instead is the reason this branch exists.
            // Pointing at a host with no tmux — the single likeliest first-run
            // mistake, since the product's premise is "any sshd plus tmux" —
            // left the window blank for 12 seconds and then "proceeded anyway"
            // into `tmux ready: 0 panes, 0 windows`: an empty session window
            // that answered nothing, forever, with each later command burning
            // its own 10s timeout. The remote had said exactly what was wrong
            // (`tmux: command not found`) in the first 50ms and the control-mode
            // parser had dropped it as unparseable.
            //
            // A login-shell transport keeps the old tolerance: there the wait is
            // genuinely racing a slow `.zshrc`, and the shell is still usable.
            if transport.startsInTmuxControlMode {
                dlog("tmux -CC never greeted — the remote command did not start tmux")
                failWithRemoteDiagnosis(
                    fallback: "Couldn’t start tmux on \(host.name).",
                    hint: tmuxStartupHint)
                return
            }
            // Proceeding used to be the tolerant choice here, on the theory
            // that a login shell might merely be slow. It is not tolerant: with
            // `usingTmux` already true, every later command is typed into that
            // shell, `isTmuxReady` is announced against a bare prompt, and the
            // poll watchdog reconnects into the same state forever. Twelve
            // seconds of silence is not a slow `.zshrc`; tmux is not coming.
            dlog("tmux -CC greeting not seen within 12s — tmux did not start")
            usingTmux = false
            if isReconnecting {
                // Let the reconnect loop retry with backoff rather than declare
                // a session that would type control commands at a shell.
                failedDuringReattach = true
                return
            }
            failWithRemoteDiagnosis(fallback: "Couldn’t start tmux on \(host.name).",
                                    hint: tmuxStartupHint)
            return
        }

        // Only resize the tmux client viewport when we created a new
        // standalone session, since shrinking a shared session would also
        // shrink the desktop's view.
        if resizeToScreen {
            // Prefer what the surface MEASURED over what we estimated before it
            // existed. By the time tmux has greeted, the container has usually
            // laid out at least once, and its number accounts for things the
            // estimate cannot see (the iPad sidebar, the quick-keys band).
            //
            // Getting this wrong is not self-correcting, which is why it is
            // worth the two fallbacks: the container pushes a client size only
            // when its own geometry CHANGES, so a session whose layout is
            // already settled when this fires keeps whatever this wrote, for
            // the life of the session.
            let size = lastTmuxClientSize ?? lastReportedSize ?? idealTerminalSize()
            dlog("Setting tmux client size to \(size.cols)x\(size.rows) (measured=\(lastTmuxClientSize != nil || lastReportedSize != nil))")
            tmuxService.sendFireAndForget(.refreshClient(width: size.cols, height: size.rows))
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
        // A subscription belongs to the control client, so every attach —
        // first connect and each reattach — is a new client that has none.
        subscribeToWorkingDirectories()
        startStatePolling()
        // Warm the session list so Move-to-Session menus (which resolve
        // synchronously from this cache) have targets on their FIRST open —
        // attaching straight to a remembered session (reconnects, and any
        // launch that already knows the name) skips the picker that would
        // otherwise have filled it.
        Task { await refreshTmuxSessions() }
    }

}
