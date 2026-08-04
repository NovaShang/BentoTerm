import Foundation
import SwiftUI
import os
import BentoTmuxKit
import BentoFoundationKit

extension TerminalViewModel {
    // MARK: - tmux Notifications

    func handleTmuxNotification(_ notification: TmuxNotification) {
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
            layoutChangeDebounce = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                await self.refreshPanes()
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
            // Sizing is a per-session policy on the server — re-adopt it, or
            // sizingMode/owner still describe the previous session.
            restoreSizingMode(for: name)
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

        case .pasteBufferChanged(let name):
            adoptPasteBuffer(named: name)

        case .exit:
            usingTmux = false
            isTmuxReady = false
            phase = .ended
        }
    }

    /// Mirror a tmux paste buffer onto this device's system pasteboard.
    ///
    /// A program that copies while running under tmux writes the text into a
    /// paste buffer (`tmux load-buffer -w -`, which is what Claude Code does the
    /// moment it detects tmux). For a normal terminal tmux would then also emit
    /// the OSC 52 that puts it on the real clipboard — but a control-mode client
    /// has no tty to receive that, so the copy used to land in a buffer nobody
    /// ever read. `%paste-buffer-changed` is the only signal we get, and
    /// `show-buffer` is the only way to collect the text.
    ///
    /// This is also what makes copy work ACROSS the link: the buffer lives on
    /// the remote host, the pasteboard is local, and this is the hop between.
    func adoptPasteBuffer(named name: String) {
        // Only while tmux is actually driving — a buffer notification arriving
        // during teardown has no owner worth serving.
        guard usingTmux else { return }
        Task { [weak self] in
            guard let self else { return }
            let resp = await self.tmuxService.send(.showBuffer(name: name), timeout: .seconds(5))
            guard !resp.isError else {
                dlog("[clipboard] show-buffer \(name) failed")
                return
            }
            // A buffer can hold a whole file. Refuse the absurd rather than
            // hand the pasteboard something that came from a runaway `cat`.
            guard !resp.output.isEmpty, resp.output.utf8.count <= Self.maxAdoptedBufferBytes else {
                dlog("[clipboard] buffer \(name) skipped (\(resp.output.utf8.count)B)")
                return
            }
            TerminalClipboard.write(resp.output)
            dlog("[clipboard] adopted tmux buffer \(name) (\(resp.output.utf8.count)B)")
        }
    }

    /// 4 MB — far above any real copy, far below "the agent dumped a log".
    static let maxAdoptedBufferBytes = 4 * 1024 * 1024
}
