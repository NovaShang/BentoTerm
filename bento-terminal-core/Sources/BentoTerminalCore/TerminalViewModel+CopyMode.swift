import Foundation
import SwiftUI
import os
import BentoTmuxKit
import BentoFoundationKit

extension TerminalViewModel {
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

    /// The plain split — ⌘D and the toolbar's Split Right / Split Down.
    ///
    /// Note it does NOT go through `resolveSeed`: tmux's own `split-window`
    /// default (`-c '#{pane_current_path}'`, no command) is already what this
    /// wants, so there is nothing to resolve before sending it. That is also
    /// why recents stayed empty on the split path even though `resolveSeed`
    /// records — `.duplicateCurrent` is only reached from the *Duplicate*
    /// menu item, not from the split every user actually presses. So ask for
    /// the pair here, purely to remember it.
    public func splitPane(horizontal: Bool) {
        if let activePaneID {
            tmuxService.sendFireAndForget(.selectPane(id: activePaneID))
        }
        tmuxService.sendFireAndForget(.splitWindow(target: activePaneID, horizontal: horizontal))
        Task {
            // Before the sleep: the source pane's directory is what we mean,
            // and after a split the active pane is the NEW one.
            await recordActivePaneLaunch()
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

}
