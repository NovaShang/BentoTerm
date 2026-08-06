import Foundation

/// How a string handed to us by a SOFTWARE keyboard becomes host bytes.
///
/// A third-party iOS keyboard has no way to send key EVENTS — a keyboard
/// extension can only insert text. So the "terminal keyboards" people install to
/// get arrows/ESC/Tab on iPhone insert the escape sequence itself: Up arrow
/// arrives at `insertText` as "\u{1b}[A", ESC as "\u{1b}", Tab as "\t".
///
/// That matters because libghostty's text channel (`ghostty_surface_text`) is for
/// PRINTABLE text and swallows control bytes — it's why a bare CR never ran the
/// line and why an inserted ESC vanished, leaving the shell to print the "[A"
/// tail as literal text. Control bytes therefore bypass the engine and go to the
/// host verbatim, the same path the accessory bar's own arrow keys already use.
public enum SoftKeyboardText {
    /// One ordered piece of an inserted string: printable text the engine can
    /// encode, or bytes that must reach the host untouched.
    public enum Segment: Equatable {
        case text(String)
        case raw(Data)
    }

    /// Split an inserted string into engine-text and straight-to-host runs.
    ///
    /// A string containing ESC is passed through WHOLE as one raw write: an
    /// escape sequence must land at the far end in one piece, because programs
    /// tell a lone ESC from a cursor key by whether the "[A" follows immediately
    /// (vim's `esctimeout`, readline's `keyseq-timeout`). Splitting it into
    /// ESC + "[A" over two writes risks two packets and a misread.
    public static func segments(for text: String) -> [Segment] {
        guard !text.isEmpty else { return [] }
        if text.unicodeScalars.contains(where: { $0.value == 0x1b }) {
            return [.raw(hostBytes(for: text))]
        }
        var out: [Segment] = []
        var run = String.UnicodeScalarView()
        func flushRun() {
            guard !run.isEmpty else { return }
            out.append(.text(String(run)))
            run = String.UnicodeScalarView()
        }
        var previousWasCR = false
        for u in text.unicodeScalars {
            guard isControl(u) else {
                run.append(u)
                previousWasCR = false
                continue
            }
            let wasCR = previousWasCR
            previousWasCR = u.value == 0x0d
            // The LF half of a CRLF pair would otherwise run the line twice.
            if u.value == 0x0a, wasCR { continue }
            flushRun()
            out.append(.raw(hostBytes(for: String(u))))
        }
        flushRun()
        return out
    }

    /// UTF-8 for the host, with the one substitution a terminal always needs:
    /// the soft keyboard delivers Return as LF, but a line editor (zsh, readline)
    /// only accepts the line on CR. A CRLF pair collapses to a single CR.
    public static func hostBytes(for text: String) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(text.utf8.count)
        var previousWasCR = false
        for byte in text.utf8 {
            switch byte {
            case 0x0a where previousWasCR:
                previousWasCR = false
            case 0x0a, 0x0d:
                out.append(0x0d)
                previousWasCR = byte == 0x0d
            default:
                out.append(byte)
                previousWasCR = false
            }
        }
        return Data(out)
    }

    /// C0 controls and DEL — everything the engine's text channel drops.
    private static func isControl(_ u: Unicode.Scalar) -> Bool {
        u.value < 0x20 || u.value == 0x7f
    }
}
