import Testing
@testable import BentoUISharedKit

/// The poll that feeds the sidebar lists PANES and folds them into windows.
@Suite("Sidebar: pane listing")
struct PaneListingTests {

    private func line(_ index: Int, _ name: String, active: Bool, panes: Int, paneActive: Bool,
                      state: String, command: String, path: String, title: String,
                      id: String = "%1") -> String {
        ["\(index)", name, active ? "1" : "0", "\(panes)", paneActive ? "1" : "0",
         state, command, path, id, title].joined(separator: "\t")
    }

    @Test func foldsPanesIntoWindowsInIndexOrder() {
        let out = [
            line(3, "logs", active: false, panes: 1, paneActive: true,
                 state: "", command: "tail", path: "/var/log", title: "host"),
            line(1, "claude", active: true, panes: 2, paneActive: false,
                 state: "working", command: "node", path: "/a", title: "x", id: "%4"),
            line(1, "claude", active: true, panes: 2, paneActive: true,
                 state: "awaiting", command: "claude", path: "/proj", title: "✳ Fix the sidebar", id: "%7"),
        ].joined(separator: "\n")
        let windows = LocalWindowInfo.parsePaneListing(out)
        #expect(windows.map(\.index) == [1, 3])
        #expect(windows[0].status == .awaitingInput)
        #expect(windows[0].awaitingCount == 1)
        // The ACTIVE pane describes the window, not the last one listed.
        #expect(windows[0].activePath == "/proj")
        #expect(windows[0].activeTitle == "✳ Fix the sidebar")
        #expect(windows[1].status == .idle)
        #expect(windows[0].panes.map(\.id) == ["%4", "%7"])
        #expect(windows[0].panes.map(\.status) == [.working, .awaitingInput])
    }

    @Test func aTitleMayHoldTabsAndPipes() {
        let out = line(0, "w", active: true, panes: 1, paneActive: true,
                       state: "done", command: "claude", path: "/p", title: "a | b\tc")
        let w = LocalWindowInfo.parsePaneListing(out)
        #expect(w.first?.activeTitle == "a | b\tc")
        #expect(w.first?.status == .doneUnseen)
    }

    @Test func aBareShellHasNoStatusWhateverTheOptionSays() {
        let out = line(0, "w", active: true, panes: 1, paneActive: true,
                       state: "working", command: "zsh", path: "/p", title: "")
        #expect(LocalWindowInfo.parsePaneListing(out).first?.status == .idle)
    }
}

@Suite("Sidebar: pane names")
struct PaneNameTests {
    @Test func aProgramsTitleWins() {
        #expect(SidebarText.paneName(title: "✳ Fix the sidebar", command: "2.1.322", path: "/Users/me/p",
                                     windowName: "2.1.322", home: "/Users/me", remoteHost: nil)
                == "✳ Fix the sidebar")
    }

    @Test func aWindowTheUserNamedComesNext() {
        #expect(SidebarText.paneName(title: "Mac", command: "zsh", path: "/Users/me/p",
                                     windowName: "api server", home: "/Users/me", remoteHost: nil)
                == "api server")
    }

    @Test func thenWhatRunsThenWhere() {
        #expect(SidebarText.paneName(title: "Mac", command: "make", path: "/src",
                                     windowName: "make", home: "/Users/me", remoteHost: nil) == "make")
        #expect(SidebarText.paneName(title: "Mac", command: "zsh", path: "/Users/me/p",
                                     windowName: "zsh", home: "/Users/me", remoteHost: nil) == "~/p")
    }
}
