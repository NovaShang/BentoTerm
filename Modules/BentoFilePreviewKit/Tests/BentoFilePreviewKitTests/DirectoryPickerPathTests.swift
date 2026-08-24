import XCTest
@testable import BentoFilePreviewKit

final class DirectoryPickerPathTests: XCTestCase {

    func testNoLocationCannotConfirmOrMove() {
        var p = DirectoryPickerPath()
        XCTAssertNil(p.selectedPath)
        XCTAssertFalse(p.canConfirm)
        XCTAssertFalse(p.canGoUp)
        XCTAssertTrue(p.breadcrumb.isEmpty)
        // Moves with nowhere to move from are dropped, not remembered as a
        // bare relative path that would later join onto whatever shows up.
        p.enter("src")
        p.up()
        XCTAssertNil(p.selectedPath)
    }

    func testStartsAtTheGivenDirectory() {
        let p = DirectoryPickerPath("/Users/x/repo")
        XCTAssertEqual(p.selectedPath, "/Users/x/repo")
        XCTAssertTrue(p.canConfirm)
        XCTAssertEqual(p.displayName, "repo")
    }

    func testEnterDescendsOneLevel() {
        var p = DirectoryPickerPath("/Users/x/repo")
        p.enter("src")
        p.enter("app")
        XCTAssertEqual(p.selectedPath, "/Users/x/repo/src/app")
    }

    func testUpWalksAboveTheStartingDirectory() {
        // The whole point: the cwd is not a floor.
        var p = DirectoryPickerPath("/Users/x/repo/src/app")
        p.up()
        XCTAssertEqual(p.selectedPath, "/Users/x/repo/src")
        p.up()
        p.up()
        XCTAssertEqual(p.selectedPath, "/Users/x")
    }

    func testFilesystemRootIsAFixedPointGoingUp() {
        var p = DirectoryPickerPath("/etc")
        p.up()
        XCTAssertEqual(p.selectedPath, "/")
        XCTAssertFalse(p.canGoUp)
        p.up()
        XCTAssertEqual(p.selectedPath, "/")   // not "" and not a relative path
        XCTAssertEqual(p.displayName, "/")
    }

    func testJoiningAtTheFilesystemRootNeverDoublesTheSlash() {
        var p = DirectoryPickerPath("/")
        p.enter("etc")
        XCTAssertEqual(p.selectedPath, "/etc")
    }

    func testTrailingSlashesAreTrimmed() {
        var p = DirectoryPickerPath("/Users/x/repo//")
        XCTAssertEqual(p.selectedPath, "/Users/x/repo")
        p.enter("src")
        XCTAssertEqual(p.selectedPath, "/Users/x/repo/src")
    }

    func testBreadcrumbIsTheTrailOfAncestors() {
        let p = DirectoryPickerPath("/Users/x/repo")
        XCTAssertEqual(p.breadcrumb.map(\.label), ["/", "Users", "x", "repo"])
        XCTAssertEqual(p.breadcrumb.map(\.path), ["/", "/Users", "/Users/x", "/Users/x/repo"])
        XCTAssertEqual(DirectoryPickerPath("/").breadcrumb.map(\.path), ["/"])
    }

    func testJumpGoesToAnAncestor() {
        var p = DirectoryPickerPath("/Users/x/repo/src")
        p.jump(to: "/Users/x")
        XCTAssertEqual(p.selectedPath, "/Users/x")
    }

    func testJumpIgnoresAnythingThatIsNotAnAncestor() {
        var p = DirectoryPickerPath("/Users/x/repo")
        p.jump(to: "/Users/x/other")          // a sibling, never in this trail
        XCTAssertEqual(p.selectedPath, "/Users/x/repo")
        p.jump(to: "/Users/x/repo/src")       // a child: only rows descend
        XCTAssertEqual(p.selectedPath, "/Users/x/repo")
        // Prefix-but-not-ancestor: "/Users/xy" must not swallow "/Users/x".
        var q = DirectoryPickerPath("/Users/xylophone")
        q.jump(to: "/Users/x")
        XCTAssertEqual(q.selectedPath, "/Users/xylophone")
    }

    func testResetDropsThePreviousLocation() {
        var p = DirectoryPickerPath("/a/deep/dir")
        p.reset("/b")
        // NOT "/b/deep/dir": that directory was never visited and may not exist.
        XCTAssertEqual(p.selectedPath, "/b")
        p.reset(nil)                          // the pane went away
        XCTAssertNil(p.selectedPath)
        XCTAssertFalse(p.canConfirm)
    }
}
