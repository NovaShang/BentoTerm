import UIKit
import SwiftUI
import Combine
import BentoSessionKit
import BentoTmuxKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

// MARK: - Gestures

extension TerminalContainerVC {
    /// Inline gesture wiring. The libghostty surface has no built-in
    /// tap-to-keyboard or long-press selection, so unlike the SwiftTerm era we
    /// don't have to suppress any pre-existing recognizers — we just add ours.
    ///   - Voice press commits at 180ms (see VoicePressGesture).
    ///   - Single tap selects the pane.
    ///   - Double tap toggles the keyboard.
    func attachGestures() {
        let voicePress = VoicePressGesture(target: self, action: #selector(handleVoicePress(_:)))
        voicePress.delegate = self
        // Finger-down prewarm: overlap the mic engine's cold start with the
        // 180ms hold threshold, so voice capture is live the moment the
        // overlay appears (macOS has had this since bba1c59; iOS didn't —
        // that gap cost the first syllables of every recording).
        voicePress.onTouchDown = { [weak self] in
            guard let self else { return }
            // A landing finger catches an in-flight fling immediately — the
            // defining iOS-scroll behavior — before any recognizer arms.
            self.stopMomentum()
            guard !self.keyboardMode else { return }
            self.voiceController?.prewarm()
        }
        // Catch-touch rule (mirrors UIScrollView's dead touch during
        // deceleration): a press that lands while the scrollback is still
        // gliding only pins the content — it must not arm voice (keyboard
        // down) or drag-selection (keyboard up). Deliberately no velocity
        // floor: any live glide swallows the press, so the failure mode is
        // "press again", never "accidental recording". Lift + press to talk.
        voicePress.shouldArm = { [weak self] in
            guard let self, self.momentumLink != nil else { return true }
            dlog("fling: caught by press — voice/selection veto")
            return false
        }
        surface.addGestureRecognizer(voicePress)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.cancelsTouchesInView = false
        singleTap.delaysTouchesBegan = false
        singleTap.delaysTouchesEnded = false
        singleTap.delegate = self
        surface.addGestureRecognizer(singleTap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = self
        surface.addGestureRecognizer(doubleTap)

        // Two-finger tap keeps Bento's own tap (link, path preview) reachable in
        // a pane whose program has taken the single-finger one. `voicePress`
        // fails itself the moment a second finger lands, and the single-tap
        // recognizer requires exactly one touch, so neither competes for this.
        let localTap = UITapGestureRecognizer(target: self, action: #selector(handleLocalTap(_:)))
        localTap.numberOfTapsRequired = 1
        localTap.numberOfTouchesRequired = 2
        localTap.cancelsTouchesInView = false
        localTap.delegate = self
        surface.addGestureRecognizer(localTap)

        // Single-finger immediate drag → scrollback (PRD §3.1/§3.7). The voice
        // press fails on early movement (its 6pt slop), so a drag scrolls while
        // a still hold records — no extra coordination needed beyond ignoring
        // scroll while voice is actively recording.
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        scrollPan.minimumNumberOfTouches = 1
        scrollPan.maximumNumberOfTouches = 1
        scrollPan.delegate = self
        surface.addGestureRecognizer(scrollPan)
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        // A tap clears an active selection (like iOS) before anything else.
        if keyboardMode, surface.hasSelection {
            surface.clearSelection(at: gesture.location(in: surface))
            hideSelectionHandles()
            return
        }
        // Selecting the pane happens no matter who ends up with the tap: focus
        // is always Bento's, even when the tap itself belongs to a link or to
        // the program.
        onSelectPaneTapped?()
        routeTap(at: gesture.location(in: surface), mayForward: true)
    }

    /// Two-finger tap = Bento's own tap, no matter what: open a link, preview a
    /// file path, never forward. The touch stand-in for ⌘-click, and the way out
    /// when single-finger detection misses what the user meant.
    @objc private func handleLocalTap(_ gesture: UITapGestureRecognizer) {
        onSelectPaneTapped?()
        routeTap(at: gesture.location(in: surface), mayForward: false)
    }

    /// Decide who gets one tap, then act on it.
    ///
    /// Detection runs BEFORE forwarding. An alt-screen TUI (Claude Code's
    /// fullscreen mode, htop, less) turns mouse reporting on for the whole
    /// pane, so a tap handed to the program first can never reach a link or a
    /// path again for as long as that program is up — which is how tapping the
    /// agent's own output stopped working at all.
    ///
    /// What the tap is allowed to WAIT for is the other half of this: only the
    /// screen snapshot (cached ~0.4s) and the fast-path token test run before
    /// the program sees the click. A candidate that needs the stat oracle —
    /// a remote round-trip on a phone — is forwarded first and gets its chip
    /// late, so a TUI never pays filesystem latency for a press.
    private func routeTap(at p: CGPoint, mayForward: Bool) {
        let cols = paneVM?.pane.width
        let link = surface.linkTapHit(at: p, wrapCols: cols)
        let scan: SurfacePathHitEngine.TapScan =
            canPreviewPaths ? surface.pathTapHits(at: p, wrapCols: cols) : .empty
        switch TerminalTapRouter.route(linkURL: link,
                                       hasFastPathHit: scan.hits.first?.fastPath == true) {
        case .link(let url):
            // Load-bearing for onboarding: a remote agent's sign-in prints an
            // OAuth URL that must open on THIS device.
            showLinkChip(url, at: p)
        case .path:
            showFastPathChip(scan.hits[0], at: p)
        case .forward:
            let forwarded = mayForward && surface.forwardTap(at: p)
            if forwarded { noteTapForwarded() }
            // The program owns the mouse, so most taps here are presses on ITS
            // interface. Verifying every one of them would put a filesystem
            // round-trip — remote, over the session's own channel — behind each
            // button press, so only tokens that look like a file are worth it.
            // Two fingers still verifies whatever was tapped.
            let hits = forwarded ? scan.hits.filter(Self.looksLikeAFile) : scan.hits
            resolvePathChip(hits, rootHints: scan.rootHints, at: p)
        }
    }

    /// Cheap local pre-filter, not a decision: the stat oracle still referees.
    private static func looksLikeAFile(_ hit: SurfacePathHitEngine.TapHit) -> Bool {
        hit.path.contains("/") || hit.path.contains(".")
    }

    /// Say it once, the first time a tap goes to the program instead of the app.
    /// Nothing on screen shows that a program has taken the mouse, so the user
    /// otherwise just finds that some taps do nothing — and the two-finger tap
    /// that gets them back is undiscoverable.
    private func noteTapForwarded() {
        guard TipCenter.shared.consume(.mouseGrabbed) else { return }
        showToast("Tap sent to the app — two fingers if you meant to open a link or file")
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if keyboardMode {
            // Typing → double-tap selects the word (standard iOS behavior); it
            // no longer dismisses the keyboard (use the accessory ⌄ button).
            let p = gesture.location(in: surface)
            if surface.selectWord(at: p) {
                refreshSelectionHandles()
                presentEditMenu(at: p)
            }
        } else if Self.prefersRawKeyboard {
            // Last time the user chose raw — resume it.
            _ = surface.becomeFirstResponder()
        } else {
            // Default (and last-remembered): the managed compose box — the
            // zero-latency local buffer for writing a line/message. Raw keys are
            // one tap away inside the box ("直接输入").
            openManagedCompose()
        }
    }

    /// Double-tap entry into the app's one managed input surface (the same
    /// inline compose bar voice uses). Targets this pane, then opens it empty +
    /// focused for typing. Falls back to the raw keyboard if the voice
    /// controller isn't wired.
    func openManagedCompose() {
        guard let controller = voiceController else { _ = surface.becomeFirstResponder(); return }
        onSelectPaneTapped?()   // send to the pane the user double-tapped
        controller.readScreenText = { [weak self] in self?.surface?.readScrollback() }
        controller.onRequestRawKeyboard = { [weak self] in
            // "直接输入" — switching to raw makes raw the remembered mode.
            // Synchronous becomeFirstResponder: it must take over from the
            // compose TextField BEFORE the bar is dismissed, or the keyboard
            // collapses and re-shows through the switch.
            Self.prefersRawKeyboard = true
            _ = self?.surface.becomeFirstResponder()
        }
        controller.beginManualCompose()
    }

    @objc private func handleVoicePress(_ gesture: VoicePressGesture) {
        if gesture.state == .began {
            dlog("[voice] press began (keyboardMode=\(keyboardMode), controller=\(voiceController != nil))")
        }
        // Keyboard mode: long-press starts a drag text selection (not voice).
        if keyboardMode {
            let p = gesture.currentLocation()
            switch gesture.state {
            case .began:
                isSelecting = true
                hideSelectionHandles()
                surface.selectionBegin(at: p)
            case .changed:
                surface.selectionExtend(to: p)
            case .ended:
                isSelecting = false
                surface.selectionEnd()
                if surface.hasSelection {
                    refreshSelectionHandles()
                    presentEditMenu(at: p)
                }
            case .cancelled, .failed:
                isSelecting = false
                surface.selectionEnd()
            default:
                break
            }
            return
        }

        // Keyboard down: long-press = voice.
        guard let controller = voiceController, let view = gesture.view else { return }
        // Selecting on press makes voice transcripts land on the right pane
        // even if the user starts holding on a non-active pane.
        if gesture.state == .began {
            onSelectPaneTapped?()
            // Bind the Qwen context-biasing source to THIS pane's surface for the
            // recording that's about to start.
            controller.readScreenText = { [weak self] in self?.surface?.readScrollback() }
        }
        let local = gesture.currentLocation()
        // VoiceInputController positions its overlay in screen (window) coords,
        // so convert before forwarding.
        let screen = view.convert(local, to: nil)
        controller.handleLongPress(state: gesture.state, location: screen)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension TerminalContainerVC: @preconcurrency UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Our tap / voice-press recognizers are passive and should coexist with
        // any recognizers the surface may add (scroll, etc.).
        return true
    }
}
