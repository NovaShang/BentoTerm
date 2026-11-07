import Foundation
import SwiftUI
import os
import BentoTmuxKit
import BentoFoundationKit

extension TerminalViewModel {
    // MARK: - Pane Status

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
        var statusWorking = 0
        var statusAwaiting = 0
        var statusDoneUnseen = 0

        var newStates: [TmuxPaneID: PaneState] = [:]
        var newDone: [TmuxPaneID: Bool] = [:]

        for paneVM in paneViewModels {
            let current = paneVM.paneState
            let (newState, hasStatus) = Self.classifyPane(paneVM.pane)
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

            if updateSeen(paneVM, from: current, to: newState, hasStatus: hasStatus) {
                changed = true
            }
            newDone[paneVM.paneID] = paneVM.doneUnseen

            if case .awaitingInput = paneVM.paneState {
                awaitingCount += 1
            }

            // Tally panes that report a status, for the session tab's dot.
            if hasStatus {
                if paneVM.doneUnseen { statusDoneUnseen += 1 }
                switch paneVM.paneState {
                case .working:       statusWorking += 1
                case .awaitingInput: statusAwaiting += 1
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
            let (state, hasStatus) = Self.classifyPane(pane)
            newStates[pane.id] = state
            if paneStates[pane.id] != state { changed = true }

            let done = Self.doneUnseen(hasStatus: hasStatus, isFocused: false,
                                       current: current, newState: state,
                                       prev: paneDoneUnseen[pane.id] ?? false)
            newDone[pane.id] = done
            if (paneDoneUnseen[pane.id] ?? false) != done { changed = true }
        }
        paneStates = newStates
        paneDoneUnseen = newDone

        if changed {
            stateVersion += 1
        }
        if panesWorking != statusWorking { panesWorking = statusWorking }
        if panesAwaiting != statusAwaiting { panesAwaiting = statusAwaiting }
        if panesDoneUnseen != statusDoneUnseen { panesDoneUnseen = statusDoneUnseen }
        if sawNewAwaiting {
            environment.onAwaitingTriggered()
        }
        // Fan into SessionManager so the aggregate Live Activity recomputes
        // across all live sessions.
        environment.onSessionUpdate(host.id, activeTmuxSessionName ?? "", awaitingCount, latestPrompt)
    }

    /// THE per-pane state judgment — the single pipeline behind both the Tiled
    /// pane chrome and the List window dots. It is only what the program in
    /// the pane wrote into its `@bento_state` option, which rides along on the
    /// list-panes poll; a pane without it gets no dot.
    static func classifyPane(_ pane: Pane) -> (state: PaneState, hasStatus: Bool) {
        PaneStatusOption.classify(value: pane.statusOption,
                                  command: pane.currentCommand)
    }

    /// Maintain the "done, unseen" flag. A pane with a status that transitions into
    /// .idle while unfocused becomes done(unseen); focusing it or leaving idle
    /// clears it. Returns true if the flag changed (so the UI repaints).
    @discardableResult
    func updateSeen(_ paneVM: PaneViewModel, from current: PaneState,
                            to newState: PaneState, hasStatus: Bool) -> Bool {
        let want = Self.doneUnseen(hasStatus: hasStatus, isFocused: paneVM.isActive,
                                   current: current, newState: newState,
                                   prev: paneVM.doneUnseen)
        guard paneVM.doneUnseen != want else { return false }
        paneVM.doneUnseen = want
        return true
    }

    /// Pure "done, unseen" transition, shared by live and background panes: a
    /// pane with a status that goes idle while UNFOCUSED becomes done; staying idle
    /// keeps the memory; focusing it or leaving idle clears it.
    static func doneUnseen(hasStatus: Bool, isFocused: Bool, current: PaneState,
                           newState: PaneState, prev: Bool) -> Bool {
        guard hasStatus, isIdle(newState), !isFocused else { return false }
        return isIdle(current) ? prev : true
    }

    static func isIdle(_ s: PaneState) -> Bool {
        if case .idle = s { return true }
        return false
    }
}

