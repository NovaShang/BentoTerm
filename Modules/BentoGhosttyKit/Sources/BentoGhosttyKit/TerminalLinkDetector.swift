import Foundation
import os

/// Link resolution, both routes: the engine's OSC 8 answer and this file's
/// scrape. Logged on every ⌘click/tap so which route fired is observable —
/// the two disagree exactly when the anchor text isn't the URL.
/// Watch with: log stream --predicate 'category == "Link"'
public let linkLog = Logger(subsystem: "com.novashang.bento", category: "Link")

/// Pure link hit-testing over a terminal line — the FALLBACK route, shared by
/// the iOS tap-to-open and macOS ⌘-click paths.
///
/// The primary route is the engine: ghostty parses OSC 8 and reports the
/// hyperlink under the pointer via `GHOSTTY_ACTION_MOUSE_OVER_LINK`. This file
/// used to carry a comment claiming that action never fires in embedded mode
/// ("verified"); it was wrong, and the cost of believing it was that a link
/// whose anchor text ISN'T a URL — Claude Code emits
/// `ESC]8;;URL ESC\ anchor ESC]8;; ESC\`, anchors often prose in another
/// language — could not be opened at all, because the URL is never rendered
/// and there is nothing on screen to scrape.
///
/// What remains for this scraper is everything that ISN'T an OSC 8 hyperlink:
/// a bare URL printed by `git`, `ls`, a log line, a stack trace.
public enum TerminalLinkDetector {

    /// The URL under `cell` in one LOGICAL line, or nil.
    ///
    /// Callers pass the line the path engine already assembled
    /// (`PathHitTester.logicalLine`), so link and path detection hit-test the
    /// same text — they used to read the screen by different means and disagree
    /// about what was on it. Soft-wrap joining therefore happens upstream, and
    /// `cell` is a COLUMN offset (display width) into the joined line, which is
    /// what the span math below compares.
    public static func urlHit(inLine line: String, atCell cell: Int) -> String? {
        guard let re = try? NSRegularExpression(pattern: schemePattern, options: .caseInsensitive) else { return nil }
        let ns = line as NSString
        for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(m.range, in: line) else { continue }
            let before = displayWidth(String(line[..<range.lowerBound]))
            var url = String(line[range])
            let width = displayWidth(url)
            guard cell >= before, cell < before + width else { continue }
            // Trailing prose punctuation ("visit https://x.com.") isn't part of
            // the URL; closing brackets usually pair with an opener before the
            // scheme, which the char class already excluded.
            while let last = url.last, ".,;:!".contains(last) { url.removeLast() }
            return url
        }
        return nil
    }

    private static let schemePattern = "(https?://|ftp://|mailto:)[^\\s\"'<>]+"

    /// TLDs common enough in terminal output that `host.tld/path` with no
    /// scheme is far more likely a link than a file. Deliberately short: this
    /// list is the entire licence to treat a slash-bearing token as a URL, and
    /// every entry is a chance to mistake a real directory for a host.
    private static let knownTLDs: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "ai", "sh", "co", "me",
        "gov", "edu", "info", "xyz", "cloud", "page", "so",
    ]

    /// `github.com/NovaShang/CodingKeyboard` → `https://github.com/…`, or nil
    /// when the token isn't host-shaped.
    ///
    /// Agents print bare hosts constantly and no terminal user reads them as
    /// paths. This is checked only AFTER path resolution has failed, so a real
    /// file or directory of the same name still wins — the stat oracle keeps
    /// its casting vote, and the browser is what's left when nothing exists.
    public static func schemelessURL(_ token: String) -> String? {
        guard !token.contains("://"), !token.hasPrefix("/"), !token.hasPrefix("~") else { return nil }
        let head = token.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let labels = head.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last,
              knownTLDs.contains(tld.lowercased()),
              labels.allSatisfy({ !$0.isEmpty }),
              head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        else { return nil }
        return "https://" + token
    }

    /// Terminal display width of a string: CJK/full-width scalars occupy two
    /// columns, everything else one. Good enough for URL span math (URLs are
    /// ASCII; only the prefix before them needs the wide-char correction).
    public static func displayWidth(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { acc, u in
            let v = u.value
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v)
                || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
                || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || v >= 0x20000
            return acc + (wide ? 2 : 1)
        }
    }
}
