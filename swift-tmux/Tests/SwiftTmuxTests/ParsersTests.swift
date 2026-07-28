import Testing
@testable import SwiftTmux

@Suite("list-panes / list-windows parsers")
struct ListParsersTests {
    @Test func parsePaneGeometryNested() {
        // checksum, total 181x45, then a horizontal split containing a vertical
        // split with a nested horizontal split — exercises {}, [] and leaves.
        let layout = "5504,181x45,0,0{56x45,0,0,38,124x45,57,0[124x30,57,0{71x30,57,0,39,52x30,129,0,70},124x14,57,31,58]}"
        let g = TmuxParsers.parsePaneGeometry(layout)
        #expect(g.count == 4)
        #expect(g.contains(.init(id: TmuxPaneID(38), width: 56, height: 45, x: 0, y: 0)))
        #expect(g.contains(.init(id: TmuxPaneID(39), width: 71, height: 30, x: 57, y: 0)))
        #expect(g.contains(.init(id: TmuxPaneID(70), width: 52, height: 30, x: 129, y: 0)))
        #expect(g.contains(.init(id: TmuxPaneID(58), width: 124, height: 14, x: 57, y: 31)))
        // Split nodes (181x45, 124x45, 124x30) must NOT appear as panes.
        #expect(!g.contains { $0.width == 181 })
    }

    @Test func parsePaneGeometrySingle() {
        let g = TmuxParsers.parsePaneGeometry("c1f3,80x24,0,0,0")
        #expect(g == [.init(id: TmuxPaneID(0), width: 80, height: 24, x: 0, y: 0)])
    }

    @Test func parsePaneListSingle() {
        let output = "%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:0:localhost"
        let panes = TmuxParsers.parsePaneList(output)
        #expect(panes.count == 1)
        #expect(panes[0].id == TmuxPaneID(0))
        #expect(panes[0].width == 80)
        #expect(panes[0].height == 24)
        #expect(panes[0].isActive)
        #expect(!panes[0].isZoomed)
        #expect(panes[0].currentCommand == "zsh")
        #expect(panes[0].title == "localhost")
        #expect(!panes[0].inMode)
    }

    @Test func parsePaneListMultiple() {
        let output = """
        %0:40:24:0:0:1:0:zsh:0:0:0:1:@1:0:host
        %1:40:24:40:0:0:0:vim:0:0:0:1:@1:0:host
        """
        let panes = TmuxParsers.parsePaneList(output)
        #expect(panes.count == 2)
        #expect(panes[1].x == 40)
        #expect(!panes[1].isActive)
        #expect(panes[1].currentCommand == "vim")
    }

    @Test func parsePaneListZoomed() {
        // window_zoomed_flag = 1 on the active pane.
        let output = "%0:120:40:0:0:1:1:vim:0:0:0:1:@1:0:host"
        let panes = TmuxParsers.parsePaneList(output)
        #expect(panes.count == 1)
        #expect(panes[0].isZoomed)
    }

    @Test func parsePaneListAlternateScreen() {
        // alternate_on = 1: a fullscreen TUI owns the screen (turn nav stands down).
        let panes = TmuxParsers.parsePaneList("%0:80:24:0:0:1:0:nvim:1:1:1:1:@1:0:host")
        #expect(panes.count == 1)
        #expect(panes[0].alternateOn)
        #expect(panes[0].title == "host")
        // …and the primary screen keeps it off.
        let plain = TmuxParsers.parsePaneList("%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:0:host")
        #expect(!plain[0].alternateOn)
    }

    @Test func parsePaneListInMode() {
        // pane_in_mode = 1: tmux has the pane in copy-mode. Bento can't see this
        // from the output stream (tmux draws the mode as ordinary pane content),
        // and while it's set our own scroll gestures fight tmux's.
        let panes = TmuxParsers.parsePaneList("%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:1:host")
        #expect(panes.count == 1)
        #expect(panes[0].inMode)
        #expect(panes[0].title == "host")
    }

