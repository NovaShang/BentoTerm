import Foundation
import BentoTmuxKit
import BentoFoundationKit

extension TerminalViewModel {
    /// Subscription name for the per-pane working directory push.
    static let cwdSubscriptionName = "bento_cwd"

    /// Ask tmux to push every pane's working directory when it changes.
    ///
    /// Why a subscription: a process changing directory (`cd`) raises no event
    /// anywhere a client could observe — not over SSH, and not locally either
    /// (macOS has no notification for another process's cwd). tmux can see it
    /// (`#{pane_current_path}` reads the foreground process's cwd) and, since
    /// 3.2, will re-check a subscribed format about once a second and send
    /// `%subscription-changed` only when the value moves. That gives the Files
    /// tree "follows `cd`" with no timer of our own: a client-side "ask every
    /// 2 s" was tried and rejected.
    ///
    /// `%*` means every pane of the ATTACHED session, evaluated at check time,
    /// so it keeps working across switch-client (see `.sessionChanged`).
    ///
    /// tmux older than 3.2 answers `%error` (no `-B`). `send` consumes that
    /// response in its own FIFO slot, so nothing shifts; we just never get
    /// pushes and the map stays empty — the UI then behaves as before
    /// (re-rooting only when the focused pane changes).
    func subscribeToWorkingDirectories() {
        guard usingTmux else { return }
        Task { [weak self] in
            guard let self else { return }
            let resp = await self.tmuxService.send(
                .subscribe(name: Self.cwdSubscriptionName, target: "%*", format: "#{pane_current_path}"),
                timeout: .seconds(5))
            if resp.isError {
                dlog("[cwd] subscription unavailable (tmux < 3.2?): \(resp.output.prefix(80))")
            }
        }
    }

    /// Fold one `%subscription-changed` into the published map. Called on the
    /// main actor from the notification drain — never from the output path
    /// (tmux sends these at most once a second per pane, only on change).
    func adoptSubscriptionValue(name: String, pane: TmuxPaneID?, value: String) {
        guard name == Self.cwdSubscriptionName, let pane, !value.isEmpty,
              paneWorkingDirectories[pane] != value else { return }
        paneWorkingDirectories[pane] = value
    }
}
