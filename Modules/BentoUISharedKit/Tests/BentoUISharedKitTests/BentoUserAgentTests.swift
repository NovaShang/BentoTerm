import Testing
import Foundation
@testable import BentoUISharedKit

/// Why this exists: the browser shipped reporting
///
///     Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)
///
/// — Safari's UA with `Version/…` and `Safari/…` missing. Measured, not
/// guessed: that is what WKWebView actually sends, and `preferredContentMode`
/// does not change it. Sniffers key on exactly those two tokens, so sites fell
/// through to their unknown-browser branch and served the legacy bundle. The
/// engine was current WebKit the whole time; only the label was wrong.
@Suite("Browser user agent")
struct BentoUserAgentTests {

    /// The real default, copied off a live WKWebView on macOS 26 / Safari 27.
    private let macDefault =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"

    /// The one thing that has to be true: a sniffer's regex now matches.
    private func parsedSafariMajor(_ ua: String) -> Int? {
        let re = try! NSRegularExpression(pattern: "Version/(\\d+)[\\d.]*.*Safari")
        guard let m = re.firstMatch(in: ua, range: NSRange(ua.startIndex..., in: ua)),
              let r = Range(m.range(at: 1), in: ua) else { return nil }
        return Int(ua[r])
    }

    @Test func theDefaultIsNotRecognisedAsSafari() {
        #expect(parsedSafariMajor(macDefault) == nil,
                "if this ever passes, WebKit fixed it and we can stop patching")
    }

    #if os(macOS)
    @Test func theAppendedStringIsRecognisedAsSafari() throws {
        let ua = try #require(BentoUserAgent.string(appending: macDefault))
        #expect(ua.hasPrefix(macDefault), "we append; we never rewrite the platform part")
        #expect(ua.contains("Safari/605.1.15"))
        #expect(parsedSafariMajor(ua) != nil)
    }

    /// We claim the Safari that is actually installed. Inventing a version
    /// would make the UA a lie for no gain.
    @Test func theVersionIsTheSafariOnThisMachine() throws {
        let installed = try #require(BentoUserAgent.safariVersion)
        let ua = try #require(BentoUserAgent.string(appending: macDefault))
        #expect(ua.contains("Version/\(installed)"))
    }
    #endif

    /// A future WebKit that ships a complete UA must not get a second
    /// `Safari/` token stapled on.
    @Test func anAlreadyCompleteUserAgentIsLeftAlone() {
        let complete = macDefault + " Version/27.0 Safari/605.1.15"
        #expect(BentoUserAgent.string(appending: complete) == nil)
    }

    /// iOS Safari puts `Version/` BEFORE `Mobile/`, not at the end. Runs on
    /// every platform because the function keys on the string's shape, not on
    /// the compile target — which is what this test forced it to do.
    @Test func iOSKeepsTheMobileTokenInTheRightPlace() {
        let iosDefault = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
                       + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        guard let ua = BentoUserAgent.string(appending: iosDefault) else { return }
        let vIdx = ua.range(of: "Version/")?.lowerBound
        let mIdx = ua.range(of: "Mobile/")?.lowerBound
        #expect(vIdx != nil && mIdx != nil)
        if let vIdx, let mIdx { #expect(vIdx < mIdx, "Version/ must precede Mobile/") }
        #expect(ua.contains("Safari/"))
    }
}
