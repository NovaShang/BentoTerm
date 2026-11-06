#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFoundationKit
import AppKit
import Carbon   // TIS* — identifies whether the input source is a plain layout
import GhosttyKit

extension GhosttyTerminalSurface {

    // MARK: - Input

    // All key input goes through ghostty_surface_key (NOT ghostty_surface_text),
    // so the engine encodes everything correctly: printable text as text, Enter
    // as CR, arrows/function keys as escape sequences, Ctrl-chords as control
    // bytes. Feeding raw event.characters to ghostty_surface_text (the old
    // approach) echoed special keys as private-use glyphs and never sent CR.

    public override func keyDown(with event: NSEvent) {
        // Scroll-review-compose: while reviewing history, the bar owns navigation
        // and editing keys (returns true = consumed). Printable text still flows
        // through the IME path below and branches into the draft in insertText.
        if compose.isReviewing, handleReviewKeyDown(event) { return }

        if event.modifierFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased()
            switch key {
            case "d":
                // ⌘D / ⌘⇧D → split the active pane (iTerm2-style).
                onSplit?(!event.modifierFlags.contains(.shift))
                return
            case "c" where hasSelection:
                // ⌘C → copy the selection to the pasteboard (only when there IS
                // a selection; otherwise fall through so ⌘C can be a no-op
                // rather than interrupting).
                copySelection()
                return
            case "v":
                // While composing, ⌘V pastes into the draft, not the terminal.
                if compose.isReviewing {
                    if let s = TerminalClipboard.read() { compose.insertText(s) }
                } else {
                    pasteFromClipboard()
                }
                return
            case "a":
                _ = selectAll()
                return
            default:
                // Other ⌘ chords aren't text input — encode directly (bypass the
                // IME so we don't insert "v" etc.). They reach the engine and snap
                // to bottom, so bail the draft first to avoid an auto-commit.
                if compose.isReviewing { compose.cancelForPassthrough() }
                sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
                return
            }
        }

        // Ordinary typing on a plain keyboard layout doesn't need the input
        // method at all, and `handleEvent` is a synchronous IPC that blocks the
        // main thread — profiled at a 15.73ms median, 73ms worst case, with a
        // third-party IME active. Encode those keys directly. Anything that
        // could involve composition — an IME input source, an in-flight preedit,
        // or a modifier that can start a dead key — still takes the full route.
        if canBypassInputMethod(event) {
            sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
            return
        }

