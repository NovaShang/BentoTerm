import SwiftUI
import BentoTmuxKit
import Combine
import BentoVoiceKit
import BentoAgentKit
import BentoSessionKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

// MARK: - Find in pane

extension PaneContainerVC {
    /// Hardware-keyboard shortcuts (iPad with a keyboard, or a Mac trackpad
    /// case). Deliberately NO Escape here: Esc belongs to the terminal, and a
    /// container-level key command would swallow it for every pane. The find
    /// bar takes Esc only while its own field holds the keyboard — see
    /// `PaneFindBar.keyCommands`.
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Find…", action: #selector(handleFindCommand),
                         input: "f", modifierFlags: .command),
            UIKeyCommand(title: "Find Next", action: #selector(handleFindNextCommand),
                         input: "g", modifierFlags: .command),
            UIKeyCommand(title: "Find Previous", action: #selector(handleFindPreviousCommand),
                         input: "g", modifierFlags: [.command, .shift]),
        ]
    }

    @objc private func handleFindCommand() {
        if findBar.isHidden { showFindBar() } else { findBar.focusField() }
    }

    @objc private func handleFindNextCommand() {
        guard !findBar.isHidden else { return }
        findTargetVC?.surface.navigateSearch(forward: true)
    }

    @objc private func handleFindPreviousCommand() {
        guard !findBar.isHidden else { return }
        findTargetVC?.surface.navigateSearch(forward: false)
    }

    func setupFindBar() {
        findBar.isHidden = true
        // On `view`, not `contentView`: the bar is chrome anchored to the
        // keyboard, so it must not pan with the tmux page.
        view.addSubview(findBar)

        findBar.model.onQueryChanged = { [weak self] needle in
            self?.findTargetVC?.surface.runSearch(needle)
        }
        findBar.model.onNext = { [weak self] in
            self?.findTargetVC?.surface.navigateSearch(forward: true)
        }
        findBar.model.onPrevious = { [weak self] in
            self?.findTargetVC?.surface.navigateSearch(forward: false)
        }
        findBar.model.onClose = { [weak self] in self?.hideFindBar() }
    }

    /// Open the find bar on the pane the user is working in. A single-line
    /// selection prefills it, matching ⌘F-with-a-selection on the Mac.
    func showFindBar(prefill: String? = nil) {
        guard let vc = focusedOrActiveVC else { return }
        findTargetVC = vc

        // The engine reports counts per surface; route this one's to the bar.
        vc.surface.onSearchCounts = { [weak self] total, selected in
            self?.findBar.model.setCounts(total: total, selected: selected)
        }
        vc.surface.onSearchEnded = { [weak self] in self?.hideFindBar() }

        findBar.isHidden = false
        bridge?.findBarActive = true
        findReserve = PaneFindBar.barHeight + PaneFindBar.edgeGap
        updateFloatingToolbarVisibility()

        if let seed = prefill ?? vc.surface.selectionAsNeedle(), !seed.isEmpty {
            findBar.query = seed
            findBar.model.setQuery(seed)   // counts for a seed that never went through typing
            vc.surface.runSearch(seed)
        }
        positionFindBar()
        // Taking first responder here is what raises the keyboard, which is what
        // makes the bar's docked position matter — so position first.
        findBar.focusField()
        view.setNeedsLayout()
    }

    func hideFindBar() {
        guard !findBar.isHidden else { return }
        findBar.model.cancelPendingQuery()
        findBar.dismissKeyboard()
        findBar.isHidden = true
        bridge?.findBarActive = false
        findBar.query = ""
        findBar.model.setCounts(total: nil, selected: nil)
        findReserve = 0
        // Drop the search AND the per-surface reporting hooks, so a pane the bar
        // is no longer pointed at can't drive it.
        if let vc = findTargetVC {
            vc.surface.endSearch()
            vc.surface.onSearchCounts = nil
            vc.surface.onSearchEnded = nil
        }
        findTargetVC = nil
        updateFloatingToolbarVisibility()
        view.setNeedsLayout()
    }

    /// Dock the bar in the strip above the keyboard; with the keyboard down it
    /// rests on the bottom safe inset. Full width less the edge gap — a needle
    /// deserves the room, and unlike the Mac there is no pane corner to tuck
    /// into on a phone.
    func positionFindBar() {
        guard !findBar.isHidden else { return }
        // The target pane went away (window switch, pane closed, mode flip). The
        // reference is weak, so this is where a bar left pointing at nothing gets
        // closed instead of sitting there swallowing keystrokes.
        guard findTargetVC != nil else { hideFindBar(); return }
        let gap = PaneFindBar.edgeGap
        let h = PaneFindBar.barHeight
        let bottomInset = max(keyboardInsetBottom, view.safeAreaInsets.bottom)
        findBar.frame = CGRect(x: gap,
                               y: view.bounds.height - bottomInset - h - gap,
                               width: max(0, view.bounds.width - gap * 2),
                               height: h)
    }
}
