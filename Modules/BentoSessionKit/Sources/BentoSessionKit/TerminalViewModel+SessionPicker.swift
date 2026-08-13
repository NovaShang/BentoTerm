import Foundation
import SwiftUI
import os
import BentoTmuxKit
import BentoAgentKit
import BentoFoundationKit

extension TerminalViewModel {
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
            sessionListIsTrustworthy = true
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
        guard let output = await captureShellOutput(cmd: cmd, marker: endMarker, timeoutMs: 5000) else {
            // Leave `availableTmuxSessions` alone. An empty list here does not
            // mean "this host has no sessions" — and `applyTmuxChoice` reads it
            // to decide whether it is creating a session or joining one, so a
            // wrong empty answer makes it resize an EXISTING session to this
            // device, shrinking the viewport for every other client attached to
            // it. Staleness is strictly safer than a fabricated empty.
            dlog("tmux ls timed out — keeping the previous session list")
            return
        }
        availableTmuxSessions = TmuxParsers.parseTmuxLs(output, startMarker: startMarker, endMarker: endMarker)
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
        kind = (choice == .noTmux) ? .plain : .tmux
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
                transport.startsInTmuxControlMode
                || !sessionListIsTrustworthy
                || availableTmuxSessions.contains(name)
            await launchTmux(
                sessionName: name,
                groupWith: nil,
                resizeToScreen: !isAttachToExisting
            )
            // Attaching IS a launch, and it's the most common one there is —
            // far more common than any of the three "new …" verbs the launcher
            // offers. Recorded here rather than where the user clicked, because
            // at click time there is nothing to ask: the directory and the
            // program belong to the session, and only the established control
            // -mode connection can name them. `launchTmux` has by now seen the
            // greeting and refreshed panes, so the active pane is real.
            //
            // A brand-new empty session comes through here too, which is
            // correct and costs nothing: `new-session -A -s <name>` carries no
            // `-c`, so it lands in `$HOME` with a bare shell, and the noise
            // rule drops exactly that.
            await recordActivePaneLaunch()
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
    func applyAgentLayout(_ spec: AgentSpec) async {
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

    func launchTmux(
        sessionName: String,
        groupWith: String?,
        resizeToScreen: Bool,
        path: String? = nil,
        command: String? = nil,
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
        startStatePolling()
        // Warm the session list so Move-to-Session menus (which resolve
        // synchronously from this cache) have targets on their FIRST open —
        // attaching straight to a remembered session (reconnects, and any
        // launch that already knows the name) skips the picker that would
        // otherwise have filled it.
        Task { await refreshTmuxSessions() }
    }

}
