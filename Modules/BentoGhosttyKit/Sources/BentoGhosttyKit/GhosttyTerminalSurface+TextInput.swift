import BentoFilePreviewKit
import BentoFoundationKit
#if canImport(UIKit)
import UIKit
import GhosttyKit

extension GhosttyTerminalSurface {

    // MARK: - Input (UIKeyInput)

    public override var canBecomeFirstResponder: Bool { true }
    public var hasText: Bool { true }

    // ghostty_surface_key (used for hardware keys below) is ignored unless the
    // surface is focused, so keep ghostty's focus in sync with first-responder
    // status. (ghostty_surface_text / insertText doesn't need this, which is why
    // soft-keyboard text worked even without it.)
    @discardableResult
    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, true) }
        setNeedsDraw()
        return ok
    }

    @discardableResult
    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, false) }
        setNeedsDraw()
        return ok
    }

    public override var inputAccessoryView: UIView? {
        get { _inputAccessoryView }
        set { _inputAccessoryView = newValue }
    }

    public func insertText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        // Committed text (typing or a chosen IME candidate): drop any in-flight
        // composition preedit before sending it.
        if !markedTextValue.isEmpty {
            markedTextValue = ""
            GhosttySel.setPreedit(surface, nil)
        }
        // Software keyboards deliver control keys as TEXT: the system keyboard's
        // Return arrives as "\n", and a third-party terminal keyboard (the only
        // way to get arrows/ESC on iPhone — an extension can't send key events)
        // inserts the escape sequence itself, "\u{1b}[A" for Up.
        //
        // We CANNOT feed those through ghostty_surface_text: that channel is for
        // printable text and drops control bytes instead of emitting them to the
        // host — which is why Enter appeared to do nothing and why an inserted
        // ESC vanished, leaving the shell to print the bare "[A". So the string
        // is split: printable runs still go through ghostty (per-mode encoding
        // and IME keep working) while control bytes are written to the host
        // directly, the same proven path deleteBackward() and the accessory bar's
        // own arrow keys (sendString("\u{1b}[A")) already use.
        for segment in SoftKeyboardText.segments(for: text) {
            switch segment {
            case .raw(let data):
                onInput?(data)
            case .text(let run):
                let bytes = Array(run.utf8)
                bytes.withUnsafeBufferPointer { buf in
                    buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { ptr in
                        ghostty_surface_text(surface, ptr, UInt(buf.count))
                    }
                }
            }
        }
        setNeedsDraw()
    }

    public func deleteBackward() {
        // While composing, UIKit edits the marked text via setMarkedText — never
        // send a host backspace mid-composition.
        if !markedTextValue.isEmpty { unmarkText(); return }
        onInput?(Data([0x7f]))
    }

    // MARK: - IME (UITextInput marked text)
    //
    // The terminal isn't an editable text document, so this is a DEGENERATE
    // UITextInput: the "document" is just the in-flight IME composition (marked
    // text). Committed text and hardware keys still go through insertText /
    // pressesBegan. Marked text (Pinyin/CJK candidates) is rendered INLINE by the
    // engine via ghostty_surface_preedit; nothing reaches the host until commit.
    // Rendering is dirty-driven (like macOS), so each preedit change marks the
    // surface dirty and paints on the next display-link tick.

    public var tokenizer: UITextInputTokenizer { _tokenizer }

    public var markedTextRange: UITextRange? {
        markedTextValue.isEmpty ? nil : TermTextRange(0, markedTextValue.count)
    }

    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        let text = markedText ?? ""
        markedTextValue = text
        guard let surface else { return }
        GhosttySel.setPreedit(surface, text)
        setNeedsDraw()
    }

    public func unmarkText() {
        // The marked text was only a ghostty preedit OVERLAY — it was never
        // actually inserted into the document. So when the IME "unmarks" to
        // confirm a candidate (iOS treats our reported marked range as already-in-
        // document text and commits by unmarking, NOT by calling insertText), we
        // must COMMIT it to the host here, or the chosen characters are lost.
        // insertText-based commits already emptied markedTextValue, so this can't
        // double-send.
        let pending = markedTextValue
        if pending.isEmpty {
            if let surface { GhosttySel.setPreedit(surface, nil) }
            setNeedsDraw()
            return
        }
        insertText(pending)   // clears marked + preedit, then sends to the host
    }

    // MARK: - UITextInput document model (degenerate)

    public var beginningOfDocument: UITextPosition { TermTextPosition(0) }
    public var endOfDocument: UITextPosition { TermTextPosition(markedTextValue.count) }

    public var selectedTextRange: UITextRange? {
        get { let n = markedTextValue.count; return TermTextRange(n, n) }
        set { }
    }

    public func text(in range: UITextRange) -> String? {
        guard let r = range as? TermTextRange else { return nil }
        let chars = Array(markedTextValue)
        let f = min(max(r.from, 0), chars.count)
        let t = min(max(r.to, 0), chars.count)
        guard f <= t else { return "" }
        return String(chars[f..<t])
    }
    public func replace(_ range: UITextRange, withText text: String) {
        // Some input paths confirm a candidate via replace() rather than
        // insertText() — treat it as a commit so the text reaches the host.
        if !text.isEmpty { insertText(text) }
    }

    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        TermTextRange(off(fromPosition), off(toPosition))
    }
    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        TermTextPosition(off(position) + offset)
    }
    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        TermTextPosition(off(position) + offset)
    }
    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = off(position), b = off(other)
        return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        off(toPosition) - off(from)
    }
    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        (direction == .left || direction == .up) ? range.start : range.end
    }
    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        let p = off(position); return TermTextRange(p, p)
    }
    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) { }

    // Geometry — anchor inline UI (IME candidates) and keyboard avoidance at the
    // real terminal cursor, which isn't always at the bottom (TUIs put it
    // anywhere). Falls back to a bottom-left caret if the surface is gone.
    public func firstRect(for range: UITextRange) -> CGRect { caretRect(for: range.start) }
    public func caretRect(for position: UITextPosition) -> CGRect {
        cursorRect() ?? CGRect(x: 2, y: max(bounds.height - 24, 0), width: 2, height: 22)
    }

    /// The terminal cursor (insertion point) rect in this surface's coordinate
    /// space, from ghostty's IME point. ghostty reports LOGICAL POINTS with a
    /// TOP-LEFT origin relative to the surface — the same convention as
    /// `mouse_pos`/`pxPoint` (content scale applied internally), so no y-flip or
    /// scale division. nil if there's no live surface.
    public func cursorRect() -> CGRect? {
        guard let surface else { return nil }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let width = w > 1 ? CGFloat(w) : 2
        let height = h > 1 ? CGFloat(h) : 18
        return CGRect(x: CGFloat(x), y: CGFloat(y), width: width, height: height)
    }
    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    public func closestPosition(to point: CGPoint) -> UITextPosition? { TermTextPosition(0) }
    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.start }
    public func characterRange(at point: CGPoint) -> UITextRange? { nil }

    private func off(_ p: UITextPosition) -> Int { (p as? TermTextPosition)?.offset ?? 0 }

    // Hardware keys (arrows / Enter / Ctrl chords / function keys) arrive as
    // UIPress, not insertText. Route through ghostty_surface_key so the engine
    // encodes them (needs focus — handled above).
    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forwardPresses(presses, action: GHOSTTY_ACTION_PRESS) { return }
        super.pressesBegan(presses, with: event)
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forwardPresses(presses, action: GHOSTTY_ACTION_RELEASE) { return }
        super.pressesEnded(presses, with: event)
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forwardPresses(presses, action: GHOSTTY_ACTION_RELEASE) { return }
        super.pressesCancelled(presses, with: event)
    }

    private func forwardPresses(_ presses: Set<UIPress>, action: ghostty_input_action_e) -> Bool {
        guard let surface else { return false }
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            handled = true
            let keyMods = mods(from: key.modifierFlags)
            var keyEvent = ghostty_input_key_s(
                action: action,
                mods: keyMods,
                consumed_mods: GhosttyKeyMods.consumed(keyMods, surface: surface),
                keycode: UInt32(key.keyCode.rawValue),
                text: nil,
                unshifted_codepoint: key.charactersIgnoringModifiers.unicodeScalars.first?.value ?? 0,
                composing: false
            )
            let text = key.characters
            if text.isEmpty {
                ghostty_surface_key(surface, keyEvent)
            } else {
                text.utf8CString.withUnsafeBufferPointer { buf in
                    keyEvent.text = buf.baseAddress
                    ghostty_surface_key(surface, keyEvent)
                }
            }
        }
        return handled
    }

    private func mods(from flags: UIKeyModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.alternate) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.alphaShift) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }
}

/// Integer-offset position/range for the terminal's degenerate UITextInput
/// document (the document is just the in-flight IME composition).
private final class TermTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = max(0, offset) }
}

private final class TermTextRange: UITextRange {
    let from: Int
    let to: Int
    init(_ a: Int, _ b: Int) { from = min(a, b); to = max(a, b) }
    override var start: UITextPosition { TermTextPosition(from) }
    override var end: UITextPosition { TermTextPosition(to) }
    override var isEmpty: Bool { from == to }
}
#endif
