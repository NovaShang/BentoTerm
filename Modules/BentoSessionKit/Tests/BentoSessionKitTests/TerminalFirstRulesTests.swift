import XCTest
@testable import BentoSessionKit

/// The two pure rules behind the "a lone pane is a plain terminal" look and
/// the mode-aware ⌘N.
final class SessionChromeTests: XCTestCase {

    func testOnePaneInOneWindowIsSingle() {
        XCTAssertTrue(SessionChrome.isSinglePane(paneCount: 1, windowCount: 1))
        XCTAssertFalse(SessionChrome.showsModeSwitch(paneCount: 1, windowCount: 1))
    }

    /// Before the first `list-panes` lands nothing is listed — that is a new
    /// session, and it must not flash the switch on and off.
    func testNothingListedYetCountsAsSingle() {
        XCTAssertTrue(SessionChrome.isSinglePane(paneCount: 0, windowCount: 0))
    }

    func testASecondPaneBringsTheChromeBack() {
        XCTAssertFalse(SessionChrome.isSinglePane(paneCount: 2, windowCount: 1))
        XCTAssertTrue(SessionChrome.showsModeSwitch(paneCount: 2, windowCount: 1))
    }

    /// Focus: one pane per window, several windows. The window on screen has a
    /// single pane, but the SESSION does not — it keeps its switch.
    func testFocusWithSeveralWindowsIsNotSingle() {
        XCTAssertFalse(SessionChrome.isSinglePane(paneCount: 3, windowCount: 3))
        XCTAssertFalse(SessionChrome.isSinglePane(paneCount: 1, windowCount: 2))
    }
}

final class NewPaneSplitTests: XCTestCase {

    /// A default 80×24 terminal is visibly wider than tall → side by side.
    func testStandardTerminalSplitsSideBySide() {
        XCTAssertTrue(NewPaneSplit.sideBySide(cols: 80, rows: 24))
        XCTAssertTrue(NewPaneSplit.sideBySide(cols: 120, rows: 36))
    }

    /// Half of that is taller than wide on screen → stacked, even though it
    /// still has more columns than rows.
    func testHalfWidthPaneStacks() {
        XCTAssertFalse(NewPaneSplit.sideBySide(cols: 60, rows: 36))
        XCTAssertFalse(NewPaneSplit.sideBySide(cols: 40, rows: 24))
    }

    /// Square on screen (two columns per row) goes side by side.
    func testTieGoesSideBySide() {
        XCTAssertTrue(NewPaneSplit.sideBySide(cols: 48, rows: 24))
        XCTAssertFalse(NewPaneSplit.sideBySide(cols: 47, rows: 24))
    }
}
