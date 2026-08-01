import Testing
@testable import BentoTmuxKit

@Suite("TmuxCommand builder")
struct CommandTests {
    @Test func splitWindowCommand() {
        let cmd = TmuxCommand.splitWindow(target: TmuxPaneID(0), horizontal: true)
        #expect(cmd.commandString == "split-window -h -t %0 -c '#{pane_current_path}'")
    }

    @Test func splitWindowVertical() {
        let cmd = TmuxCommand.splitWindow(target: TmuxPaneID(2), horizontal: false)
        #expect(cmd.commandString == "split-window -v -t %2 -c '#{pane_current_path}'")
    }

    @Test func newWindowPlainShell() {
        let cmd = TmuxCommand.newWindow(path: "/tmp")
        #expect(cmd.commandString == "new-window -c /tmp")
    }

    @Test func newWindowShellCommandIsQuoted() {
        // "Path & Command…": a typed command line gets shell-quoted.
        let cmd = TmuxCommand.newWindow(path: "/tmp", command: .shell("claude --resume"))
        #expect(cmd.commandString == "new-window -c /tmp 'claude --resume'")
    }

    @Test func newWindowDuplicateCurrentSplicesVerbatim() {
        // "Duplicate Current": #{pane_start_command} is already tmux-quoted
        // (a spaced arg comes back as `"sleep 300"`). It must be spliced
        // verbatim — re-quoting it would exec a program named `sleep 300` and
        // the window would vanish the instant it opened.
        let cmd = TmuxCommand.newWindow(path: "/tmp", command: .tmuxSyntax("\"sleep 300\""))
        #expect(cmd.commandString == "new-window -c /tmp \"sleep 300\"")
    }

    @Test func splitWindowDuplicateCurrentSplicesVerbatim() {
        // Tiled mode's "Split — Duplicate Current" shares the same path.
        let cmd = TmuxCommand.splitWindow(
            target: TmuxPaneID(0), horizontal: true, command: .tmuxSyntax("nano \"a b.txt\""))
        #expect(cmd.commandString == "split-window -h -t %0 -c '#{pane_current_path}' nano \"a b.txt\"")
    }

    @Test func sendKeysLiteral() {
        let cmd = TmuxCommand.sendKeys(pane: TmuxPaneID(1), keys: "hello", literal: true)
        #expect(cmd.commandString == "send-keys -t %1 -l hello")
    }

    @Test func sendKeysWithSpacesEscaped() {
        let cmd = TmuxCommand.sendKeys(pane: TmuxPaneID(1), keys: "hello world", literal: true)
        #expect(cmd.commandString == "send-keys -t %1 -l 'hello world'")
    }

    @Test func refreshClient() {
        let cmd = TmuxCommand.refreshClient(width: 120, height: 40)
        #expect(cmd.commandString == "refresh-client -C 120,40")
    }

    @Test func listPanesFormat() {
        let cmd = TmuxCommand.listPanes()
        #expect(cmd.commandString.hasPrefix("list-panes -F "))
        #expect(cmd.commandString.contains("#{pane_id}"))
        #expect(cmd.commandString.contains("#{pane_active}"))
    }

    @Test func copyModeCommandUsesXAndRepeat() {
        // -X sends a copy-mode COMMAND (not a key), so it is independent of the
        // user's vi/emacs copy-mode bindings.
        let scroll = TmuxCommand.copyModeCommand(pane: TmuxPaneID(3), command: "scroll-up", count: 4)
        #expect(scroll.commandString == "send-keys -t %3 -X -N 4 scroll-up")
        // A count of 1 (or none) omits -N.
        let cancel = TmuxCommand.copyModeCommand(pane: TmuxPaneID(3), command: "cancel")
        #expect(cancel.commandString == "send-keys -t %3 -X cancel")
    }

    @Test func listWindowsFormat() {
        let cmd = TmuxCommand.listWindows()
        #expect(cmd.commandString.hasPrefix("list-windows -F "))
        #expect(cmd.commandString.contains("#{window_id}"))
    }

    @Test func capturePaneHasFlags() {
        // Default is plain text (no -e): detection wants clean text for matching.
        let cmd = TmuxCommand.capturePane(id: TmuxPaneID(3), lines: 50)
        #expect(cmd.commandString == "capture-pane -t %3 -p -J -S -50")
    }

    @Test func capturePaneWithEscapesKeepsColor() {
        // Display seeding passes escapes: true so SGR color/style codes survive.
        let cmd = TmuxCommand.capturePane(id: TmuxPaneID(3), lines: 50, escapes: true)
        #expect(cmd.commandString == "capture-pane -t %3 -p -J -e -S -50")
    }

    @Test func resizePaneByDirection() {
        let cmd = TmuxCommand.resizePaneBy(id: TmuxPaneID(0), direction: "L", amount: 4)
        #expect(cmd.commandString == "resize-pane -t %0 -L 4")
    }

    @Test func zoomPane() {
        let cmd = TmuxCommand.zoomPane(id: TmuxPaneID(5))
        #expect(cmd.commandString == "resize-pane -Z -t %5")
    }

    @Test func killSessionWithoutName() {
        let cmd = TmuxCommand.killSession()
        #expect(cmd.commandString == "kill-session")
    }

    @Test func killSessionWithName() {
        let cmd = TmuxCommand.killSession(name: "main")
        #expect(cmd.commandString == "kill-session -t main")
    }

    @Test func newSessionGrouped() {
        let cmd = TmuxCommand.newSession(name: "main-mobile", groupWith: "main")
        #expect(cmd.commandString == "new-session -d -t main -s main-mobile")
    }

    @Test func argEscapingForQuote() {
        let cmd = TmuxCommand.renameWindow(id: TmuxWindowID(0), name: "it's mine")
        #expect(cmd.commandString == "rename-window -t @0 'it'\\''s mine'")
    }

