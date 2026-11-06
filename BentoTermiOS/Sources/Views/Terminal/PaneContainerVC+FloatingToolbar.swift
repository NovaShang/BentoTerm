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

// MARK: - Floating toolbar

extension PaneContainerVC {
    func setupFloatingToolbar() {
        // Restore the per-device collapse choice BEFORE the first layout pass,
        // so the bar's first frame is already the circle or the full strip.
        quickKeysCollapsed = UserDefaults.standard.bool(forKey: Self.quickKeysCollapsedKey)
        floatingToolbar.isCollapsed = quickKeysCollapsed

        floatingToolbar.onKeyTap = { [weak self] key in
            self?.focusedOrActiveVC?.handleAccessoryKey(key)
        }
        floatingToolbar.onCollapseToggle = { [weak self] collapsed in
            guard let self else { return }
            self.quickKeysCollapsed = collapsed
            UserDefaults.standard.set(collapsed, forKey: Self.quickKeysCollapsedKey)
            // Only the bar's width changed — the band and grid are untouched,
            // so this is a re-position, not a layout pass.
            self.positionFloatingToolbar()
        }
        floatingToolbar.isHidden = true
        view.addSubview(floatingToolbar)
    }

    func updateFloatingToolbarVisibility() {
        // Hidden while the keyboard is up (the docked accessory row covers keys)
        // and while the compose bar or the find bar is up (they own the bottom
        // strip).
        floatingToolbar.isHidden = !hasVisiblePane || keyboardInsetBottom > 0
            || composeReserve > 0 || findReserve > 0
    }

    /// Position the floating toolbar just below the active pane. The pane frames
    /// live in the (possibly panned) content view, so offset into view
    /// coordinates.
    func positionFloatingToolbar() {
        guard !floatingToolbar.isHidden else { return }
        let activeVC = focusedOrActiveVC
        refreshFloatingToolbarActions(for: activeVC)
        let paneFrame = activeVC?.view.frame ?? .zero
        let origin = contentView.frame.origin
        let anchor = CGRect(x: paneFrame.minX + origin.x, y: paneFrame.minY + origin.y,
                            width: paneFrame.width, height: paneFrame.height)
        // Two homes, chosen by `quickKeysBandActive`:
        //   - Docked: the reserved band between the page bottom and the bottom
        //     safe inset — the bar sits in its own strip, never over the grid.
        //   - Floating: over the pane content (fullscreen, where no band is
        //     reserved), clamped just above the home-indicator strip. Hides
        //     while the keyboard is up, so no keyboard reserve is needed.
        let containerBounds: CGRect
        if quickKeysBandActive {
            containerBounds = CGRect(x: 0, y: pageRect.maxY,
                                     width: view.bounds.width,
                                     height: max(0, view.bounds.height - pageRect.maxY
                                                     - view.safeAreaInsets.bottom))
        } else {
            containerBounds = CGRect(x: 0, y: 0, width: view.bounds.width,
                                     height: max(0, view.bounds.height - view.safeAreaInsets.bottom))
        }
        floatingToolbar.updatePosition(paneFrame: anchor,
                                       containerBounds: containerBounds, animated: false)
    }

    /// Point the floating toolbar's menu at the active pane.
    ///
    /// Shown for a plain session too: the menu drops its tmux entries there and
    /// keeps Find / Paste, which are about the terminal and
    /// have nothing to do with tmux. Hiding the whole button (what this used to
    /// do for anything without a `paneVM`) took search and paste with it, and on
    /// a phone the bar is the only way to reach either.
    private func refreshFloatingToolbarActions(for activeVC: TerminalContainerVC?) {
        floatingToolbar.showsPaneActions = activeVC != nil
        guard let activeVC else { return }
        // The pane menu is cached on the VC (deferred elements re-resolve at
        // open time); only reassign when the active pane actually changed, so
        // per-layout-pass calls don't churn UIKit's menu plumbing.
        if floatingToolbar.menuButton.menu !== activeVC.paneMenu {
            floatingToolbar.menuButton.menu = activeVC.paneMenu
            // The menu's Zoom/Unzoom entry reads this live at open time
            // (deferred element), so wiring it once per pane change is enough.
            activeVC.isZoomed = { [weak self] in self?.viewModel?.zoomedPaneID != nil }
        }
    }
}
