import Foundation
import BentoFoundationKit
import BentoFoundationKit

/// Platform-neutral state machine for the scroll-review-compose feature
/// (see `docs/scroll-review-compose.md`).
///
/// When the user scrolls up into history, typing would normally snap the view
/// back to the bottom (verified: scroll-on-keystroke is on). Instead we capture
/// keystrokes into a *local draft* shown in a bottom bar, leaving the history
/// view put, and only inject the draft into the program's real input line on an
/// explicit commit. The platform surface owns key routing + the bar UI and the
/// side-effect callbacks; this type owns the phase + draft logic only.
///
/// Draft is stored as `before`/`after` of the caret (a tiny gap buffer) so edits
/// never invalidate a `String.Index`. `preedit` holds the in-flight IME
/// composition, rendered at the caret but not yet part of the draft.
@MainActor
final class ScrollReviewCompose {

    enum Phase: Equatable {
        case live          // at/near bottom — keys pass straight to the engine
        case reviewIdle    // scrolled up, empty draft — show a low-key hint
        case reviewDraft   // scrolled up, draft has content — show the bar
    }

    /// Master feature switch. When false the model stays in `.live` forever and
    /// the surface skips every gate (zero behavior change).
    var isEnabled = true

    private(set) var phase: Phase = .live
    private(set) var before = ""
    private(set) var after = ""
    private(set) var preedit = ""

    // MARK: Side effects — wired by the platform surface.

    /// The bar should redraw (phase or draft content changed).
    var onChange: (() -> Void)?
    /// Inject `text` into the program's real input line. `execute` appends a
    /// carriage return to run it; otherwise the text just lands in the input.
    var onInject: ((_ text: String, _ execute: Bool) -> Void)?
    /// Snap the viewport to the bottom (return to the live prompt).
    var onSnapToBottom: (() -> Void)?

    // MARK: Derived

    var isReviewing: Bool { phase != .live }
    var draftText: String { before + after }
    var isEmpty: Bool { before.isEmpty && after.isEmpty }

    // MARK: Scroll feed (from SCROLLBAR action)

    /// Called on every scrollbar update. `atBottom` is `offset+len >= total`.
    func scrollChanged(atBottom: Bool) {
        guard isEnabled else { return }
        if atBottom {
            // Reached the bottom. If a draft is in flight and the user got here
            // by scrolling (draft still present), hand it off into the real
            // input. Control-key passthrough clears the draft first, so a snap
            // it triggers lands here empty and just returns to live.
            if phase == .reviewDraft, !isEmpty {
                commit(execute: false)
            } else if phase != .live {
                resetDraft()
                setPhase(.live)
            }
        } else {
            // Scrolled up into history.
            if phase == .live { setPhase(.reviewIdle) }
        }
    }

    // MARK: Text input (from the platform key/IME pipeline)

    /// Committed text — a printable keystroke or an IME candidate. Appends to the
    /// draft at the caret.
    func insertText(_ s: String) {
        guard isEnabled, isReviewing, !s.isEmpty else { return }
        preedit = ""
        before += s
        setPhase(.reviewDraft)
        onChange?()
    }

    /// In-flight IME composition (pinyin before a candidate is chosen). Shown at
    /// the caret; not part of the draft until committed via `insertText`.
    func setPreedit(_ s: String) {
        guard isEnabled, isReviewing else { return }
        preedit = s
        if !s.isEmpty { setPhase(.reviewDraft) }
        onChange?()
    }

    func backspace() {
        guard isReviewing else { return }
        if !preedit.isEmpty { return }   // IME owns deletes while composing
        if !before.isEmpty { before.removeLast() }
        if isEmpty { setPhase(.reviewIdle) }
        onChange?()
    }

    func deleteForward() {
        guard isReviewing, preedit.isEmpty else { return }
        if !after.isEmpty { after.removeFirst() }
        if isEmpty { setPhase(.reviewIdle) }
        onChange?()
    }

    func moveLeft() {
        guard isReviewing, preedit.isEmpty, let c = before.last else { return }
        before.removeLast()
        after = String(c) + after
        onChange?()
    }

    func moveRight() {
        guard isReviewing, preedit.isEmpty, let c = after.first else { return }
        after.removeFirst()
        before.append(c)
        onChange?()
    }

    /// Shift+Enter — insert a newline into the draft (multi-line input).
    func newline() {
        guard isReviewing else { return }
        before += "\n"
        setPhase(.reviewDraft)
        onChange?()
    }

    // MARK: Exits

    /// Enter (execute=false) / Cmd·Ctrl+Enter (execute=true). Injects a non-empty
    /// draft into the real input, then snaps to bottom and returns to live.
    func commit(execute: Bool) {
        guard isReviewing else { return }
        let text = draftText
        resetDraft()
        setPhase(.live)
        if !text.isEmpty { onInject?(text, execute) }
        onSnapToBottom?()
        onChange?()
    }

    /// Esc. First press clears a non-empty draft (stay scrolled in idle); a press
    /// with no draft returns to the live prompt (snap to bottom).
    func escape() {
        guard isReviewing else { return }
        if phase == .reviewDraft, !isEmpty {
            resetDraft()
            setPhase(.reviewIdle)
            onChange?()
        } else {
            resetDraft()
            setPhase(.live)
            onSnapToBottom?()
            onChange?()
        }
    }

    /// A control chord (Ctrl-C/D/Z…) is about to be forwarded to the engine,
    /// which will snap to bottom. Discard the draft and drop to live FIRST so the
    /// resulting `atBottom` doesn't auto-commit it. (v1: a control chord cancels
    /// the in-progress draft — semantically "abort".)
    func cancelForPassthrough() {
        guard isReviewing else { return }
        resetDraft()
        setPhase(.live)
        onChange?()
    }

    // MARK: - Internals

    private func resetDraft() {
        before = ""; after = ""; preedit = ""
    }

    private func setPhase(_ p: Phase) {
        guard phase != p else { return }
        phase = p
        ComposeDebug.log("compose phase → \(p)")
        // Every phase change must refresh the bar (show hint / show draft / hide).
        // Transitions driven purely by scrolling (live↔reviewIdle, reviewIdle→
        // live) have no other onChange, so the bar would otherwise go stale —
        // the hint wouldn't appear on scroll-up, and the bar wouldn't close when
        // scrolling back to the bottom. Content-only edits still call onChange
        // themselves (phase unchanged → this guard returns early).
        onChange?()
    }
}
