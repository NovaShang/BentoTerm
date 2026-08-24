import XCTest
@testable import BentoFoundationKit

/// Real banners, copied from what these tools actually print.
///
/// The rule under test is deliberately "a loopback URL with an explicit port",
/// not a list of frameworks — so the interesting cases are the ones that prove
/// it generalises (a hand-rolled script) and the ones that prove it does not
/// over-fire (prose that happens to mention localhost).
final class DevServerDetectorTests: XCTestCase {

    private func port(_ text: String) -> Int? {
        DevServerDetector.detect(in: text)?.port
    }

    // MARK: What it must catch

    func testVite() {
        XCTAssertEqual(port("  ➜  Local:   http://localhost:5173/"), 5173)
    }

    func testNext() {
        XCTAssertEqual(port("   - Local:        http://localhost:3000"), 3000)
    }

    func testWebpackDevServer() {
        XCTAssertEqual(port("<i> [webpack-dev-server] Loopback: http://localhost:8080/"), 8080)
    }

    func testRailsAndAnythingElsePrintingAnAddress() {
        XCTAssertEqual(port("* Listening on http://127.0.0.1:3000"), 3000)
        XCTAssertEqual(port("Server started at http://localhost:4321 — press q to quit"), 4321)
    }

    /// A bind address is not a client address. `0.0.0.0` means "every
    /// interface"; nothing connects to it.
    func testBindAddressIsRewrittenToLoopback() {
        let found = DevServerDetector.detect(
            in: "Serving HTTP on 0.0.0.0 port 8000 (http://0.0.0.0:8000/) ...")
        XCTAssertEqual(found?.port, 8000)
        XCTAssertEqual(found?.url.host, "localhost")
    }

    func testIPv6Loopback() {
        XCTAssertEqual(port("listening on http://[::1]:9000/"), 9000)
    }

    /// Terminal output routinely wraps a URL in punctuation. None of it is
    /// part of the address.
    func testTrailingPunctuationIsNotPartOfTheURL() {
        let found = DevServerDetector.detect(in: "open \"http://localhost:5173/app\".")
        XCTAssertEqual(found?.port, 5173)
        XCTAssertEqual(found?.url.absoluteString, "http://localhost:5173/app")
    }

    // MARK: What it must not catch

    /// No port = not a server coming up, just a sentence.
    func testProseWithoutAPortIsIgnored() {
        XCTAssertNil(port("see the docs at http://localhost for details"))
    }

    func testNonLoopbackAddressesAreIgnored() {
        XCTAssertNil(port("deployed to https://example.com:8443/"))
        XCTAssertNil(port("fetching http://192.168.1.20:3000/api"))
    }

    func testPrivilegedPortsAreIgnored() {
        XCTAssertNil(port("proxying http://localhost:80/"))
    }

    func testPlainOutputIsIgnored() {
        XCTAssertNil(port("$ npm run build\n✓ built in 812ms"))
    }

    // MARK: The output-path prefilter

    /// This runs on every chunk the terminal receives, so its job is to say
    /// "no" without allocating. It is allowed to be over-eager; it is not
    /// allowed to miss.
    func testPrefilterRejectsOrdinaryOutputAndKeepsCandidates() {
        XCTAssertFalse(DevServerDetector.mightAnnounce(Array("total 48\ndrwxr-xr-x  12 nova".utf8)))
        XCTAssertFalse(DevServerDetector.mightAnnounce(Array("a:/b".utf8)))
        XCTAssertTrue(DevServerDetector.mightAnnounce(Array("  Local: http://localhost:5173/".utf8)))
        XCTAssertTrue(DevServerDetector.mightAnnounce(Array("https://x".utf8)))
    }

    func testPrefilterNeverMissesWhatTheDetectorWouldFind() {
        for banner in ["  ➜  Local:   http://localhost:5173/",
                       "* Listening on http://127.0.0.1:3000",
                       "listening on http://[::1]:9000/"] {
            XCTAssertNotNil(DevServerDetector.detect(in: banner))
            XCTAssertTrue(DevServerDetector.mightAnnounce(Array(banner.utf8)),
                          "prefilter dropped a real banner: \(banner)")
        }
    }

    // MARK: Offering it once

    /// Agents restart dev servers constantly and every restart reprints the
    /// banner. Offering it again each time would be a popup that never stops.
    func testAPortIsOfferedOncePerPane() {
        var offers = DevServerOffers()
        XCTAssertTrue(offers.shouldOffer(port: 5173, inPane: "a"))
        XCTAssertFalse(offers.shouldOffer(port: 5173, inPane: "a"))
        // A different pane is a different server, even on the same number.
        XCTAssertTrue(offers.shouldOffer(port: 5173, inPane: "b"))
        // A different port in the same pane is a second server (UI + API).
        XCTAssertTrue(offers.shouldOffer(port: 8080, inPane: "a"))
    }

    func testForgettingAPaneLetsItOfferAgain() {
        var offers = DevServerOffers()
        XCTAssertTrue(offers.shouldOffer(port: 3000, inPane: "a"))
        offers.forget(paneID: "a")
        XCTAssertTrue(offers.shouldOffer(port: 3000, inPane: "a"))
    }
}
