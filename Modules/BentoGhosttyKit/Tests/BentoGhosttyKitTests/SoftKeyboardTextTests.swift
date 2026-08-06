import Foundation
import Testing
@testable import BentoGhosttyKit

/// What a software keyboard's inserted string must become on the wire. The cases
/// are written as the bytes a program at the far end has to receive (the xterm
/// cursor keys, CR for Return), not re-derived from the encoder.
struct SoftKeyboardTextTests {

    private func raws(_ text: String) -> [String] {
        SoftKeyboardText.segments(for: text).compactMap {
            if case .raw(let d) = $0 { return String(decoding: d, as: UTF8.self) }
            return nil
        }
    }

    private func texts(_ text: String) -> [String] {
        SoftKeyboardText.segments(for: text).compactMap {
            if case .text(let s) = $0 { return s }
            return nil
        }
    }

    // MARK: - Third-party terminal keyboards

    /// The reported bug: a custom keyboard inserts the cursor key's escape
    /// sequence as text. Sent through the engine's text channel the ESC is
    /// dropped and the shell prints "[A"; it has to reach the host verbatim.
    @Test func cursorKeySequenceGoesToTheHostUntouched() {
        #expect(SoftKeyboardText.segments(for: "\u{1b}[A") == [.raw(Data("\u{1b}[A".utf8))])
        #expect(raws("\u{1b}[D") == ["\u{1b}[D"])
    }

    /// Application-cursor-mode (SS3) and Alt-chords are the same passthrough.
    @Test func otherEscapeFormsPassThrough() {
        #expect(raws("\u{1b}OA") == ["\u{1b}OA"])
        #expect(raws("\u{1b}") == ["\u{1b}"])
        #expect(raws("\u{1b}b") == ["\u{1b}b"])
    }

    /// An escape sequence must land in ONE write: programs tell a lone ESC from
    /// a cursor key by whether the tail follows immediately, so a string with an
    /// ESC in it is never split into engine-text and raw pieces.
    @Test func escapeSequenceIsASingleWrite() {
        let segments = SoftKeyboardText.segments(for: "ls\u{1b}[A")
        #expect(segments == [.raw(Data("ls\u{1b}[A".utf8))])
    }

    // MARK: - Control keys with no ESC

    @Test func tabAndControlCharsReachTheHost() {
        #expect(raws("\t") == ["\t"])
        #expect(raws("\u{03}") == ["\u{03}"])   // Ctrl-C
        #expect(raws("\u{7f}") == ["\u{7f}"])   // DEL
    }

    /// Return arrives from the soft keyboard as LF, but a line editor only runs
    /// the line on CR.
    @Test func returnBecomesCarriageReturn() {
        #expect(SoftKeyboardText.segments(for: "\n") == [.raw(Data([0x0d]))])
        #expect(SoftKeyboardText.segments(for: "\r") == [.raw(Data([0x0d]))])
    }

    /// A CRLF pair is one Return, not two — otherwise a pasted line runs twice.
    @Test func crlfIsASingleReturn() {
        #expect(SoftKeyboardText.segments(for: "\r\n") == [.raw(Data([0x0d]))])
        #expect(SoftKeyboardText.hostBytes(for: "a\r\nb") == Data("a\rb".utf8))
        #expect(SoftKeyboardText.segments(for: "\n\n")
                == [.raw(Data([0x0d])), .raw(Data([0x0d]))])
    }

    // MARK: - Ordinary typing still goes through the engine

    @Test func printableTextStaysOnTheEngineChannel() {
        #expect(SoftKeyboardText.segments(for: "git status") == [.text("git status")])
        #expect(SoftKeyboardText.segments(for: "你好") == [.text("你好")])
        #expect(SoftKeyboardText.segments(for: "") == [])
    }

    /// Mixed input keeps its order: text, the control byte, then the rest.
    @Test func mixedInputPreservesOrder() {
        #expect(SoftKeyboardText.segments(for: "ls\ncd") == [
            .text("ls"), .raw(Data([0x0d])), .text("cd"),
        ])
        #expect(texts("a\tb") == ["a", "b"])
    }
}
