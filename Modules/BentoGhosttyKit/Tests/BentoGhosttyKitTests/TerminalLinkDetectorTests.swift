import XCTest
@testable import BentoGhosttyKit

final class TerminalLinkDetectorTests: XCTestCase {

    func testHitInsideURL() {
        let line = "  visit https://example.com/login now"
        // Columns 8..<34 hold the URL ("  visit " is 8 cols wide).
        XCTAssertEqual(TerminalLinkDetector.urlHit(inLine: line, atCell: 12),
                       "https://example.com/login")
    }

    func testMissBeforeAndAfterURL() {
        let line = "  visit https://example.com/login now"
        XCTAssertNil(TerminalLinkDetector.urlHit(inLine: line, atCell: 3))
        XCTAssertNil(TerminalLinkDetector.urlHit(inLine: line, atCell: 36))
    }

    func testTrailingPunctuationStripped() {
        XCTAssertEqual(TerminalLinkDetector.urlHit(inLine: "see https://example.com/a.", atCell: 10),
                       "https://example.com/a")
    }

    /// The onboarding-critical case: a long OAuth URL soft-wrapped across rows.
    /// The wrap join now happens upstream (`read_text(SCREEN)` returns logical
    /// lines, and `PathHitTester` maps a visual row + column onto one), so what
    /// arrives here is the whole URL with a cell offset past the first row's
    /// width. Tapping any of its rows must still hit.
    func testWrappedURLHitsAtAnyRowOffset() {
        let line = "Open https://auth.example.com/oauth?code=abcdef123456"
        // 5 = width of "Open ". Offsets inside the URL, including ones that
        // would have landed on the 2nd and 3rd visual row of a 20-col pane.
        for cell in [6, 25, 45, 51] {
            XCTAssertEqual(TerminalLinkDetector.urlHit(inLine: line, atCell: cell),
                           "https://auth.example.com/oauth?code=abcdef123456",
                           "cell \(cell) should hit the URL")
        }
        XCTAssertNil(TerminalLinkDetector.urlHit(inLine: line, atCell: 2))
        XCTAssertNil(TerminalLinkDetector.urlHit(inLine: line, atCell: 60))
    }

    /// CJK before the URL shifts its column span by the wide-char widths.
    func testWideCharPrefixOffsets() {
        let line = "访问 https://x.com 继续"  // "访问 " = 2+2+1 = 5 display cols
        XCTAssertNil(TerminalLinkDetector.urlHit(inLine: line, atCell: 2))
        XCTAssertEqual(TerminalLinkDetector.urlHit(inLine: line, atCell: 6), "https://x.com")
    }

    func testDisplayWidth() {
        XCTAssertEqual(TerminalLinkDetector.displayWidth("abc"), 3)
        XCTAssertEqual(TerminalLinkDetector.displayWidth("访问"), 4)
        XCTAssertEqual(TerminalLinkDetector.displayWidth("a访b"), 4)
    }

    func testNoURLNoHit() {
        XCTAssertNil(TerminalLinkDetector.urlHit(inLine: "plain prose only", atCell: 4))
        XCTAssertNil(TerminalLinkDetector.urlHit(inLine: "", atCell: 0))
    }

    // MARK: - Scheme-less hosts

    /// Agents print bare hosts constantly; "github.com/NovaShang/CodingKeyboard"
    /// used to be resolved as a PATH, fuzzy-matched onto a local directory, and
    /// opened in the file viewer.
    func testSchemelessHostBecomesHTTPS() {
        XCTAssertEqual(TerminalLinkDetector.schemelessURL("github.com/NovaShang/CodingKeyboard"),
                       "https://github.com/NovaShang/CodingKeyboard")
        XCTAssertEqual(TerminalLinkDetector.schemelessURL("novashang.github.io"),
                       "https://novashang.github.io")
    }

    /// Real paths and filenames must never be mistaken for hosts — this check
    /// is the entire licence to open a browser instead of a file.
    func testSchemelessRejectsPaths() {
        for token in ["README.md", "docs/privacy-policy.html", "src/main.rs",
                      "/Users/nova/code/x.swift", "~/Desktop/shot.png",
                      "Package.swift", "a.b", "..", "file.txt"] {
            XCTAssertNil(TerminalLinkDetector.schemelessURL(token), "\(token) is not a URL")
        }
    }

    /// Already-schemed tokens are the other detector's job; double-prefixing
    /// would produce "https://https://…".
    func testSchemelessIgnoresSchemedTokens() {
        XCTAssertNil(TerminalLinkDetector.schemelessURL("https://example.com/a"))
    }
}
