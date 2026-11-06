import Testing
@testable import BentoTmuxKit

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
        let output = "%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:0:::localhost"
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
        %0:40:24:0:0:1:0:zsh:0:0:0:1:@1:0:::host
        %1:40:24:40:0:0:0:vim:0:0:0:1:@1:0:::host
        """
        let panes = TmuxParsers.parsePaneList(output)
        #expect(panes.count == 2)
        #expect(panes[1].x == 40)
        #expect(!panes[1].isActive)
        #expect(panes[1].currentCommand == "vim")
    }

    @Test func parsePaneListZoomed() {
        // window_zoomed_flag = 1 on the active pane.
        let output = "%0:120:40:0:0:1:1:vim:0:0:0:1:@1:0:::host"
        let panes = TmuxParsers.parsePaneList(output)
        #expect(panes.count == 1)
        #expect(panes[0].isZoomed)
    }

    @Test func parsePaneListAlternateScreen() {
        // alternate_on = 1: a fullscreen TUI owns the screen.
        let panes = TmuxParsers.parsePaneList("%0:80:24:0:0:1:0:nvim:1:1:1:1:@1:0:::host")
        #expect(panes.count == 1)
        #expect(panes[0].alternateOn)
        #expect(panes[0].title == "host")
        // …and the primary screen keeps it off.
        let plain = TmuxParsers.parsePaneList("%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:0:::host")
        #expect(!plain[0].alternateOn)
    }

    @Test func parsePaneListInMode() {
        // pane_in_mode = 1: tmux has the pane in copy-mode. Bento can't see this
        // from the output stream (tmux draws the mode as ordinary pane content),
        // and while it's set our own scroll gestures fight tmux's.
        let panes = TmuxParsers.parsePaneList("%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:1:::host")
        #expect(panes.count == 1)
        #expect(panes[0].inMode)
        #expect(panes[0].title == "host")
    }

    @Test func parsePaneListTitleWithColons() {
        // pane_title is the last field and may contain colons (e.g. a path).
        let output = "%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:0:::user@host: ~/code"
        let panes = TmuxParsers.parsePaneList(output)
        #expect(panes.count == 1)
        #expect(panes[0].currentCommand == "zsh")
        #expect(panes[0].title == "user@host: ~/code")
    }

    @Test func parsePaneListAgentHookOptions() {
        // `@bento_agent` / `@bento_state`, set by an agent's own hooks, sit
        // just before the title.
        let panes = TmuxParsers.parsePaneList("%0:80:24:0:0:1:0:node:0:0:0:1:@1:0:codex:awaiting:host")
        #expect(panes.count == 1)
        #expect(panes[0].agent == "codex")
        #expect(panes[0].agentState == "awaiting")
        #expect(panes[0].title == "host")
        // Unset options expand to nothing, which reads as nil.
        let plain = TmuxParsers.parsePaneList("%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:0:::host")
        #expect(plain[0].agent == nil)
        #expect(plain[0].agentState == nil)
        #expect(plain[0].title == "host")
    }

    @Test func parsePaneListSkipsGarbage() {
        let panes = TmuxParsers.parsePaneList("not-a-pane-line\n%0:80:24:0:0:1:0:zsh:0:0:0:1:@1:0:::host")
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
