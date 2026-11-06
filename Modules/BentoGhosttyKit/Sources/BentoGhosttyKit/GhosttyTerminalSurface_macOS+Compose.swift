#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFilePreviewKit
import BentoFoundationKit
import AppKit
import GhosttyKit

extension GhosttyTerminalSurface {

    // MARK: - Scroll-review-compose

    func setupCompose() {
        let bar = ComposeBarView(frame: .zero)
        bar.monoFont = composeFont()
        bar.isHidden = true
        addSubview(bar)
        composeBar = bar

        compose.onChange = { [weak self] in self?.updateComposeBar() }
        compose.onInject = { [weak self] text, execute in self?.injectComposed(text, execute: execute) }
        compose.onSnapToBottom = { [weak self] in self?.scrollComposeToBottom() }
    }

    private func composeFont() -> NSFont {
        let size = CGFloat(theme.fontSize > 0 ? theme.fontSize : 13)
        if let fam = theme.fontFamily, let f = NSFont(name: fam, size: size) { return f }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Called by GhosttyRuntime on every SCROLLBAR action (already on main).
    ///
    /// ghostty emits a transient not-at-bottom frame while it auto-scrolls to
    /// the new bottom on fresh output (the echo of your own typing, or a CJK
    /// preedit refresh): for one frame `offset+len < total` before the pin
    /// catches up. Forwarding that blip straight to the compose machine armed
    /// review mode (`isReviewing`), which routed the next IME commit into the
    /// draft bar instead of the engine — the text then only surfaced on the
    /// following at-bottom update, read as a ~1s "上屏" stutter on ~1/3 of
    /// commits. So debounce the live→review *entry*: only a scroll-up that
    /// persists past a short settle window is a real, user-initiated scroll.
    public func handleScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        lastScrollTop = Int(offset)
        let atBottom = offset + len >= total
        if atBottom {
            // Any real bottom cancels a pending entry and is reported at once.
            pendingReviewEntry?.cancel()
            pendingReviewEntry = nil
            compose.scrollChanged(atBottom: true)
            return
        }
        // Already reviewing: forward scroll updates immediately so draft/scroll
        // stay responsive. Only the initial entry from `.live` is debounced.
        if compose.isReviewing {
            compose.scrollChanged(atBottom: false)
            return
        }
        guard pendingReviewEntry == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReviewEntry = nil
            self.compose.scrollChanged(atBottom: false)
        }
        pendingReviewEntry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }

    private var composeBarHeight: CGFloat { ceil(composeFont().ascender - composeFont().descender) + 16 }

    func layoutComposeBar() {
        guard let bar = composeBar else { return }
        let h = composeBarHeight
        // isFlipped == true, so the bottom strip sits at the max-y edge.
        bar.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
    }

    private func updateComposeBar() {
        guard let bar = composeBar else { return }
        switch compose.phase {
        case .live:
            bar.isHidden = true
        case .reviewIdle:
            bar.monoFont = composeFont()
            bar.isHidden = false
            bar.showHint()
        case .reviewDraft:
            bar.monoFont = composeFont()
            bar.isHidden = false
            bar.showDraft(before: compose.before, preedit: compose.preedit, after: compose.after)
        }
        layoutComposeBar()
    }

    /// Keys the bar owns while reviewing. Returns true if fully consumed (no
    /// further handling), false to fall through (control / ⌘ chords).
    func handleReviewKeyDown(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags
        // Control chords (Ctrl-C/D/Z…) go to the engine, which snaps to bottom.
        // Discard the draft first so the snap doesn't auto-commit it.
        if mods.contains(.control) {
            compose.cancelForPassthrough()
            return false
        }
        switch event.keyCode {
        case 53:                      // Escape
            compose.escape(); return true
        case 36, 76:                  // Return, Keypad Enter
            if mods.contains(.shift) { compose.newline() }
            else if mods.contains(.command) { compose.commit(execute: true) }
            else { compose.commit(execute: false) }
            return true
        case 51:                      // Delete (Backspace)
            compose.backspace(); return true
        case 117:                     // Forward Delete
            compose.deleteForward(); return true
        case 123:                     // Left
            compose.moveLeft(); return true
        case 124:                     // Right
            compose.moveRight(); return true
        case 126:                     // Up
            reviewScroll(lines: -1); return true
        case 125:                     // Down
            reviewScroll(lines: 1); return true
        case 116:                     // Page Up
            reviewScroll(lines: -max(1, (currentSize?.rows ?? 10) - 2)); return true
        case 121:                     // Page Down
            reviewScroll(lines: max(1, (currentSize?.rows ?? 10) - 2)); return true
        default:
            return false              // printable / other → ⌘ handling + IME path
        }
    }

    /// Scroll the history view by `lines` (negative = up/older) without touching
    /// the engine key pipeline (so it doesn't snap to bottom).
    func reviewScroll(lines: Int) {
        guard let surface else { return }
        // Match scrollWheel's sign: positive y scrolls toward older content.
        ghostty_surface_mouse_scroll(surface, 0, Double(-lines), 0)
        ghostty_surface_refresh(surface)
        setNeedsDraw()
    }

    /// Inject a committed draft into the program's real input line via ghostty's
    /// paste pipeline (bracketed-paste wrapping when the app enabled it) without
    /// clobbering the system clipboard. `execute` then sends a CR to run it.
    private func injectComposed(_ text: String, execute: Bool) {
        guard let surface, !text.isEmpty else { return }
        GhosttyRuntime.shared.pendingPasteText = text
        GhosttyRuntime.shared.pasteSurface = surface
        GhosttySel.bindingAction("paste_from_clipboard", on: surface)
        if execute { sendReturn() }
    }

    private func sendReturn() {
        guard let surface else { return }
        let keyEvent = ghostty_input_key_s(
            action: GHOSTTY_ACTION_PRESS,
            mods: GHOSTTY_MODS_NONE,
            consumed_mods: GHOSTTY_MODS_NONE,
            keycode: 36,            // macOS virtual keycode for Return
            text: nil,
            unshifted_codepoint: 0,
            composing: false
        )
        ghostty_surface_key(surface, keyEvent)
    }

    private func scrollComposeToBottom() {
        guard let surface else { return }
        GhosttySel.bindingAction("scroll_to_bottom", on: surface)
        ghostty_surface_refresh(surface)
    }
}
#endif
