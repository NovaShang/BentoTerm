import XCTest
@testable import BentoFoundationKit

/// The engine and the iOS chrome both read the font through this mapping, so
/// legacy tokens, real family names and the defaults must each land on one
/// answer.
final class FontFamilyTokenTests: XCTestCase {

    func testLegacyTokensMapToTheirFaces() {
        XCTAssertEqual(ThemeStore.ghosttyFontFamily(forToken: "menlo"), "Menlo")
        XCTAssertEqual(ThemeStore.ghosttyFontFamily(forToken: "courier"), "Courier New")
        XCTAssertEqual(ThemeStore.ghosttyFontFamily(forToken: "jetbrains"), "JetBrains Mono")
        XCTAssertEqual(ThemeStore.ghosttyFontFamily(forToken: "maple-nf-cn"), "Maple Mono NF CN")
    }

    func testDefaultsAreTheEnginesOwnFont() {
        for token in [nil, "", "sf-mono", "system", "system-medium"] {
            XCTAssertNil(ThemeStore.ghosttyFontFamily(forToken: token), "\(token ?? "nil")")
        }
    }

    func testARealFamilyPassesThrough() {
        XCTAssertEqual(ThemeStore.ghosttyFontFamily(forToken: "Iosevka"), "Iosevka")
    }
}
