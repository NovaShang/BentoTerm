import XCTest
@testable import BentoGhosttyKit

/// The find bars' shared plumbing: navigating must search for what the field
/// says now, not wait out the keystroke debounce.
@MainActor
final class SearchBarModelTests: XCTestCase {

    func testNavigatingFlushesTheTypedNeedleFirst() {
        let model = SearchBarModel()
        var events: [String] = []
        model.onQueryChanged = { events.append("query:\($0)") }
        model.onNext = { events.append("next") }
        model.onPrevious = { events.append("previous") }

        model.queryChanged("foo")
        model.next(currentText: "foo")
        XCTAssertEqual(events, ["query:foo", "next"])

        // Nothing pending: navigation doesn't re-run the search.
        model.previous(currentText: "foo")
        XCTAssertEqual(events, ["query:foo", "next", "previous"])
    }

    func testOnlyASingleLineSelectionSeedsTheField() {
        XCTAssertEqual(SearchBarModel.needle(fromSelection: "error"), "error")
        XCTAssertNil(SearchBarModel.needle(fromSelection: nil))
        XCTAssertNil(SearchBarModel.needle(fromSelection: ""))
        XCTAssertNil(SearchBarModel.needle(fromSelection: "a\nb"))
    }
}
