import Foundation
import SwiftUI
import os
import BentoTmuxKit
import BentoFoundationKit

extension TerminalViewModel {
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
    func bringUpTransport() async -> (cols: Int, rows: Int)? {
        errorMessage = nil
        showError = false
        phase = .sshConnecting
        dlog("Connecting to \(self.host.hostname):\(self.host.port)")
        await transport.connect(host: host)

        guard case .connected = transport.state else {
            dlog("SSH connection failed: \(String(describing: self.transport.state))")
            // Surface the diagnosis here instead of waiting for the transport's
            // `onStateChanged` hop. That callback reaches the MainActor through
            // a `Task`, while callers of `connect()` read `errorMessage` the
            // moment it returns — so whichever got enqueued first decided
            // whether the user saw what actually went wrong or the caller's
            // generic "check the host and your SSH credentials". `state` is
            // written synchronously before the callback fires, so reading it
            // here is exact, and `handleUnexpectedFailure` is the same policy
            // the callback would have applied (it no-ops mid-reconnect and
            // while backgrounded, and only reports once).
            if case .failed(let msg) = transport.state {
                handleUnexpectedFailure(message: msg)
            }
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
    func idealTerminalSize() -> (cols: Int, rows: Int) {
        environment.idealTerminalSize()
    }

}
