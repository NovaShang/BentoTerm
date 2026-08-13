import Foundation
import BentoTmuxKit
import BentoFoundationKit

extension TerminalViewModel {

    // MARK: - "This canvas isn't mine"

    /// How long ONE answer has to hold before it reaches the UI.
    ///
    /// This is the whole anti-flap mechanism, and it has to be symmetric:
    /// appearing and disappearing both wait. A resize, a rotation, a font
    /// change and a reattach all move the two grids independently for a moment
    /// — the window follows the client a round trip later — so every one of
    /// them mismatches transiently, and a banner that believed the first sample
    /// would blink through normal use. Anything that changes either grid
    /// restarts the clock (see `noteSizingInputsChanged`), so the banner only
    /// ever states a conclusion the session has already stood still on.
    static let sizeMismatchSettle: Duration = .seconds(2)

    /// The grid the session is actually rendered at: the bounding box of the
    /// current window's panes, which is the tmux WINDOW's size.
    ///
    /// Read from the panes rather than asked of tmux (`#{window_width}`)
    /// because it must be free to sample: pane geometry already arrives on
    /// every `%layout-change`, and a poll would add a command round trip per
    /// tick to answer a question that is usually "nothing changed". A pane's
    /// `x + width` reaches the window edge — tmux's divider column sits between
    /// panes, never past the last one.
    var renderedSessionGrid: (cols: Int, rows: Int)? {
        let panes = paneViewModels.map(\.pane)
        guard !panes.isEmpty,
              let cols = panes.map({ $0.x + $0.width }).max(),
              let rows = panes.map({ $0.y + $0.height }).max(),
              cols > 0, rows > 0 else { return nil }
        return (cols, rows)
    }

    /// The banner's answer for RIGHT NOW, before the settle delay. Cheap enough
    /// to call on every layout change and every poll tick.
    func computeSessionSizeMismatch() -> SessionSizeMismatch? {
        // Only a live tmux session can have a foreign canvas. During a
        // reconnect the two grids are meaningless (the panes are the ones we
        // had before the drop, the client size is not declared yet), and in the
        // background there is nobody to tell.
        guard usingTmux, isTmuxReady, phase == .tmuxReady,
              !isReconnecting, !isInBackground else { return nil }
        // We hold the size ourselves: a difference here is our own resize still
        // in flight, and there is nothing to take over.
        guard !sizingOwnerIsMe else { return nil }
        guard let mine = lastTmuxClientSize, mine.cols > 0, mine.rows > 0,
              let session = renderedSessionGrid,
              session.cols != mine.cols || session.rows != mine.rows else { return nil }
        return SessionSizeMismatch(
            mode: sizingMode,
            // Only `manual` records an owner; under the client-derived policies
            // the size comes from the set of attached clients, so naming one
            // would be a guess.
            owner: sizingMode == .thisDevice ? sizingOwner?.displayName : nil,
            sessionCols: session.cols, sessionRows: session.rows,
            deviceCols: mine.cols, deviceRows: mine.rows)
    }

    /// Something that feeds the comparison moved (either grid, the policy, or
    /// the owner). Re-arm the settle timer, but only when the ANSWER changed —
    /// a repeated identical answer must let the clock keep running, or a poll
    /// tick every 2s would postpone the banner forever.
    func noteSizingInputsChanged() {
        let candidate = computeSessionSizeMismatch()
        guard candidate != pendingSizeMismatch else { return }
        pendingSizeMismatch = candidate
        sizeMismatchSettleTask?.cancel()
        // Nothing pending and nothing showing: no timer to run.
        guard candidate != nil || sessionSizeMismatch != nil else { return }
        sizeMismatchSettleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.sizeMismatchSettle)
            guard !Task.isCancelled, let self else { return }
            // Recompute instead of publishing what was captured: a teardown
            // (disconnect, background) changes the answer without anything
            // calling back in here, and a banner about a session that is gone
            // is worse than a late one.
            let settled = self.computeSessionSizeMismatch()
            self.pendingSizeMismatch = settled
            if self.sessionSizeMismatch != settled { self.sessionSizeMismatch = settled }
        }
    }

    /// The banner's tap: make THIS device the one that sets the size.
    ///
    /// One call for all three policies. Under `manual` it re-claims ownership
    /// from the other device; under `latest`/`smallest` it switches the session
    /// to `manual` and claims it, which is the only way to stop a canvas that
    /// is derived from someone else's screen (a `refresh-client` re-announcement
    /// would leave the same policy in place and be recomputed away again).
    public func claimSessionSize() {
        setSizingMode(.thisDevice)
        // The banner is stale the moment the claim is issued; leaving it up for
        // the settle delay would read as "the tap did nothing".
        sizeMismatchSettleTask?.cancel()
        pendingSizeMismatch = nil
        sessionSizeMismatch = nil
    }
}
