import Testing
@testable import BentoTmuxKit

@Suite("ANSI stripping")
struct ANSITests {
    @Test func stripsCSI() {
        let s = "\u{1B}[31mred\u{1B}[0m"
        #expect(ANSI.strip(s) == "red")
    }

    @Test func stripsCSIWithParameters() {
        let s = "\u{1B}[1;7;38;5;202mhi\u{1B}[0m"
        #expect(ANSI.strip(s) == "hi")
    }

    @Test func stripsOSCTerminatedByBEL() {
        let s = "before\u{1B}]2;title here\u{07}after"
        #expect(ANSI.strip(s) == "beforeafter")
    }

    @Test func stripsOSCTerminatedByST() {
        let s = "before\u{1B}]1;icon\u{1B}\\after"
        #expect(ANSI.strip(s) == "beforeafter")
    }

    /// Real shells regularly emit `ESC]2;...ESC]1;...BEL` — OSC 2 has no BEL
    /// of its own, just the next ESC starting OSC 1. The first stripper
    /// must NOT eat the second sequence's start byte.
    @Test func stripsAdjacentOSCs() {
        let s = "x\u{1B}]2;running\u{1B}]1;icon\u{07}y"
        // OSC 2 ends right before \u{1B}]1; (escape boundary).
        // OSC 1 ends at BEL.
        // Result: "xy".
        #expect(ANSI.strip(s) == "xy")
    }

    @Test func stripsBareEsc() {
        // Charset selection sequences are 2-byte: ESC + final.
        let s = "x\u{1B}Bcurrent\u{1B}(0"
        #expect(ANSI.strip(s) == "xcurrent")
    }

    @Test func idempotent() {
        let s = "no escapes here"
        #expect(ANSI.strip(s) == s)
    }

    @Test func handlesEmptyOSC() {
        let s = "a\u{1B}]\u{07}b"
        #expect(ANSI.strip(s) == "ab")
    }

    @Test func preservesNewlines() {
        let s = "\u{1B}[31mline1\u{1B}[0m\nline2"
        #expect(ANSI.strip(s) == "line1\nline2")
    }
}