        // Everything else routes through the macOS input system so IME
        // composition (Chinese / Japanese / dead keys) works. The input context
        // calls back into our NSTextInputClient conformance: `insertText` for
        // committed text, `setMarkedText` for the in-flight composition,
        // `doCommandBySelector` for special keys. If the context doesn't consume
        // the event we encode it ourselves via the engine.
        keyEventForIME = event
        defer { keyEventForIME = nil }
        if inputContext?.handleEvent(event) != true {
            sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
        }
    }

    /// Whether this key event can skip the input method entirely.
    ///
    /// Deliberately conservative — a wrong `true` here breaks CJK input, which
    /// is far worse than the latency it saves:
    ///   - the active input source must be a plain keyboard LAYOUT, not an IME
    ///     (a Pinyin/Kana source reports `kTISTypeKeyboardInputMode` and is
    ///     excluded)
    ///   - no composition may be in flight (`markedText` empty)
    ///   - no modifier that can begin a dead-key sequence (⌥e → ´ works even on
    ///     ABC), so only shift/caps/fn/numpad are allowed through
    ///   - empty `characters` means the key produced no text, which is exactly
    ///     what a dead key does on press (US International's `'` and `` ` ``
    ///     take no modifier at all). Its continuation is then covered by the
    ///     `markedText` check above, since IMK marks the pending composition.
    ///   - the scroll-review draft owns its own keys, so not while reviewing
    private func canBypassInputMethod(_ event: NSEvent) -> Bool {
        guard markedText.length == 0, !compose.isReviewing else { return false }
        guard let chars = event.characters, !chars.isEmpty else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.isSubset(of: [.shift, .capsLock, .function, .numericPad]) else { return false }
        return Self.activeInputSourceIsPlainLayout
    }

    /// Cached because TIS lookups aren't free and this is consulted per key.
    /// Invalidated on the same notification that tells ghostty to rebuild its
    /// keyboard table (see GhosttyRuntime).
    private static var cachedPlainLayout: Bool?

    static func invalidateInputSourceCache() { cachedPlainLayout = nil }

    private static var activeInputSourceIsPlainLayout: Bool {
        if let cachedPlainLayout { return cachedPlainLayout }
        let value = computePlainLayout()
        cachedPlainLayout = value
        return value
    }

    private static func computePlainLayout() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType)
        else { return false }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        // kTISTypeKeyboardLayout = a layout with no input method behind it.
        // Everything else (input modes, input methods) must keep the IME path.
        return type == (kTISTypeKeyboardLayout as String)
    }

    public override func keyUp(with event: NSEvent) {
        // While reviewing, draft keys never reached the engine — don't leak a
        // stray key-up to it either.
        if compose.isReviewing { return }
        // Don't emit key-up while composing — the IME owns the sequence.
        guard markedText.length == 0 else { return }
        sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
    }

    /// `textOverride` supplies the committed text from the input system (e.g. the
    /// character `insertText` produced) so direct key input is encoded by
    /// ghostty's key pipeline rather than injected as raw text — see `insertText`.
    private func sendKeyEvent(_ event: NSEvent, action: ghostty_input_action_e, textOverride: String? = nil) {
        guard let surface else { return }

        var keyEvent = ghostty_input_key_s(
            action: action,
            mods: modsFromFlags(event.modifierFlags),
            consumed_mods: GhosttyKeyMods.consumed(modsFromFlags(event.modifierFlags),
                                                   surface: surface),
            keycode: UInt32(event.keyCode),
            text: nil,
            unshifted_codepoint: unshiftedCodepoint(from: event),
            composing: false
        )

        // ghostty_surface_key synchronously runs the engine's key encoding AND
        // its write-to-host callback, so this span covers everything from key to
        // "bytes handed to the tmux batcher".
        if let text = textOverride ?? translatedText(from: event) {
            text.withCString { ptr in
                keyEvent.text = ptr
                ghostty_surface_key(surface, keyEvent)
            }
        } else {
            ghostty_surface_key(surface, keyEvent)
        }
    }

    func modsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        guard let chars = event.characters(byApplyingModifiers: []),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    /// The text payload for the key event, or nil to let ghostty derive it from
    /// keycode. Control chars and private-use function keys (arrows etc.) return
    /// nil/stripped so the engine encodes them itself.
    private func translatedText(from event: NSEvent) -> String? {
        // Dedicated keys (Tab/Return/Keypad-Enter/Escape) carry a control-char
        // `characters` value (\t, \r, \e). Passing that text makes ghostty emit
        // it verbatim and skip its modifier-aware encoding — so Shift+Tab would
        // send a plain Tab instead of backtab (CSI Z). Return nil for these and
        // let ghostty encode from the keycode + mods.
        switch event.keyCode {
        case 48, 36, 76, 53: return nil   // Tab, Return, Keypad Enter, Escape
        default: break
        }
        guard let chars = event.characters else { return nil }
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            if scalar.value < 0x20 {
                // Control character — let ghostty encode it; pass the
                // unmodified-by-control text so it knows the base key.
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                // Private-use range = arrows / function keys; encode via keycode.
                return nil
            }
        }
        return chars
    }

    // MARK: - NSTextInputClient (IME)

    /// Committed text from the input system (plain typing, or the chosen IME
    /// candidate). Feed it to the engine as literal text and clear any preedit.
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""

        // Scroll-review-compose: committed text (plain typing or an IME candidate)
        // goes into the local draft, not the engine.
        if compose.isReviewing {
            markedText = NSMutableAttributedString()
            compose.insertText(text)
            return
        }

        let wasComposing = markedText.length > 0
        markedText = NSMutableAttributedString()
        if let surface { GhosttySel.setPreedit(surface, nil) }
        // Clearing the preedit changes only ghostty's local overlay, and the
        // prebuilt pull-model libghostty never emits a RENDER action, so nothing
        // repaints on its own. For a NON-empty commit we deliberately do NOT mark
        // dirty here: the committed text round-trips to the shell and its echo's
        // draw (draw-on-arrival) repaints the line with the text in place. Drawing
        // now would paint one composition-less frame *before* that echo lands —
        // the characters blink out and back, i.e. the "上屏整行闪一下" (and the
        // lingering highlighted preedit looked like the prior commit was selected).
        // Only an empty commit / cancel has no echo to repaint it, so draw then.
        if wasComposing && text.isEmpty { setNeedsDraw() }
        guard !text.isEmpty, let surface else { return }

        // Direct key input (not an IME composition commit) must go through the
        // KEY pipeline so ghostty encodes it per the active keyboard protocol
        // (kitty / CSI-u progressive enhancement). `ghostty_surface_text` injects
        // raw text and bypasses that — so TUIs that enabled enhanced key
        // reporting never see the keypress and their q/space/etc. bindings don't
        // fire. (Hardware keys on iOS already go through ghostty_surface_key.)
        if !wasComposing, let event = keyEventForIME {
            sendKeyEvent(event,
                         action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,
                         textOverride: text)
            return
        }

        // IME commit (e.g. pinyin → 你好) or other multi-char insertion: send as
        // literal text. (Routing this through the key pipeline was tried and makes
        // no difference — ghostty emits the same raw UTF-8 either way, verified by
        // tracing the host bytes.)
        let utf8 = Array(text.utf8)
        utf8.withUnsafeBufferPointer { buf in
            buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { p in
                ghostty_surface_text(surface, p, UInt(buf.count))
            }
        }
    }

    /// In-flight composition (e.g. pinyin before a candidate is picked). Show it
    /// as ghostty preedit; nothing is sent to the shell until commit.
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = NSMutableAttributedString(string: text)

        // Scroll-review-compose: show the in-flight composition in the bar, not
        // as engine preedit in the terminal.
        if compose.isReviewing {
            compose.setPreedit(text)
            return
        }

        guard let surface else { return }
        GhosttySel.setPreedit(surface, text)
        setNeedsDraw()
    }

    public func unmarkText() {
        markedText = NSMutableAttributedString()
        if let surface { GhosttySel.setPreedit(surface, nil) }
        // Same as insertText: the cleared preedit won't repaint on its own under
        // the dirty-driven renderer, so mark dirty here.
        setNeedsDraw()
    }

    public func hasMarkedText() -> Bool { markedText.length > 0 }

    // IMK queries these synchronously while `handleEvent` is blocked, so any
    // cost here would land inside the keystroke. Keep them constant-time.

    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length)
                              : NSRange(location: NSNotFound, length: 0)
    }

    public func attributedSubstring(forProposedRange range: NSRange,
                                    actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Where the IME candidate window should anchor. We don't track the exact
    /// cell cursor here, so anchor near the bottom-left of the surface — good
    /// enough that the candidate list is visible and near the typing area.
    public func firstRect(forCharacterRange range: NSRange,
                          actualRange: NSRangePointer?) -> NSRect {
        let local = NSRect(x: 4, y: bounds.height - 24, width: 1, height: 20)
        let inWindow = convert(local, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    /// Special keys routed by the input system (Enter/Tab/Backspace/arrows/Esc).
    /// Encode the stashed key event via the engine; the engine emits the right
    /// escape sequence / control byte.
    public override func doCommand(by selector: Selector) {
        // In review, special keys are handled in handleReviewKeyDown before the
        // IME ever sees them; ignore anything that still routes here.
        if compose.isReviewing { return }
        guard let event = keyEventForIME else { return }
        sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }
}
#endif