    @Test func parsePaneListTitleWithColons() {
        // pane_title is the last field and may contain colons (e.g. a path).
        let output = "%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:0:user@host: ~/code"
        let panes = TmuxParsers.parsePaneList(output)
        #expect(panes.count == 1)
        #expect(panes[0].currentCommand == "zsh")
        #expect(panes[0].title == "user@host: ~/code")
    }

    @Test func parsePaneListSkipsGarbage() {
        let panes = TmuxParsers.parsePaneList("not-a-pane-line\n%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:0:host")
        #expect(panes.count == 1)
        #expect(panes[0].id == TmuxPaneID(0))
    }

    @Test func parseWindowListSingle() {
        // Format: window_id:window_index:window_active:window_layout:window_name
        // (name last).
        let output = "@0:3:1:b25d,80x24,0,0,0:zsh"
        let windows = TmuxParsers.parseWindowList(output)
        #expect(windows.count == 1)
        #expect(windows[0].id == TmuxWindowID(0))
        #expect(windows[0].index == 3)
        #expect(windows[0].name == "zsh")
        #expect(windows[0].layout == "b25d,80x24,0,0,0")
        #expect(windows[0].isActive == true)
    }

    /// `index:name` is what tmux itself prints in `list-windows` and what
    /// `select-window -t` targets — the UI shows the same string so a user can
    /// carry the label straight over to a tmux command line.
    @Test func indexedNameMatchesTmuxLabel() {
        let windows = TmuxParsers.parseWindowList("@0:2:1:b25d,80x24,0,0,0:claude")
        #expect(windows[0].indexedName == "2:claude")
        // Unknown index (listing without the field) must not render a stray ":".
        let legacy = TmuxWindow(id: TmuxWindowID(1), name: "zsh", panes: [], layout: nil)
        #expect(legacy.indexedName == "zsh")
    }

    /// A colon in the window name (e.g. a title like "host:~/dir") must NOT
    /// corrupt the layout field — regression for the Tiled⇄List restore, which
    /// persists window_layout. Name is last so its colons stay in the name.
    @Test func parseWindowListNameWithColons() {
        let output = "@3:7:0:6b1f,120x40,0,0{60x40,0,0,1,59x40,61,0,2}:host:~/src/app"
        let windows = TmuxParsers.parseWindowList(output)
        #expect(windows.count == 1)
        #expect(windows[0].id == TmuxWindowID(3))
        #expect(windows[0].index == 7)
        #expect(windows[0].isActive == false)
        #expect(windows[0].layout == "6b1f,120x40,0,0{60x40,0,0,1,59x40,61,0,2}")
        #expect(windows[0].name == "host:~/src/app")
    }
}

