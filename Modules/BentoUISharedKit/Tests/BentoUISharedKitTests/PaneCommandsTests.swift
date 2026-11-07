import Testing
import BentoSessionKit
@testable import BentoUISharedKit

/// Every surface's rows, pinned row for row. A change here is a product
/// change and should read like one in review.
struct PaneCommandsTests {
    private let parallel = PaneMenuContext(sessionMode: .tiled, paneCount: 2)
    private let focus = PaneMenuContext(sessionMode: .list)

    private func titles(_ rows: [PaneMenuEntry], _ surface: PaneCommand.Surface,
                        zoomed: Bool = false) -> [String] {
        rows.map {
            switch $0 {
            case .command(let c): return c.title(on: surface, zoomed: zoomed)
            case .separator: return "—"
            case .layouts: return "[layouts]"
            case .moveToSession: return "[move]"
            case .paste: return "[paste]"
            }
        }
    }

    @Test func macPaneMenuInParallel() {
        #expect(titles(PaneMenuLayout.macPaneMenu(parallel), .macPaneMenu) == [
            "Split Right (-h)", "Split Down (-v)", "—",
            "Split — Duplicate Current", "Split — Path & Command…",
            "—", "[layouts]", "—",
            "Zoom", "—", "[move]", "—", "Close Pane",
        ])
    }

    @Test func macPaneMenuInFocusHasNoSplits() {
        #expect(titles(PaneMenuLayout.macPaneMenu(focus), .macPaneMenu, zoomed: true) == [
            "Unzoom", "—", "[move]", "—", "Close Pane",
        ])
    }

    @Test func macNewMenuRows() {
        let plain = PaneMenuContext(isTmuxPane: false, sessionMode: .tiled)
        #expect(PaneMenuLayout.macNewMenuSessionRows(plain).isEmpty)
        #expect(titles(PaneMenuLayout.macNewMenuSessionRows(parallel), .macNewMenu) == [
            "New Pane",
        ])
        #expect(titles(PaneMenuLayout.macNewMenuSessionRows(focus), .macNewMenu) == [
            "New tmux Window",
        ])
        #expect(PaneCommand.newPane.symbol(on: .macNewMenu) == "square.split.2x1")
        #expect(PaneCommand.newTmuxWindow.symbol(on: .macNewMenu) == "macwindow")
    }

    @Test func iosPaneMenuForATmuxPane() {
        let rows = PaneMenuLayout.IOSSection.allCases.flatMap {
            PaneMenuLayout.iosPaneMenu($0, parallel)
        }
        #expect(titles(rows, .iosPaneMenu) == [
            "Find…", "Zoom", "[paste]", "Split Right (-h)", "Split Down (-v)",
            "Split — Path & Command…", "[move]", "Close Pane",
        ])
        #expect(PaneCommand.closePane.role(on: .iosPaneMenu) == .destructive)
        #expect(PaneCommand.zoom.title(on: .iosPaneMenu, zoomed: true) == "Unzoom")
    }

    @Test func iosPaneMenuForAPlainShellKeepsFindAndPaste() {
        let plain = PaneMenuContext(isTmuxPane: false, sessionMode: .tiled, inCopyMode: true)
        let rows = PaneMenuLayout.IOSSection.allCases.flatMap {
            PaneMenuLayout.iosPaneMenu($0, plain)
        }
        #expect(titles(rows, .iosPaneMenu) == ["Find…", "[paste]", "Exit tmux copy-mode"])
    }

    @Test func iosOverflowMenuLayouts() {
        #expect(PaneMenuLayout.iosOverflowShowsLayouts(parallel))
        #expect(!PaneMenuLayout.iosOverflowShowsLayouts(
            PaneMenuContext(sessionMode: .tiled, paneCount: 1)))
    }
}
