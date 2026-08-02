import XCTest
@testable import BentoGhosttyKit

final class TerminalLinkDetectorTests: XCTestCase {

    func testHitInsideURL() {
        let rows = ["  visit https://example.com/login now"]
        // Columns 8..<34 hold the URL ("  visit " is 8 cols wide).
        XCTAssertEqual(TerminalLinkDetector.urlHit(rows: rows, tapRow: 0, tapCol: 12, columns: 80),
                       "https://example.com/login")
    }

    func testMissBeforeAndAfterURL() {
        let rows = ["  visit https://example.com/login now"]
        XCTAssertNil(TerminalLinkDetector.urlHit(rows: rows, tapRow: 0, tapCol: 3, columns: 80))
        XCTAssertNil(TerminalLinkDetector.urlHit(rows: rows, tapRow: 0, tapCol: 36, columns: 80))
    }

    func testTrailingPunctuationStripped() {
        let rows = ["see https://example.com/a."]
        XCTAssertEqual(TerminalLinkDetector.urlHit(rows: rows, tapRow: 0, tapCol: 10, columns: 80),
                       "https://example.com/a")
    }

    /// The onboarding-critical case: a long OAuth URL soft-wrapped across
    /// rows (each full row runs edge-to-edge). Tapping ANY of its rows must
    /// return the whole reassembled URL.
    func testWrappedURLReassembles() {
        let cols = 20
        let url = "https://auth.example.com/oauth?code=abcdef123456"
        // Break into 20-col visual rows: full rows wrap into the next.
        let rows = ["Open this link:",
                    String(url.prefix(20)),                                   // fills row → wraps
                    String(url.dropFirst(20).prefix(20)),                     // fills row → wraps
                    String(url.dropFirst(40)),                                // tail
                    "then paste the code"]
        for (row, col) in [(1, 5), (2, 10), (3, 2)] {
            XCTAssertEqual(TerminalLinkDetector.urlHit(rows: rows, tapRow: row, tapCol: col, columns: cols),
                           url, "tap at row \(row) col \(col) should hit the reassembled URL")
        }
        XCTAssertNil(TerminalLinkDetector.urlHit(rows: rows, tapRow: 4, tapCol: 5, columns: cols),
                     "the prose row after the URL is not part of it")
    }

    /// CJK before the URL shifts its column span by the wide-char widths.
    func testWideCharPrefixOffsets() {
        let rows = ["访问 https://x.com 继续"]  // "访问 " = 2+2+1 = 5 display cols
        XCTAssertNil(TerminalLinkDetector.urlHit(rows: rows, tapRow: 0, tapCol: 2, columns: 80))
        XCTAssertEqual(TerminalLinkDetector.urlHit(rows: rows, tapRow: 0, tapCol: 6, columns: 80),
                       "https://x.com")
    }

    func testDisplayWidth() {
        XCTAssertEqual(TerminalLinkDetector.displayWidth("abc"), 3)
        XCTAssertEqual(TerminalLinkDetector.displayWidth("访问"), 4)
        XCTAssertEqual(TerminalLinkDetector.displayWidth("a访b"), 4)
    }

    func testNoURLNoHit() {
        XCTAssertNil(TerminalLinkDetector.urlHit(rows: ["plain prose only"], tapRow: 0, tapCol: 4, columns: 80))
        XCTAssertNil(TerminalLinkDetector.urlHit(rows: [], tapRow: 0, tapCol: 0, columns: 80))
    }
}
