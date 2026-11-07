import XCTest
@testable import BentoSessionKit

/// Every window surface (sidebar row, iPhone tab, Mac strip) renders a window's
/// status through the pane chrome table, so the mapping must be one-to-one —
/// the iPhone tab used to drop "done, unseen" on the floor.
final class WindowDisplayStatusTests: XCTestCase {

    func testEachWindowStatusMapsOntoItsPaneChromeStatus() {
        XCTAssertEqual(WindowDisplayStatus.working.chrome, .working)
        XCTAssertEqual(WindowDisplayStatus.awaiting.chrome, .awaitingInput)
        XCTAssertEqual(WindowDisplayStatus.doneUnseen.chrome, .doneUnseen)
        XCTAssertEqual(WindowDisplayStatus.idle.chrome, .idle)
    }

    func testDoneUnseenCarriesTheGreenCheck() {
        let chrome = WindowDisplayStatus.doneUnseen.chrome
        XCTAssertEqual(chrome.symbol, "checkmark.circle.fill")
        XCTAssertEqual(chrome.accentHex, PaneState.doneUnseenHex)
    }
}
