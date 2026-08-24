import Foundation
import BentoFoundationKit

/// Who owns one tap on a terminal surface.
///
/// A pane whose program turned mouse reporting on (any alt-screen TUI —
/// Claude Code's fullscreen mode, htop, less) claims EVERY tap: forward first
/// and Bento's own detectors never run again, so a printed URL or file path
/// becomes untappable for as long as the TUI is up. Detection therefore runs
/// first and swallows the tap when it hits; the program gets everything else.
///
/// The order (link → path → program) is decided here, away from the view
/// controller, so it can be asserted in a test instead of read off a method.
public enum TerminalTapRoute: Equatable {
    /// A URL the app is allowed to open. The host confirms it with a chip —
    /// on a touch screen a mistap must not launch the browser by itself.
    case link(String)
    /// A path candidate the token itself proves (`/…`, `~/…`, `./…`, quoted).
    /// No stat, so it can hold the tap without making the program wait.
    case path
    /// Nobody claimed it — hand it to the program.
    case forward
}

public enum TerminalTapRouter {

    /// Route one tap from what could be decided WITHOUT I/O.
    ///
    /// - Parameters:
    ///   - linkURL: the URL under the tap (engine OSC 8 or scrape), or nil.
    ///   - hasFastPathHit: the best path candidate is self-contained, i.e. the
    ///     chip can be shown without asking the filesystem anything.
    ///
    /// Candidates that need the stat oracle are deliberately NOT an input: a
    /// tap must never wait on a filesystem round-trip to reach the program.
    /// The host resolves those after forwarding and shows the chip late.
    public static func route(linkURL: String?, hasFastPathHit: Bool) -> TerminalTapRoute {
        if let linkURL, LinkRouter.canOpen(linkURL) { return .link(linkURL) }
        if hasFastPathHit { return .path }
        return .forward
    }
}

/// What a link chip shows. A terminal URL is routinely longer than a phone is
/// wide, and the two ends are what identify it — the host says who is being
/// opened, the tail says which page — so the middle is what goes.
public enum LinkChipText {

    /// `url`, elided in the middle to at most `maxChars` characters.
    public static func display(for url: String, maxChars: Int) -> String {
        guard maxChars > 1 else { return String(url.prefix(1)) }
        guard url.count > maxChars else { return url }
        let head = hostPrefix(of: url)
        // Keep the head only while it still leaves room for a useful tail;
        // a URL whose host alone overflows the chip is truncated plainly.
        if head.count + 4 <= maxChars {
            return head + "…" + String(url.suffix(maxChars - head.count - 1))
        }
        return String(url.prefix(maxChars - 1)) + "…"
    }

    /// `https://host` out of `https://host/path?q` — or `mailto:` out of a
    /// mail link, which has no `//` to look for.
    private static func hostPrefix(of url: String) -> String {
        if let sep = url.range(of: "://") {
            let rest = url[sep.upperBound...]
            guard let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
            else { return url }
            return String(url[..<end])
        }
        if let colon = url.firstIndex(of: ":") { return String(url[...colon]) }
        return url
    }
}
