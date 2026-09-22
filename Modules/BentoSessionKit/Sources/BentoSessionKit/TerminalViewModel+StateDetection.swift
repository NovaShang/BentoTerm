import Foundation
import SwiftUI
import os
import BentoTmuxKit
import BentoAgentKit
import BentoFoundationKit

extension TerminalViewModel {
    // MARK: - State Detection

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
            let (newState, isAgent) = await classifyPane(
                id: paneVM.paneID, command: paneVM.pane.currentCommand,
                title: paneVM.pane.title ?? "", current: current)
            newStates[paneVM.paneID] = newState

            if paneVM.paneState != newState {
                // Transition INTO awaiting/blocked — fire haptic + snippet.
                if case .awaitingInput = newState {
                    sawNewAwaiting = true
                    let snippet = stateDetection.recentText(for: paneVM.paneID, lines: 3)
                    if !snippet.isEmpty { latestPrompt = snippet }
                }
                paneVM.paneState = newState
                changed = true
            }

            if updateSeen(paneVM, from: current, to: newState, isAgent: isAgent) {
                changed = true
            }
            await rememberAgentLaunch(pane: paneVM.paneID, isAgent: isAgent)
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
            let (state, isAgent) = await classifyPane(
                id: pane.id, command: pane.currentCommand,
                title: pane.title ?? "", current: current)
            newStates[pane.id] = state
            if paneStates[pane.id] != state { changed = true }

            let done = Self.doneUnseen(isAgent: isAgent, isFocused: false,
                                       current: current, newState: state,
                                       prev: paneDoneUnseen[pane.id] ?? false)
            newDone[pane.id] = done
            if (paneDoneUnseen[pane.id] ?? false) != done { changed = true }
            // Background windows count too: an agent you left running in
            // another tmux window is exactly the one you want to start again.
            await rememberAgentLaunch(pane: pane.id, isAgent: isAgent)
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
    /// pane chrome and the List window dots. Recognized coding agents go through
    /// the region/priority rule engine (title is the cheap pass; a spinner
    /// resolves to .working with no tmux round-trip — otherwise capture the live
    /// screen and re-classify). Everything else stays on the legacy
    /// activity/profile path.
    func classifyPane(id: TmuxPaneID, command: String?, title: String,
                              current: PaneState) async -> (state: PaneState, isAgent: Bool) {
        switch stateDetection.classifyAgent(command: command, title: title, snapshot: nil,
                                            pane: id, current: current) {
        case .notAgent:
            return (stateDetection.detectState(pane: id, currentCommand: command, title: title), false)
        case .state(let s):
            return (s, true)
        case .needsSnapshot:
            guard let snap = await captureSnapshot(id) else {
                // The capture failed. If the pane has never been identified,
                // the snapshot was only an identity probe — it is not an agent
                // pane, and must not be counted as one.
                guard stateDetection.identifiedAgent(for: id) != nil else {
                    return (stateDetection.detectState(pane: id, currentCommand: command, title: title), false)
                }
                return (current, true)
            }
            switch stateDetection.classifyAgent(
                command: command, title: title, snapshot: snap, pane: id, current: current) {
            case .state(let s):
                return (s, true)
            case .notAgent:
                // The snapshot was the identity probe (a `node` pane that could
                // have been an agent), and the screen says it isn't one.
                return (stateDetection.detectState(pane: id, currentCommand: command, title: title), false)
            case .needsSnapshot:
                return (current, true)
            }
        }
    }

    /// Remember "an agent ran here" so it can be started again later — the
    /// list behind the Recent Agents rows in the split menu and ⌘P.
    ///
    /// The command comes from the DETECTED agent, never from tmux's
    /// `pane_current_command`. That value is the executed file's name, which on
    /// a versioned install is a number — `2.1.246` names no program, and rows
    /// like that are exactly what poisoned this store in builds through 0.3.1
    /// (see `RecentLaunchPolicy.isReplayableCommand`). Detection already knows
    /// who it is regardless of how the binary was installed, so this asks it.
    ///
    /// Once per pane per agent: the directory costs a tmux round trip, and the
    /// poll would otherwise pay it every two seconds for every agent on screen.
    func rememberAgentLaunch(pane: TmuxPaneID, isAgent: Bool) async {
        // Filed under `launchHost`: the row is replayed by splitting on the
        // machine the path lives on, and only offered there.
        guard isAgent, usingTmux else { return }
        guard let agentID = stateDetection.identifiedAgent(for: pane),
              let command = AgentPreset.forDetectionID(agentID)?.launchCommand
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

    /// Fetch a pane's live visible screen (no scrollback, plain text) for the
    /// agent rule engine. nil on error.
    func captureSnapshot(_ id: TmuxPaneID) async -> String? {
        let resp = await tmuxService.send(.capturePane(id: id, lines: nil))
        return resp.isError ? nil : resp.output
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

