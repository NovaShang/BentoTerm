import XCTest
@testable import BentoSessionKit

/// Release is the one sizing row the menus show; when it shows and what it
/// says it would undo are decided here, once, for both platforms.
final class TerminalSizingModeTests: XCTestCase {
    private let ipad = TmuxSizingOwner(client: "/dev/ttys003", label: "iPad")

    func testAnotherDeviceOwningTheSizeIsNamed() {
        XCTAssertEqual(TerminalSizingMode.thisDevice.foreignOwner(ipad, ownerIsMe: false), ipad)
        XCTAssertEqual(TerminalSizingMode.thisDevice.releaseNote(owner: ipad, ownerIsMe: false),
                       "Sized by iPad")
    }

    func testOwningItYourself() {
        XCTAssertNil(TerminalSizingMode.thisDevice.foreignOwner(ipad, ownerIsMe: true))
        XCTAssertEqual(TerminalSizingMode.thisDevice.releaseNote(owner: ipad, ownerIsMe: true),
                       "Sized by this device")
    }

    /// The default policy has nothing to release; the other two both do.
    func testReleaseIsOfferedOffTheDefaultOnly() {
        XCTAssertFalse(TerminalSizingMode.tracking.offersRelease)
        XCTAssertNil(TerminalSizingMode.tracking.releaseNote(owner: nil, ownerIsMe: false))
        XCTAssertTrue(TerminalSizingMode.smallest.offersRelease)
        XCTAssertTrue(TerminalSizingMode.thisDevice.offersRelease)
    }

    /// An owner left over from an earlier `.thisDevice` means nothing under
    /// the client-driven modes.
    func testOtherModesHaveNoOwner() {
        for mode in [TerminalSizingMode.tracking, .smallest] {
            XCTAssertNil(mode.foreignOwner(ipad, ownerIsMe: false))
        }
        XCTAssertEqual(TerminalSizingMode.smallest.releaseNote(owner: ipad, ownerIsMe: false),
                       "Sized to the smallest device")
    }
}
