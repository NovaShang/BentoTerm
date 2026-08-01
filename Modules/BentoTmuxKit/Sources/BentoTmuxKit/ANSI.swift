import Foundation

/// ANSI escape-sequence stripping. Handles CSI (`ESC [ ... letter`), OSC
/// (`ESC ] ... BEL` or `ESC ] ... ESC \`), and bare-`ESC` 2-byte sequences.
///
/// Implemented as a regex rather than a hand-rolled state machine, because
/// unterminated OSCs (which real shells emit) tripped the earlier state
/// machine into eating ESC bytes belonging to the *next* sequence — that bug
/// silently swallowed the bulk of `tmux ls` output. The regex matches
/// optional terminators and never consumes more than one sequence at a time.
public enum ANSI {
    /// Strip every CSI / OSC / bare-ESC sequence from `s` and return the
    /// remainder. Idempotent and safe to call on arbitrary text.
    public static func strip(_ s: String) -> String {
        // CSI:        ESC [ <params 0-9;?> <intermediates SP-/> <final @-~>
        // OSC:        ESC ] <data not BEL/ESC> (BEL | ESC \)?    — terminator optional
        // Charset:    ESC <intermediate SP-/> <final SP-~>       — e.g. `ESC ( 0`
        // Short ESC:  ESC + any one byte                          — fallback for 2-byte
        let pattern = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
            + "|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)?"
            + "|\u{1B}[ -/][ -~]"
            + "|\u{1B}."
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return s
        }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }
}