    @Test func killWindow() {
        let cmd = TmuxCommand.killWindow(id: TmuxWindowID(3))
        #expect(cmd.commandString == "kill-window -t @3")
    }

    @Test func breakPaneSameSession() {
        let cmd = TmuxCommand.breakPane(source: TmuxPaneID(4), name: "claude")
        #expect(cmd.commandString == "break-pane -d -s %4 -n claude")
    }

    @Test func breakPaneToOtherSession() {
        // Move-to-session: the trailing colon (empty window part) lands the
        // pane as a new window at the target's next free index (verified live).
        let cmd = TmuxCommand.breakPane(source: TmuxPaneID(4), name: "claude", targetSession: "work")
        #expect(cmd.commandString == "break-pane -d -s %4 -n claude -t work:")
    }

    @Test func breakPaneToSessionWithSpaceQuoted() {
        let cmd = TmuxCommand.breakPane(source: TmuxPaneID(4), targetSession: "my project")
        #expect(cmd.commandString == "break-pane -d -s %4 -t 'my project:'")
    }

    @Test func killWindowByRawTarget() {
        // `^` = the session's lowest-index window (a fresh session's
        // placeholder); names with spaces quote as one target.
        let cmd = TmuxCommand.killWindowTarget("my project:^")
        #expect(cmd.commandString == "kill-window -t 'my project:^'")
    }

    @Test func movePaneDockRight() {
        // Drop-zone edge landing: re-split the target and dock the dragged
        // pane in the new half. No -b → after (right/bottom); no -d → the
        // dragged pane lands focused.
        let cmd = TmuxCommand.movePane(
            source: TmuxPaneID(4), target: TmuxPaneID(1), horizontal: true, before: false)
        #expect(cmd.commandString == "move-pane -h -s %4 -t %1")
    }

    @Test func movePaneDockAbove() {
        let cmd = TmuxCommand.movePane(
            source: TmuxPaneID(4), target: TmuxPaneID(1), horizontal: false, before: true)
        #expect(cmd.commandString == "move-pane -v -b -s %4 -t %1")
    }

    @Test func moveWindowToOtherSession() {
        // Whole-window move (Focus/List rows): layout, panes, and name travel
        // intact; trailing colon = target's next free index (verified live).
        let cmd = TmuxCommand.moveWindow(id: TmuxWindowID(7), targetSession: "work")
        #expect(cmd.commandString == "move-window -d -s @7 -t work:")
    }

    @Test func joinPaneIntoSessionCurrentWindow() {
        // Parallel landing: split the target session's active pane (verified
        // live; an emptied source session dies on its own).
        let cmd = TmuxCommand.joinPaneToSession(source: TmuxPaneID(4), session: "work")
        #expect(cmd.commandString == "join-pane -d -s %4 -t work:")
    }

    @Test func selectLayoutByRawTarget() {
        let cmd = TmuxCommand.selectLayoutTarget(target: "work:", layout: "tiled")
        #expect(cmd.commandString == "select-layout -t work: tiled")
    }

    // A window-layout string with a horizontal split carries `{…}`. tmux's
    // command parser reads an unquoted `{` as a brace command group and fails
    // the whole command with a silent `syntax error` over control mode — which
    // is what dropped the Parallel⇄Focus layout (never applied on merge → even
    // auto-layout). The layout must be single-quoted.
    @Test func selectLayoutQuotesBraceLayout() {
        let layout = "6b32,208x50,0,0{104x50,0,0,0,103x50,105,0,1}"
        let cmd = TmuxCommand.selectLayout(window: TmuxWindowID(0), layout: layout)
        #expect(cmd.commandString == "select-layout -t @0 '\(layout)'")
    }

    // Same brace hazard on the SAVE side: `set-option @bento_orig_layout …{…}`
    // must be quoted or the snapshot is never stored and merge-back has nothing
    // to restore.
    @Test func setSessionOptionQuotesBraceLayout() {
        let layout = "6b32,208x50,0,0{104x50,0,0,0,103x50,105,0,1}"
        let cmd = TmuxCommand.setSessionOption(name: "@bento_orig_layout", value: layout)
        #expect(cmd.commandString == "set-option @bento_orig_layout '\(layout)'")
    }

    // A vertical-only split serializes with `[…]` (not special to the parser)
    // — still quoted, since quoting is always safe and the pane-order option is
    // space-joined anyway.
    @Test func setSessionOptionQuotesBracketLayout() {
        let layout = "ee54,208x50,0,0[208x25,0,0,0,208x24,0,26,1]"
        let cmd = TmuxCommand.setSessionOption(name: "@bento_orig_layout", value: layout)
        #expect(cmd.commandString == "set-option @bento_orig_layout '\(layout)'")
    }
}

@Suite("Tmux ID parsing")
struct IDParsingTests {
    @Test func paneID() {
        let id = TmuxPaneID(string: "%5")
        #expect(id != nil)
        #expect(id?.raw == 5)
        #expect(id?.description == "%5")
    }

    @Test func windowID() {
        let id = TmuxWindowID(string: "@10")
        #expect(id != nil)
        #expect(id?.raw == 10)
    }

    @Test func sessionID() {
        let id = TmuxSessionID(string: "$0")
        #expect(id != nil)
        #expect(id?.raw == 0)
    }

    @Test func wrongSigilRejected() {
        #expect(TmuxPaneID(string: "0") == nil)
        #expect(TmuxPaneID(string: "@0") == nil)
        #expect(TmuxWindowID(string: "%0") == nil)
        #expect(TmuxSessionID(string: "@0") == nil)
    }

    @Test func nonNumericRejected() {
        #expect(TmuxPaneID(string: "%abc") == nil)
    }
}
