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

        case .exit:
            usingTmux = false
            isTmuxReady = false
            phase = .ended
        }
    }

}
