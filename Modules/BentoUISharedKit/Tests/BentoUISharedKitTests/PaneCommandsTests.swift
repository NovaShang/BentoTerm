import Testing
import BentoSessionKit
@testable import BentoUISharedKit

/// The menus as they shipped before the catalog existed, pinned row for row.
/// The platforms differ on purpose until someone decides they shouldn't; a
/// change here is a product change and should read like one in review.
struct PaneCommandsTests {
    private let parallel = PaneMenuContext(sessionMode: .tiled, paneCount: 2)
    private let focus = PaneMenuContext(sessionMode: .list)

    private func titles(_ rows: [PaneMenuEntry], _ surface: PaneCommand.Surface,
                        zoomed: Bool = false) -> [String] {
        rows.map {
            switch $0 {
            case .command(let c): return c.title(on: surface, zoomed: zoomed)
            case .separator: return "—"
            case .recentAgents: return "[recents]"
            case .layouts: return "[layouts]"
            case .moveToSession: return "[move]"
            case .paste: return "[paste]"
            }
        }
    }

    @Test func macPaneMenuInParallel() {
        #expect(titles(PaneMenuLayout.macPaneMenu(parallel), .macPaneMenu) == [
            "Split Right (-h)", "Split Down (-v)", "—",
            "Split — Duplicate Current", "Split — Path & Command…", "[recents]",
            "—", "[layouts]", "—",
            "Zoom", "—", "Swap Up", "Swap Down", "—", "[move]", "—", "Close Pane",
        ])
    }

    @Test func macPaneMenuInFocusHasNoSplits() {
        #expect(titles(PaneMenuLayout.macPaneMenu(focus), .macPaneMenu, zoomed: true) == [
            "Unzoom", "—", "Swap Up", "Swap Down", "—", "[move]", "—", "Close Pane",
        ])
    }

    @Test func macNewMenuRows() {
        #expect(PaneMenuLayout.macNewMenuSessionRows(hasSession: false).isEmpty)
        let rows = PaneMenuLayout.macNewMenuSessionRows(hasSession: true)
        #expect(titles(rows, .macNewMenu) == [
            "—", "New tmux Window", "Split Pane", "[recents]",
        ])
        let symbols = rows.compactMap { row -> String?? in
            if case .command(let c) = row { return .some(c.symbol(on: .macNewMenu)) }
            return nil
        }
        #expect(symbols == ["macwindow", "square.split.2x1"])
    }

    @Test func macPaletteCommands() {
        #expect(PaneMenuLayout.macPalette.map { $0.title(on: .macPalette) } == [
            "Split Right (-h)", "Split Down (-v)", "Split Pane",
            "Close Pane", "Toggle Zoom", "Select Next Pane", "Select Previous Pane",
            "New tmux Window",
        ])
        #expect(PaneMenuLayout.macPalette.map(\.paletteID) == [
            "splitRight", "splitDown", "duplicate", "closePane", "zoom",
            "nextPane", "prevPane", "newTmuxWindow",
        ])
        #expect(PaneCommand.closePane.symbol(on: .macPalette) == "xmark.square")
    }

    @Test func iosPaneMenuForATmuxPane() {
        let rows = PaneMenuLayout.IOSSection.allCases.flatMap {
            PaneMenuLayout.iosPaneMenu($0, parallel)
        }
        #expect(titles(rows, .iosPaneMenu) == [
            "Find…", "Maximize", "[paste]", "Split Right (-h)", "Split Down (-v)",
            "[move]", "Close Pane",
        ])
        #expect(PaneCommand.closePane.role(on: .iosPaneMenu) == .destructive)
        #expect(PaneCommand.zoom.title(on: .iosPaneMenu, zoomed: true) == "Restore")
    }

    @Test func iosPaneMenuForAPlainShellKeepsFindAndPaste() {
        let plain = PaneMenuContext(isTmuxPane: false, sessionMode: .tiled, inCopyMode: true)
        let rows = PaneMenuLayout.IOSSection.allCases.flatMap {
            PaneMenuLayout.iosPaneMenu($0, plain)
        }
        #expect(titles(rows, .iosPaneMenu) == ["Find…", "[paste]", "Exit tmux copy-mode"])
    }

    @Test func iosOverflowMenu() {
        #expect(PaneMenuLayout.iosOverflowSplit(parallel).map { $0.title(on: .iosOverflowMenu) } == [
            "Split Right (-h)", "Split Down (-v)",
            "Split — Duplicate Current", "Split — Path & Command…",
        ])
        #expect(PaneMenuLayout.iosOverflowSplit(focus).isEmpty)
        #expect(PaneMenuLayout.iosOverflowShowsLayouts(parallel))
        #expect(!PaneMenuLayout.iosOverflowShowsLayouts(
            PaneMenuContext(sessionMode: .tiled, paneCount: 1)))
    }
}
