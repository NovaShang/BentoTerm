import Foundation

/// Pure link hit-testing over rendered terminal rows — shared by the iOS
/// tap-to-open and macOS ⌘-click paths. Exists because the prebuilt
/// libghostty's own link pipeline (hover → MOUSE_OVER_LINK → click-activate)
/// is inert in embedded mode, so the apps read the visual rows around the
/// pointer themselves (via transient selections) and hit-test here.
public enum TerminalLinkDetector {

    /// Given consecutive VISUAL rows, the pointer's (row, col) within them and
    /// the grid width, return the URL under the pointer or nil. Rows whose
    /// glyphs fill every column are joined with their successor (soft-wrap
    /// heuristic) before matching, so a long OAuth URL wrapped across rows
    /// resolves whole.
    public static func urlHit(rows: [String], tapRow: Int, tapCol: Int, columns: Int) -> String? {
        guard tapRow >= 0, tapRow < rows.count, columns > 0 else { return nil }
        // Bounds of the wrap-chain containing the tapped row.
        var start = tapRow
        while start > 0, displayWidth(rows[start - 1]) >= columns { start -= 1 }
        var end = tapRow
        while end + 1 < rows.count, displayWidth(rows[end]) >= columns { end += 1 }

        var merged = ""
        var tapOffset = tapCol
        for (i, row) in rows[start...end].enumerated() {
            if start + i < tapRow { tapOffset += displayWidth(row) }
            merged += row
        }

        let pattern = "(https?://|ftp://|mailto:)[^\\s\"'<>]+"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = merged as NSString
        for m in re.matches(in: merged, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(m.range, in: merged) else { continue }
            let before = displayWidth(String(merged[..<range.lowerBound]))
            var url = String(merged[range])
            let width = displayWidth(url)
            guard tapOffset >= before, tapOffset < before + width else { continue }
            // Trailing prose punctuation ("visit https://x.com.") isn't part
            // of the URL; closing brackets usually pair with an opener before
            // the scheme, which the char class already excluded.
            while let last = url.last, ".,;:!".contains(last) { url.removeLast() }
            return url
        }
        return nil
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
