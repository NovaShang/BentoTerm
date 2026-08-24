import Foundation
import Testing
@testable import BentoGhosttyKit
import BentoFoundationKit

/// Who gets a tap, and what a link chip says. The order asserted here is the
/// whole fix for "links stopped opening in Claude Code's fullscreen mode": a
/// mouse-reporting pane claims every tap, so detection has to be allowed to
/// take the tap back BEFORE anything is forwarded.
struct TerminalTapRoutingTests {

    // MARK: - Order

    @Test func linkWinsOverForwarding() {
        let route = TerminalTapRouter.route(linkURL: "https://example.com/x",
                                            hasFastPathHit: false)
        #expect(route == .link("https://example.com/x"))
    }

    /// Both detectors hit (they are disjoint in practice, but the order has to
    /// be defined): the link is offered, the tap is not forwarded.
    @Test func linkWinsOverPath() {
        #expect(TerminalTapRouter.route(linkURL: "https://example.com",
                                        hasFastPathHit: true) == .link("https://example.com"))
    }

    @Test func fastPathHitTakesTheTap() {
        #expect(TerminalTapRouter.route(linkURL: nil, hasFastPathHit: true) == .path)
    }

    @Test func nothingDetectedForwards() {
        #expect(TerminalTapRouter.route(linkURL: nil, hasFastPathHit: false) == .forward)
    }

    /// A link the app would refuse to open must not put up a chip that does
    /// nothing when tapped — it counts as a miss and the tap moves on.
    @Test func unopenableSchemeIsNotALink() {
        #expect(TerminalTapRouter.route(linkURL: "file:///etc/passwd",
                                        hasFastPathHit: false) == .forward)
        #expect(TerminalTapRouter.route(linkURL: "javascript:alert(1)",
                                        hasFastPathHit: true) == .path)
    }

    // MARK: - Scheme allowlist

    @Test func openableSchemes() {
        #expect(LinkRouter.canOpen("https://example.com"))
        #expect(LinkRouter.canOpen("http://example.com"))
        #expect(LinkRouter.canOpen("mailto:a@b.com"))
        #expect(LinkRouter.canOpen("ftp://example.com/f"))
        #expect(LinkRouter.canOpen("HTTPS://example.com"))
    }

    @Test func refusedSchemes() {
        #expect(!LinkRouter.canOpen("file:///etc/passwd"))
        #expect(!LinkRouter.canOpen("bento://open"))
        #expect(!LinkRouter.canOpen("example.com"))
        #expect(!LinkRouter.canOpen(""))
    }

    // MARK: - Chip label

    @Test func shortURLIsShownWhole() {
        #expect(LinkChipText.display(for: "https://x.dev/a", maxChars: 34) == "https://x.dev/a")
    }

    @Test func longURLKeepsHostAndTail() {
        let url = "https://console.example.com/orgs/acme/projects/42/settings/tokens"
        let shown = LinkChipText.display(for: url, maxChars: 34)
        #expect(shown.count == 34)
        #expect(shown.hasPrefix("https://console.example.com"))
        #expect(shown.hasSuffix("tokens"))
        #expect(shown.contains("…"))
    }

    /// An OAuth callback — the case this whole path exists for — still shows
    /// which host is about to be opened.
    @Test func oauthURLKeepsItsHost() {
        let url = "https://claude.ai/oauth/authorize?client_id=abc123&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&scope=user"
        let shown = LinkChipText.display(for: url, maxChars: 34)
        #expect(shown.hasPrefix("https://claude.ai…"))
        #expect(shown.count == 34)
    }

    /// A host longer than the whole budget can't keep a tail as well — it is
    /// truncated plainly instead of producing a label that is all ellipsis.
    @Test func hostLongerThanBudgetTruncatesPlainly() {
        let url = "https://a-very-long-hostname-indeed.example.com/p"
        let shown = LinkChipText.display(for: url, maxChars: 20)
        #expect(shown == "https://a-very-long…")
        #expect(shown.count == 20)
    }

    @Test func mailtoKeepsTheScheme() {
        let shown = LinkChipText.display(for: "mailto:someone.with.a.long.name@example.com",
                                         maxChars: 24)
        #expect(shown.hasPrefix("mailto:…"))
        #expect(shown.hasSuffix("@example.com"))
    }
}
