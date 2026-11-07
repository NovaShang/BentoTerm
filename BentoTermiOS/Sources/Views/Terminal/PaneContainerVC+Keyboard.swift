import SwiftUI
import BentoTmuxKit
import Combine
import BentoVoiceKit
import BentoSessionKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

// MARK: - Keyboard & compose occlusion

extension PaneContainerVC {
    func setupKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification, object: nil)
        // Third-party IMEs resize AFTER showing (candidate strips appear and
        // collapse while typing) and report it only through willChangeFrame.
        // Without this the avoidance pans from a stale height: the compose bar
        // covered the cursor while candidates were up, and left a dead gap
        // above itself once they collapsed. Same handler — an off-screen end
        // frame computes to inset 0, so hide also passes through safely.
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillShow(_ note: Notification) {
        guard let frameValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        let inView = view.convert(frameValue, from: nil)
        keyboardInsetBottom = max(0, view.bounds.maxY - inView.minY)
        dlog("[keyboard] show inset=\(keyboardInsetBottom)")
        updateFloatingToolbarVisibility()
        animateForKeyboard(note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        dlog("[keyboard] hide")
        keyboardInsetBottom = 0
        updateFloatingToolbarVisibility()
        animateForKeyboard(note)
    }

    private func animateForKeyboard(_ note: Notification) {
        let info = note.userInfo
        let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 0
        let opts = UIView.AnimationOptions(rawValue: curveRaw << 16)
        // Keyboard changes the VIEWPORT only — it never changes the page (tmux
        // size) or the tmux client size (both come from the keyboard-independent
        // page rect, so the keyboard never resizes tmux). We respond by panning
        // the content up so the active pane's input stays above the keyboard,
        // re-clamping the offset, and repositioning the floating toolbar. On
        // hide, keyboardOverlap is 0 so the re-clamp pulls the page back.
        UIView.animate(withDuration: duration, delay: 0, options: opts) {
            self.revealActivePaneAboveKeyboard()
            self.applyContentFrame()
            self.view.layoutIfNeeded()
        }
    }

    /// Pan the content up just enough to lift the active pane's INSERTION POINT
    /// (the real terminal cursor) above the bottom occlusion (keyboard, plus the
    /// compose bar while composing). The cursor isn't always at the pane bottom
    /// — TUIs (vim, forms, less) put it anywhere — so anchoring on the pane
    /// bottom hid the caret. Falls back to the pane bottom when the cursor rect
    /// isn't readable. No-op when nothing is hidden.
    private func revealActivePaneAboveKeyboard() {
        guard bottomOcclusion > 0, let vc = focusedOrActiveVC else { return }
        let keyboardTopInView = view.bounds.height - bottomOcclusion
        let anchorBottomInView: CGFloat
        if let caret = vc.cursorRect(in: view) {
            anchorBottomInView = caret.maxY + Self.cursorKeyboardMargin
        } else {
            anchorBottomInView = contentView.frame.minY + vc.view.frame.maxY
        }
        let overflow = anchorBottomInView - keyboardTopInView
        guard overflow > 0 else { return }
        contentOffset.y -= overflow
    }

    /// Track the compose bar's visibility + measured height so the content can
    /// pan clear of it (same animated path as the keyboard).
    func observeComposeBar() {
        composeBarSubs.removeAll()
        guard let controller = voiceController else { return }
        controller.$showPreview
            .combineLatest(controller.$composeBarHeight)
            .map { shown, height in shown ? height : 0 }
            .removeDuplicates()
            .sink { [weak self] reserve in self?.composeReserveChanged(reserve) }
            .store(in: &composeBarSubs)
    }

    private func composeReserveChanged(_ reserve: CGFloat) {
        guard composeReserve != reserve else { return }
        composeReserve = reserve
        guard isViewLoaded else { return }
        updateFloatingToolbarVisibility()
        UIView.animate(withDuration: 0.25) {
            self.revealActivePaneAboveKeyboard()
            self.applyContentFrame()
            self.view.layoutIfNeeded()
        }
    }
}
