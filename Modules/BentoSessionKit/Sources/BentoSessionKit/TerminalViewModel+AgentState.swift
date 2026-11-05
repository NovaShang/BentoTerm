import Foundation
import SwiftUI
import os
import BentoTmuxKit
import BentoAgentKit
import BentoFoundationKit

extension TerminalViewModel {
    // MARK: - Agent State

    func startStatePolling() {
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
                // Cheap re-derive of the take-over banner. The event hooks
                // (resize, layout change, policy change) cover every way the
                // answer normally moves; this tick is the backstop for the ones
                // that arrive as a same-shaped pane list — a `resize-window`
                // from another client changes nothing but the numbers.
                self.noteSizingInputsChanged()
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

    func updatePaneStates() async {
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
            let (newState, isAgent) = Self.classifyPane(paneVM.pane)
            newStates[paneVM.paneID] = newState

            if paneVM.paneState != newState {
                // Transition INTO awaiting/blocked — fire haptic + snippet.
                if case .awaitingInput = newState {
                    sawNewAwaiting = true
                    let snippet = recentOutput.recentText(for: paneVM.paneID, lines: 3)
                    if !snippet.isEmpty { latestPrompt = snippet }
                }
                paneVM.paneState = newState
                changed = true
            }

            if updateSeen(paneVM, from: current, to: newState, isAgent: isAgent) {
                changed = true
            }
            await rememberAgentLaunch(pane: paneVM.paneID, agent: isAgent ? paneVM.pane.agent : nil)
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
            let (state, isAgent) = Self.classifyPane(pane)
            newStates[pane.id] = state
            if paneStates[pane.id] != state { changed = true }

            let done = Self.doneUnseen(isAgent: isAgent, isFocused: false,
                                       current: current, newState: state,
                                       prev: paneDoneUnseen[pane.id] ?? false)
            newDone[pane.id] = done
            if (paneDoneUnseen[pane.id] ?? false) != done { changed = true }
            // Background windows count too: an agent you left running in
            // another tmux window is exactly the one you want to start again.
            await rememberAgentLaunch(pane: pane.id, agent: isAgent ? pane.agent : nil)
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
    /// pane chrome and the List window dots. It is only what the agent's hooks
    /// wrote into the pane's `@bento_agent` / `@bento_state` options, which
    /// ride along on the list-panes poll; a pane without them gets no dot.
    static func classifyPane(_ pane: Pane) -> (state: PaneState, isAgent: Bool) {
        AgentHookState.classify(agent: pane.agent, state: pane.agentState,
                                command: pane.currentCommand)
    }

    /// Remember "an agent ran here" so it can be started again later — the
    /// list behind the Recent Agents rows in the split menu and ⌘P.
    ///
    /// The command comes from the agent id the hook wrote, never from tmux's
    /// `pane_current_command`. That value is the executed file's name, which on
    /// a versioned install is a number — `2.1.246` names no program, and rows
    /// like that are exactly what poisoned this store in builds through 0.3.1
    /// (see `RecentLaunchPolicy.isReplayableCommand`).
    ///
    /// Once per pane per agent: the directory costs a tmux round trip, and the
    /// poll would otherwise pay it every two seconds for every agent on screen.
    func rememberAgentLaunch(pane: TmuxPaneID, agent agentID: String?) async {
        // Filed under `launchHost`: the row is replayed by splitting on the
        // machine the path lives on, and only offered there.
        guard usingTmux, let agentID,
              let command = AgentPreset.forAgentID(agentID)?.launchCommand
        else { return }
        let key = "\(pane)|\(agentID)"
        guard !rememberedAgentLaunches.contains(key) else { return }
        rememberedAgentLaunches.insert(key)
        guard let dir = await displayValue("#{pane_current_path}", pane: pane) else {
            // Nothing to name the row after — let a later poll try again.
            rememberedAgentLaunches.remove(key)
            return
        }
        PaletteRecents.shared.recordLaunchIfUseful(dir: dir, command: command, host: launchHost)
    }

    /// Maintain the "done, unseen" flag. An agent pane that transitions into
    /// .idle while unfocused becomes done(unseen); focusing it or leaving idle
    /// clears it. Returns true if the flag changed (so the UI repaints).
    @discardableResult
    func updateSeen(_ paneVM: PaneViewModel, from current: PaneState,
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

    static func isIdle(_ s: PaneState) -> Bool {
        if case .idle = s { return true }
        return false
    }
}

