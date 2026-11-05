import Foundation
import XCTest
@testable import BentoFilePreviewKit

@MainActor
final class FilePreviewLoadModelTests: XCTestCase {
    private func context(_ source: FilePreviewSource) -> PathPreviewContext {
        PathPreviewContext(source: source, cwd: { nil }, hostLabel: "test", isLocal: true)
    }

    /// A model without seed data starts loading on its own and lands on the
    /// source's error — the message is what both platforms show.
    func testFailureLandsAsMessage() async throws {
        let model = FilePreviewLoadModel(path: "/nope", line: nil,
                                         context: context(MockDirectorySource()))
        guard case .loading = model.phase else { return XCTFail("expected loading first") }
        for _ in 0..<200 {
            if case .failed = model.phase { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .failed(let message) = model.phase else { return XCTFail("never failed") }
        XCTAssertFalse(message.isEmpty)
    }
}