@Suite("tmux ls parser (PTY noise resilience)")
struct TmuxLsParserTests {
    /// Captured from a real iOS device run: zsh with syntax highlighting,
    /// 9 sessions, CRLF endings, OSC title escapes around the start marker,
    /// `[1m[7m%[27m[1m[0m` zsh "missing-newline" prompt indicator after end.
    @Test func parsesNineSessionsThroughOSCAndCRLF() {
        let startMarker = "__SPK_S_1A547748__GO__"
        let endMarker = "__SPK_E_1A547748__DONE__"

        // CRLF is critical here — Swift treats it as a single grapheme
        // cluster, so a splitter that compares to "\n" alone would yield
        // ONE giant line. We pin that we actually split per session.
        let body =
            "\r\n3: 1 windows (created Mon May  4 12:35:19 2026)" +
            "\r\n7: 1 windows (created Tue May 12 17:24:10 2026)" +
            "\r\nbim-claw: 1 windows (created Sun May 17 09:23:33 2026) (attached)" +
            "\r\nhelpxs: 1 windows (created Sat May  2 22:28:41 2026)" +
            "\r\nload-survey: 1 windows (created Tue Apr 28 22:40:54 2026)" +
            "\r\nnovashang_com: 1 windows (created Fri May  8 15:23:12 2026)" +
            "\r\noneline: 1 windows (created Wed May  6 22:58:05 2026)" +
            "\r\nspeakterm: 1 windows (created Thu May  7 21:48:26 2026) (attached)" +
            "\r\nvoltreality: 1 windows (created Tue Apr 28 16:52:08 2026) (attached)\r\n"

        let osc = "\u{1B}]2;tmux ls 2> /dev/null\u{07}\u{1B}]1;printf\u{07}"
        let promptTail = "\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[1m\u{1B}[0m"
        let raw = osc + startMarker + body + endMarker + "\r\n" + promptTail

        let result = TmuxParsers.parseTmuxLs(
            raw,
            startMarker: startMarker,
            endMarker: endMarker
        )
        #expect(result == [
            "3", "7", "bim-claw", "helpxs", "load-survey",
            "novashang_com", "oneline", "speakterm", "voltreality",
        ])
    }

    /// When the start marker is missing (e.g. printf-start failed silently)
    /// we still slice up to the end marker — better partial result than
    /// nothing.
    @Test func fallbackWhenStartMissing() {
        let endMarker = "__SPK_E_X__DONE__"
        let raw = "prompt junk\r\nfoo: 1 windows (created x)\r\n" + endMarker + "\r\n"
        let result = TmuxParsers.parseTmuxLs(raw, startMarker: "missing", endMarker: endMarker)
        #expect(result == ["foo"])
    }

    /// MOTD / banner lines that contain a colon but no `windows` keyword
    /// must NOT be reported as sessions.
    @Test func ignoresMOTDLines() {
        let raw =
            "__START__\r\nWelcome: please log in\r\nfoo: 2 windows (created y)\r\n__END__\r\n"
        let result = TmuxParsers.parseTmuxLs(raw, startMarker: "__START__", endMarker: "__END__")
        #expect(result == ["foo"])
    }

    /// The (attached) suffix must not be folded into the session name.
    @Test func keepsAttachedSuffixOutOfName() {
        let raw = "__S__\r\nmain: 3 windows (created z) (attached)\r\n__E__\r\n"
        let result = TmuxParsers.parseTmuxLs(raw, startMarker: "__S__", endMarker: "__E__")
        #expect(result == ["main"])
    }

    /// Session names with allowed punctuation pass; weird chars get
    /// filtered out.
    @Test func acceptsAllowedNameChars() {
        let raw =
            "__S__\r\n" +
            "alpha-1: 1 windows (created)\r\n" +
            "beta_2: 1 windows (created)\r\n" +
            "v1.2.3: 1 windows (created)\r\n" +
            "weird/bad: 1 windows (created)\r\n" +
            "__E__\r\n"
        let result = TmuxParsers.parseTmuxLs(raw, startMarker: "__S__", endMarker: "__E__")
        #expect(result == ["alpha-1", "beta_2", "v1.2.3"])
    }

    /// Empty body returns empty array (server not running).
    @Test func noSessionsYieldsEmpty() {
        let raw = "__S__\r\n\r\n__E__\r\n"
        let result = TmuxParsers.parseTmuxLs(raw, startMarker: "__S__", endMarker: "__E__")
        #expect(result.isEmpty)
    }

    /// Pre-marker shell echo with the SPLIT halves of the marker must not
    /// be confused for the runtime concatenated marker.
    @Test func shellEchoOfSplitHalvesDoesNotMatch() {
        // Mirror exactly what zsh would echo for:
        //   printf '%s%s\n' '__SPK_S_T_' '_GO__'; tmux ls
        let raw =
            "printf '%s%s\\n' '__SPK_S_T_' '_GO__'; tmux ls\r\n" +
            "__SPK_S_T__GO__\r\n" +
            "alpha: 1 windows (x)\r\n" +
            "__SPK_E_T__DONE__\r\n"
        let result = TmuxParsers.parseTmuxLs(
            raw,
            startMarker: "__SPK_S_T__GO__",
            endMarker: "__SPK_E_T__DONE__"
        )
        // If the split-halves heuristic broke, the parser would have sliced
        // from the FIRST start match (inside the echo) and would miss
        // "alpha" or pick up garbage. We want exactly ["alpha"].
        #expect(result == ["alpha"])
    }
}
