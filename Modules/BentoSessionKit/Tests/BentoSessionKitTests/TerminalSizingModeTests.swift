import XCTest
@testable import BentoSessionKit

/// Naming the size owner is the whole point on a second device — both menus
/// derive it here rather than each re-checking the three conditions.
final class TerminalSizingModeTests: XCTestCase {
    private let ipad = TmuxSizingOwner(client: "/dev/ttys003", label: "iPad")

    func testAnotherDeviceOwningTheSizeIsNamed() {
        XCTAssertEqual(TerminalSizingMode.thisDevice.foreignOwner(ipad, ownerIsMe: false), ipad)
        XCTAssertEqual(TerminalSizingMode.thisDevice.ownerNote(owner: ipad, ownerIsMe: false),
                       "Sized by iPad. Choose “Size to This Device” to take over.")
    }

    func testOwningItYourselfIsJustTheExplanation() {
        XCTAssertNil(TerminalSizingMode.thisDevice.foreignOwner(ipad, ownerIsMe: true))
        XCTAssertEqual(TerminalSizingMode.thisDevice.ownerNote(owner: ipad, ownerIsMe: true),
                       TerminalSizingMode.thisDevice.explanation)
    }

    /// An owner left over from an earlier `.thisDevice` means nothing under
    /// the client-driven modes.
    func testOtherModesHaveNoOwner() {
        for mode in [TerminalSizingMode.tracking, .smallest] {
            XCTAssertNil(mode.foreignOwner(ipad, ownerIsMe: false))
            XCTAssertEqual(mode.ownerNote(owner: ipad, ownerIsMe: false), mode.explanation)
        }
    }
}
