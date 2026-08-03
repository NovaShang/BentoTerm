import XCTest
@testable import BentoFilePreviewKit

final class LocalFileSourceListTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bfp-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testListsOneLevelSortedWithSymlinkSafety() async throws {
        let fm = FileManager.default
        let path = tempDir.path
        fm.createFile(atPath: path + "/b.txt", contents: Data())
        fm.createFile(atPath: path + "/a.txt", contents: Data())
        try fm.createDirectory(atPath: path + "/subdir", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: path + "/link",
                                  withDestinationPath: tempDir.appendingPathComponent("subdir").path)
        let source = LocalFileSource()
        let result = try await source.listDirectory(path: path, request: .init())
        XCTAssertEqual(result.entries.map(\.name), ["a.txt", "b.txt", "link", "subdir"])
        // A symlinked directory stays a "file" — walks must never descend into it.
        XCTAssertEqual(result.entries.map(\.isDir), [false, false, false, true])
        XCTAssertFalse(result.truncated)
    }

    /// truncation is strict: exactly maxChildren children is NOT truncated.
    func testTruncatedFlagIsExact() async throws {
        let path = tempDir.path
        for i in 0..<12 {
            FileManager.default.createFile(atPath: path + "/f\(i).txt", contents: Data())
        }
        let source = LocalFileSource()
        let capped = try await source.listDirectory(path: path, request: .init(maxChildren: 10))
        XCTAssertEqual(capped.entries.count, 10)
        XCTAssertTrue(capped.truncated)
        let exact = try await source.listDirectory(path: path, request: .init(maxChildren: 12))
        XCTAssertEqual(exact.entries.count, 12)
        XCTAssertFalse(exact.truncated)
    }

    func testMissingDirectoryThrows() async throws {
        let source = LocalFileSource()
        do {
            _ = try await source.listDirectory(path: tempDir.path + "/nope", request: .init())
            XCTFail("expected throw")
        } catch {}
    }
}
