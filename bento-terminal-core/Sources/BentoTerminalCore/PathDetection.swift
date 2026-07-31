import Foundation

/// Detects file paths in terminal text and hit-tests them against a tapped /
/// clicked cell, for the tap-to-preview feature.
///
/// Everything here is pure text + integer math — no engine, no transport — so
/// it works identically for local and SSH panes, inside or outside tmux, and
/// is unit-testable without a surface.
///
/// Coordinate model (same as TurnNavigator): `read_text(SCREEN)` returns
/// LOGICAL lines — ghostty joins soft-wrapped rows back into one line — while
/// taps land in VISUAL (wrapped) row space, top-aligned with the SCROLLBAR
/// action's `offset`/`total`. `PathHitTester` bridges the two with the same
/// `ceil(displayCells / cols)` accumulation the turn-scan nav validated on
/// device, then maps the in-row cell column to a character of the logical
/// line using terminal display width (CJK / emoji = 2 cells).
public enum PathDetector {

    /// One recognized path token.
    public struct Candidate: Equatable, Sendable {
        /// The path itself: quotes stripped, trailing punctuation and any
        /// `:line[:col]` suffix removed, `\ ` unescaped. What the fetch layer
        /// resolves against the pane's cwd.
        public let path: String
        /// `:12` / `:12:3` suffix if present (compiler-style references).
        public let line: Int?
        public let column: Int?
        /// True for tokens that are unambiguously path-shaped (`/…`, `~/…`,
        /// `./…`, `../…`, or quoted). False for bare relatives like
        /// `src/main.rs`, which the caller should stat-verify before surfacing
        /// UI (they're also common in non-path text).
        public let explicit: Bool
        /// Range of the visible token within the logical line (trailing junk
        /// trimmed, `:line` suffix kept) — what the UI highlights.
        public let range: Range<String.Index>
    }

    // MARK: - Token scan

    /// CJK / fullwidth PUNCTUATION that ends a path token. Terminal prose
    /// wraps paths in 、。，（）「」etc. with no spaces ("…sample.txt、notes.md）。"),
    /// so these must break the match. Deliberately narrow: CJK *ideographs*
    /// (and even fullwidth alphanumerics / halfwidth kana) stay legal path
    /// characters — `docs/渠道/说明文档.md` is a real path. Ranges: CJK Symbols
    /// and Punctuation (U+3000–303F), the punctuation slices of the
    /// Fullwidth/Halfwidth Forms block (，！？：；（）［］｛｝｜～·… but not
    /// ＡＢＣ１２３ or ｱｲｳ), curly quotes, ellipsis, middle dot.
    private static let cjkPunct =
        #"\x{3000}-\x{303F}"# +                                  // 、。〈〉《》「」【】…
        #"\x{FF01}-\x{FF0F}\x{FF1A}-\x{FF20}\x{FF3B}-\x{FF40}\x{FF5B}-\x{FF65}"# +
        #"\x{2018}-\x{201D}\x{2026}\x{00B7}"#

    /// Pattern priority: when matches overlap, the lowest wins (a quoted path
    /// beats the slashful fragment inside it, etc.).
    private static let patterns: [(explicit: Bool, regex: NSRegularExpression)] = {
        func re(_ p: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p)
        }
        return [
            // "quoted path with spaces" — inner group must contain a slash.
            (true, re(#""([^"\n]{1,512})""#)),
            (true, re(#"'([^'\n]{1,512})'"#)),
            // Absolute / home / dot-relative: `/…`, `~/…`, `./…`, `../…`.
            // Lookbehind rejects mid-token starts ("src/x" → bare pattern) and
            // URL authority slashes ("https://x" — first `/` follows `:`).
            (true, re(#"(?<![\w:/.~-])(?:~|\.{1,2})?/(?:\\ |[^\s"'`"# + cjkPunct + #"])+"#)),
            // Bare relative with at least one internal slash (optionally a
            // compiler-style `:line[:col]` suffix): src/main.rs:42:7. `\w`
            // matches ideographs (CJK file names are real); ASCII brackets are
            // NOT in the segment class — "x.md(注释)" must stop at the paren.
            // (Bracketed FILE names still work via the quoted patterns.)
            // `\.?` up front admits dot-dir relatives (".claude/settings.json")
            // — the lookbehind still rejects mid-token dots ("a.b/c" matches
            // from `a`, and `../x` stays with the explicit pattern above.)
            (false, re(#"(?<![\w./~@-])\.?[\w+@-][\w.+@-]*(?:/[\w.+@#%-]+)+/?(?::\d{1,6}(?::\d{1,6})?)?"#)),
            // Bare filename with an extension: README.md, foo.tar.gz. The
            // extension must contain a letter so versions ("1.2.3") don't match.
            (false, re(#"(?<![\w./~@-])[\w+@-][\w.+@-]*\.[A-Za-z][A-Za-z0-9]{0,7}(?::\d{1,6}(?::\d{1,6})?)?(?![\w./~-])"#)),
            // Dotfile without a slash: .gitignore, .env.local. Non-explicit —
            // like every bare token these are stat-verified before any UI, so
            // prose false positives (".Net") only cost one probe.
            (false, re(#"(?<![\w./~@-])\.[A-Za-z][\w.+-]{0,60}(?::\d{1,6}(?::\d{1,6})?)?(?![\w./~-])"#)),
        ]
    }()

    /// All path candidates in one logical line, best-priority-first per span.
    /// Exposed for tests; hit-testing callers use `candidate(in:atCell:)`.
    static func matches(in line: String) -> [(priority: Int, explicit: Bool, range: Range<String.Index>, quotedInner: Range<String.Index>?)] {
        guard !line.isEmpty else { return [] }
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [(Int, Bool, Range<String.Index>, Range<String.Index>?)] = []
        for (i, entry) in patterns.enumerated() {
            entry.regex.enumerateMatches(in: line, range: full) { m, _, _ in
                guard let m, let r = Range(m.range, in: line) else { return }
                var inner: Range<String.Index>? = nil
                if m.numberOfRanges > 1, let ir = Range(m.range(at: 1), in: line) {
                    // Quoted patterns: the payload is the inner group, and it
                    // only counts as a path when it has a slash.
                    guard line[ir].contains("/") else { return }
                    inner = ir
                }
                out.append((i, entry.explicit, r, inner))
            }
        }
        return out
    }

    /// The candidate whose visible token covers `cell` (0-based display cell
    /// within the logical line), or nil.
    public static func candidate(in line: String, atCell cell: Int) -> Candidate? {
        guard cell >= 0, let idx = index(inLine: line, atCell: cell) else { return nil }
        let hits = matches(in: line)
            .filter { $0.range.contains(idx) }
            .sorted { ($0.priority, $0.range.lowerBound) < ($1.priority, $1.range.lowerBound) }
        guard let best = hits.first else { return nil }
        let tokenRange = best.quotedInner ?? best.range
        // TUI-truncated prefix: "…/App/File.swift" would otherwise read as an
        // absolute path that can never exist. Reclassify as a relative suffix
        // (drop the leading slash) that resolves via tree search.
        let truncated = best.explicit
            && tokenRange.lowerBound > line.startIndex
            && line[tokenRange.lowerBound] == "/"
            && "…⋯".contains(line[line.index(before: tokenRange.lowerBound)])
        guard var cand = clean(line: line, tokenRange: tokenRange, explicit: best.explicit) else {
            return nil
        }
        if truncated, cand.path.hasPrefix("/") {
            let suffix = String(cand.path.dropFirst())
            guard suffix.count > 1 else { return nil }
            cand = Candidate(path: suffix, line: cand.line, column: cand.column,
                             explicit: false, range: cand.range)
        }
        return cand
    }

    /// All absolute / `~` path tokens in one logical line — the raw material
    /// for root hints (a TUI agent's own output betrays the directory it
    /// really works in, even when the pane's shell cwd points elsewhere).
    static func explicitPaths(in line: String) -> [String] {
        matches(in: line).compactMap { m in
            guard m.explicit else { return nil }
            let range = m.quotedInner ?? m.range
            // A slash right after a TUI ellipsis is a truncated fragment,
            // not a real root — same rule as candidate().
            if range.lowerBound > line.startIndex, line[range.lowerBound] == "/",
               "…⋯".contains(line[line.index(before: range.lowerBound)]) {
                return nil
            }
            guard let ct = cleanToken(String(line[range])),
                  ct.path.hasPrefix("/") || ct.path.hasPrefix("~/") else { return nil }
            return ct.path
        }
    }

    /// A raw token after cleanup: junk-trimmed, `:line[:col]` split off.
    struct CleanedToken {
        let path: String
        let line: Int?
        let column: Int?
        /// How many characters of the raw token remain visible (junk stripped
        /// from the end; the `:line[:col]` digits stay visible).
        let keptCount: Int
    }

    /// Trim trailing junk, split off a `:line[:col]` suffix, unescape. Shared
    /// by single-line candidates and joined wrap-chain tokens.
    static func cleanToken(_ raw: String) -> CleanedToken? {
        var token = raw

        // Trailing punctuation that's prose/markup, not path: strip repeatedly,
        // ASCII and the fullwidth/CJK equivalents ("见 x.md。"). Closers only
        // come off while unbalanced against the token body.
        let junk = ".,;:!?'\"、。，；：！？…·’”"
        let closers: [Character: Character] = [
            ")": "(", "]": "[", "}": "{", ">": "<",
            "）": "（", "】": "【", "》": "《", "」": "「",
        ]
        while let last = token.last {
            if junk.contains(last) {
                token.removeLast()
            } else if let opener = closers[last],
                      token.filter({ $0 == opener }).count < token.filter({ $0 == last }).count {
                token.removeLast()
            } else {
                break
            }
        }
        let keptCount = token.count

        // `path:12` / `path:12:34` — compiler-style file references. The digits
        // stay inside the highlight range but come off the fetch path.
        var lineNo: Int?
        var colNo: Int?
        var path = token
        if let m = token.range(of: #":(\d{1,6})(:(\d{1,6}))?$"#, options: .regularExpression) {
            let suffix = token[m].dropFirst().split(separator: ":")
            lineNo = suffix.first.flatMap { Int($0) }
            colNo = suffix.count > 1 ? Int(suffix[1]) : nil
            path = String(token[..<m.lowerBound])
        }

        path = path.replacingOccurrences(of: "\\ ", with: " ")
        // A lone "/" or "~" or "." isn't a useful preview target.
        guard path.count > 1, path != "~/", path != "./", path != "../" else { return nil }
        return CleanedToken(path: path, line: lineNo, column: colNo, keptCount: keptCount)
    }

    private static func clean(line: String, tokenRange: Range<String.Index>,
                              explicit: Bool) -> Candidate? {
        guard let ct = cleanToken(String(line[tokenRange])) else { return nil }
        // The display range starts at the raw match (including an opening
        // quote); highlight from the token start instead.
        let start = tokenRange.lowerBound
        let end = line.index(start, offsetBy: ct.keptCount)
        guard start < end else { return nil }
        return Candidate(path: ct.path, line: ct.line, column: ct.column,
                         explicit: explicit, range: start..<end)
    }

    // MARK: - Cell ↔ index mapping (terminal display width)

    /// Display width of one character (sum of its scalars' cells — the same
    /// accounting `TurnNavigator.displayCells` uses, so hit-testing and wrap
    /// math can never disagree).
    private static func charCells(_ ch: Character) -> Int {
        ch.unicodeScalars.reduce(0) { $0 + TurnNavigator.scalarCells($1.value) }
    }

    /// The character index whose display cell span covers `cell`, or nil when
    /// `cell` is past the end of the line. Walks characters (not scalars) so
    /// the result is always a valid character boundary — regex ranges are
    /// character-aligned.
    public static func index(inLine line: String, atCell cell: Int) -> String.Index? {
        var acc = 0
        var idx = line.startIndex
        while idx < line.endIndex {
            let w = charCells(line[idx])
            if acc + w > cell { return idx }
            acc += w
            idx = line.index(after: idx)
        }
        return nil
    }

    // MARK: - Wrap-chain fragments (TUI hard-wrapped paths)

    /// True when `ch` can be part of a path token — the same set the explicit
    /// regex allows (everything but whitespace, quotes and CJK punctuation).
    static func isPathLegal(_ ch: Character) -> Bool {
        if ch.isWhitespace || "\"'`".contains(ch) { return false }
        return !ch.unicodeScalars.contains { isCJKPunctScalar($0) }
    }

    private static func isCJKPunctScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x303F, 0xFF01...0xFF0F, 0xFF1A...0xFF20,
             0xFF3B...0xFF40, 0xFF5B...0xFF65,
             0x2018...0x201D, 0x2026, 0x00B7, 0x22EF:
            return true
        default:
            return false
        }
    }

    /// Leading chrome a TUI puts before content: whitespace, box drawing,
    /// bullet/marker glyphs (Claude Code's ⏺/⎿, quote bars). Stripped when
    /// deciding where a continuation line's content starts.
    static func isDecoration(_ ch: Character) -> Bool {
        if ch.isWhitespace { return true }
        if let s = ch.unicodeScalars.first, ch.unicodeScalars.count == 1,
           (0x2500...0x257F).contains(s.value) { return true }
        return "⎿⏺●○◐◑•·▪❯›»>|".contains(ch)
    }

    /// First index of real content (after leading decoration).
    static func effectiveStart(of line: String) -> String.Index {
        var i = line.startIndex
        while i < line.endIndex, isDecoration(line[i]) { i = line.index(after: i) }
        return i
    }

    /// Index after the last non-whitespace character.
    static func effectiveEnd(of line: String) -> String.Index {
        var i = line.endIndex
        while i > line.startIndex {
            let prev = line.index(before: i)
            guard line[prev].isWhitespace else { break }
            i = prev
        }
        return i
    }

    /// Maximal run of path-legal characters covering `cell`, or nil.
    static func lexicalRun(in line: String, atCell cell: Int) -> Range<String.Index>? {
        guard cell >= 0, let idx = index(inLine: line, atCell: cell),
              isPathLegal(line[idx]) else { return nil }
        var lo = idx
        while lo > line.startIndex {
            let prev = line.index(before: lo)
            guard isPathLegal(line[prev]) else { break }
            lo = prev
        }
        var hi = line.index(after: idx)
        while hi < line.endIndex, isPathLegal(line[hi]) { hi = line.index(after: hi) }
        return lo..<hi
    }

    /// The continuation fragment a wrapped path would leave at the start of
    /// `line`: the path-legal run at the effective start, or nil.
    static func headToken(of line: String) -> Range<String.Index>? {
        let start = effectiveStart(of: line)
        guard start < line.endIndex, isPathLegal(line[start]) else { return nil }
        var hi = line.index(after: start)
        while hi < line.endIndex, isPathLegal(line[hi]) { hi = line.index(after: hi) }
        return start..<hi
    }

    /// The fragment a wrapped path would leave at the END of `line` (abutting
    /// the effective end). Prefers a regex match ending there — it excludes
    /// leading prose glued to the token ("Read(bento/…") — falling back to the
    /// raw path-legal run.
    static func tailToken(of line: String) -> Range<String.Index>? {
        let ee = effectiveEnd(of: line)
        guard ee > line.startIndex else { return nil }
        // Quoted patterns (priority 0/1) need their closing quote on the same
        // line, so any match abutting the end is a plain token match.
        if let best = matches(in: line)
            .filter({ $0.range.upperBound == ee && $0.quotedInner == nil })
            .min(by: { ($0.priority, $0.range.lowerBound) < ($1.priority, $1.range.lowerBound) }) {
            return best.range
        }
        let last = line.index(before: ee)
        guard isPathLegal(line[last]) else { return nil }
        var lo = last
        while lo > line.startIndex {
            let prev = line.index(before: lo)
            guard isPathLegal(line[prev]) else { break }
            lo = prev
        }
        return lo..<ee
    }

    // MARK: - Space-separated filename joins

    /// A joined candidate for a filename containing unescaped spaces.
    struct SpaceJoin {
        let path: String
        let line: Int?
        let column: Int?
        /// Visible range of the joined token within the logical line.
        let range: Range<String.Index>
    }

    /// Filenames with unescaped spaces ("装饰材料数据标准和要求 V2.0.docx",
    /// "My Report v3.pdf") appear in terminal output as several space-separated
    /// tokens that no single-token pattern can cover. Rebuild the single-space
    /// run group around `anchor` and offer joined candidates, longest first —
    /// aggressively over-generated (prose glues onto names and only the
    /// filesystem can tell), which is safe because every caller stat-verifies.
    ///
    /// Bounds that keep the guesses sane:
    /// - A join must END at a run bearing a file extension — the one reliable
    ///   anchor a spaced name has. Nothing right of that extension joins.
    /// - Runs separated by 2+ spaces stay separate (column layout, not a name).
    /// - A rooted anchor (`/…`, `~…`) never extends LEFT — an absolute path
    ///   starts at its root, so a left neighbor is prose by construction (this
    ///   also preserves the zero-stat fast path for plain absolute tokens).
    /// - Tool-call chrome glues an opener onto the first word
    ///   ("Read(装饰材料… V2.0.docx)") — each start run also offers the
    ///   variant beginning after its last opening bracket.
    static func spaceJoins(in line: String, anchor: Range<String.Index>,
                           maxNeighbors: Int = 3) -> [SpaceJoin] {
        guard anchor.lowerBound < line.endIndex else { return [] }
        // Expand the anchor to its full path-legal run.
        var lo = anchor.lowerBound
        while lo > line.startIndex, isPathLegal(line[line.index(before: lo)]) {
            lo = line.index(before: lo)
        }
        var hi = anchor.upperBound
        while hi < line.endIndex, isPathLegal(line[hi]) { hi = line.index(after: hi) }

        func isDecorationRun(_ r: Range<String.Index>) -> Bool {
            line[r].allSatisfy { isDecoration($0) }
        }
        func runEnding(before start: String.Index) -> Range<String.Index>? {
            guard start > line.startIndex else { return nil }
            let sp = line.index(before: start)
            guard line[sp] == " ", sp > line.startIndex else { return nil }
            let last = line.index(before: sp)
            guard line[last] != " ", isPathLegal(line[last]) else { return nil }
            var s = last
            while s > line.startIndex, isPathLegal(line[line.index(before: s)]) {
                s = line.index(before: s)
            }
            return s..<sp
        }
        func runStarting(after end: String.Index) -> Range<String.Index>? {
            guard end < line.endIndex, line[end] == " " else { return nil }
            let start = line.index(after: end)
            guard start < line.endIndex, line[start] != " ",
                  isPathLegal(line[start]) else { return nil }
            var e = line.index(after: start)
            while e < line.endIndex, isPathLegal(line[e]) { e = line.index(after: e) }
            return start..<e
        }

        var runs: [Range<String.Index>] = [lo..<hi]
        var anchorIdx = 0
        while anchorIdx < maxNeighbors,
              let r = runEnding(before: runs[0].lowerBound), !isDecorationRun(r) {
            runs.insert(r, at: 0)
            anchorIdx += 1
        }
        while runs.count - anchorIdx - 1 < maxNeighbors,
              let r = runStarting(after: runs[runs.count - 1].upperBound),
              !isDecorationRun(r) {
            runs.append(r)
        }
        guard runs.count > 1 else { return [] }

        // The nearest at/after-anchor run ending with an extension anchors the
        // join's end; anything further right belongs to other names.
        func hasExt(_ s: String) -> Bool {
            guard let ct = cleanToken(s) else { return false }
            return ct.path.range(of: #"\.[A-Za-z][A-Za-z0-9]{0,7}$"#,
                                 options: .regularExpression) != nil
        }
        guard let e = (anchorIdx..<runs.count)
            .first(where: { hasExt(String(line[runs[$0]])) }) else { return [] }

        let rooted = "/~".contains(line[runs[anchorIdx].lowerBound])
        let openers: Set<Character> = ["(", "[", "{", "（", "【", "「", "《"]
        var out: [SpaceJoin] = []
        var seen = Set<String>()
        for s in (rooted ? anchorIdx : 0)...anchorIdx {
            var startIndexes = [runs[s].lowerBound]
            if let lastOpen = line[runs[s]].lastIndex(where: { openers.contains($0) }) {
                let after = line.index(after: lastOpen)
                if after < runs[e].upperBound { startIndexes.append(after) }
            }
            for vs in startIndexes {
                let raw = String(line[vs..<runs[e].upperBound])
                guard let ct = cleanToken(raw), ct.path.contains(" "),
                      seen.insert(ct.path).inserted else { continue }
                let end = line.index(vs, offsetBy: ct.keptCount)
                out.append(SpaceJoin(path: ct.path, line: ct.line,
                                     column: ct.column, range: vs..<end))
            }
        }
        return out
    }

    /// The display-cell span `[start, end)` of `range` within `line`.
    public static func cellSpan(inLine line: String, of range: Range<String.Index>) -> (start: Int, end: Int) {
        var acc = 0
        var start = 0
        var idx = line.startIndex
        while idx < range.upperBound, idx < line.endIndex {
            if idx == range.lowerBound { start = acc }
            acc += charCells(line[idx])
            idx = line.index(after: idx)
        }
        return (start, acc)
    }
}

/// Bridges a tap in visual-row space to a `PathDetector` candidate, from one
/// `read_text(SCREEN)` snapshot. Build once per snapshot (the surfaces cache
/// briefly for hover), then hit-test cheaply per event.
public struct PathHitTester {
    public struct Hit: Equatable {
        public let candidate: PathDetector.Candidate
        /// Highlight geometry: one span per visual row the token crosses,
        /// in ABSOLUTE visual-row space (same space as SCROLLBAR offset).
        /// `startCol..<endCol` are display cells.
        public let spans: [Span]
        public struct Span: Equatable {
            public let row: Int
            public let startCol: Int
            public let endCol: Int
        }
    }

    public let cols: Int
    /// Total visual rows of the snapshot — lets callers derive the viewport
    /// top (`total - viewportRows`) when no SCROLLBAR action arrived yet.
    public let totalVisualRows: Int
    private let lines: [String]
    private let starts: [Int]

    public init(screenText: String, cols: Int) {
        self.cols = max(1, cols)
        var lines: [String] = []
        var starts: [Int] = []
        var row = 0
        for piece in screenText.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(piece)
            lines.append(s)
            starts.append(row)
            row += TurnNavigator.visualRows(s, cols: cols)
        }
        self.lines = lines
        self.starts = starts
        self.totalVisualRows = row
    }

    /// Hit-test the display cell at (`absRow`, `col`), both 0-based.
    public func hit(absRow: Int, col: Int) -> Hit? {
        guard absRow >= 0, col >= 0, col < cols, let li = lineIndex(forRow: absRow) else { return nil }
        let line = lines[li]
        let cell = (absRow - starts[li]) * cols + col
        if let cand = PathDetector.candidate(in: line, atCell: cell) {
            return Hit(candidate: cand, spans: rowSpans(lineIdx: li, range: cand.range))
        }
        // The non-extension words of a spaced filename ("装饰材料数据标准和要求
        // V2.0.docx") match no single-token pattern, so hover/right-click would
        // be blind exactly where such a name is widest. Zero-I/O fallback: the
        // shortest space-join starting at the hovered run (non-explicit — every
        // consumer stat-verifies before opening anything).
        guard let run = PathDetector.lexicalRun(in: line, atCell: cell) else { return nil }
        let joins = PathDetector.spaceJoins(in: line, anchor: run)
            .filter { $0.range.lowerBound >= run.lowerBound }
        guard let j = joins.min(by: {
            line.distance(from: $0.range.lowerBound, to: $0.range.upperBound)
                < line.distance(from: $1.range.lowerBound, to: $1.range.upperBound)
        }) else { return nil }
        let cand = PathDetector.Candidate(path: j.path, line: j.line, column: j.column,
                                          explicit: false, range: j.range)
        return Hit(candidate: cand, spans: rowSpans(lineIdx: li, range: j.range))
    }

    /// Visual-row highlight spans of a character range within one logical line.
    private func rowSpans(lineIdx li: Int, range: Range<String.Index>) -> [Hit.Span] {
        let span = PathDetector.cellSpan(inLine: lines[li], of: range)
        var spans: [Hit.Span] = []
        var s = span.start
        while s < span.end {
            let r = s / cols
            let rowEnd = min(span.end, (r + 1) * cols)
            spans.append(Hit.Span(row: starts[li] + r, startCol: s - r * cols, endCol: rowEnd - r * cols))
            s = rowEnd
        }
        return spans
    }

    // MARK: - Tap candidates (wrap-chain aware)

    /// One resolvable path guess for a tap, best-first. Everything except a
    /// self-contained explicit token (`fastPath`) must be verified against the
    /// filesystem before any UI shows — over-generation is safe because the
    /// stat is the oracle.
    public struct TapCandidate: Equatable {
        public let path: String
        public let line: Int?
        public let column: Int?
        /// Self-contained explicit token — UI may show it without a stat.
        public let fastPath: Bool
        public let spans: [Hit.Span]
    }

    /// A line "reaches" the wrap boundary when its content runs to (almost)
    /// the full wrap width — the signature a TUI's own word-wrap leaves. Only
    /// such lines can continue onto the next one.
    private func reachesWrapBoundary(_ line: String) -> Bool {
        let end = PathDetector.effectiveEnd(of: line)
        let cells = PathDetector.cellSpan(inLine: line, of: line.startIndex..<end).end
        return cells >= cols - min(8, max(1, cols / 4))
    }

    /// All path candidates for the tapped cell, best-first: TUIs hard-wrap
    /// long paths across logical lines (real newline + indent), so the tapped
    /// fragment is stitched to abutting fragments on neighboring lines and
    /// the joins offered longest-first. Cost is bounded: callers verify each
    /// candidate in order and stop at the first that exists.
    public func tapCandidates(absRow: Int, col: Int) -> [TapCandidate] {
        guard absRow >= 0, col >= 0, col < cols, let li = lineIndex(forRow: absRow) else { return [] }
        let line = lines[li]
        let cell = (absRow - starts[li]) * cols + col
        for i in max(0, li - 1)...min(lines.count - 1, li + 1) {
            pathPreviewLog.log("tap line[\(i)\(i == li ? "*" : "", privacy: .public)] cols=\(self.cols) ⟨\(self.lines[i], privacy: .public)⟩")
        }
        let sameLine = PathDetector.candidate(in: line, atCell: cell)

        let anchorRange: Range<String.Index>
        if let c = sameLine {
            anchorRange = c.range
        } else if let r = PathDetector.lexicalRun(in: line, atCell: cell) {
            anchorRange = r
        } else {
            return []
        }

        // Reconstruct the wrap chain containing the anchor (≤ 4 lines).
        var pieces: [(li: Int, range: Range<String.Index>)] = [(li, anchorRange)]
        var anchorIdx = 0
        while pieces.count < 4 {
            let head = pieces[0]
            let headLine = lines[head.li]
            guard head.li > 0,
                  head.range.lowerBound == PathDetector.effectiveStart(of: headLine),
                  head.range.lowerBound < headLine.endIndex else { break }
            let prev = lines[head.li - 1]
            guard reachesWrapBoundary(prev),
                  let tail = PathDetector.tailToken(of: prev) else { break }
            // A rooted fragment ("/…", "~…") only continues a previous line
            // when that line's tail itself looks path-ish — otherwise a plain
            // prose word would glue onto a genuine absolute path below it.
            let rooted = "/~".contains(headLine[head.range.lowerBound])
            let tailStr = prev[tail]
            guard !rooted || tailStr.contains("/") || tailStr.contains(".") else { break }
            pieces.insert((head.li - 1, tail), at: 0)
            anchorIdx += 1
        }
        while pieces.count < 4 {
            let last = pieces[pieces.count - 1]
            let lastLine = lines[last.li]
            guard last.range.upperBound == PathDetector.effectiveEnd(of: lastLine),
                  reachesWrapBoundary(lastLine),
                  last.li + 1 < lines.count,
                  let next = PathDetector.headToken(of: lines[last.li + 1]) else { break }
            pieces.append((last.li + 1, next))
        }

        // Candidate order: longest join → partial joins → the anchor alone.
        var out: [TapCandidate] = []
        var seen = Set<String>()
        func appendJoined(_ slice: ArraySlice<(li: Int, range: Range<String.Index>)>) {
            guard slice.count > 1, let first = slice.first else { return }
            let pieces = slice.map { String(lines[$0.li][$0.range]) }
            // A TUI hard-wraps a long path mid-token (join directly), but
            // word-wraps a spaced filename AT its space and EATS the space at
            // the boundary — so also offer the space-restored join. The stat
            // oracle keeps whichever guess is wrong invisible.
            for sep in ["", " "] {
                let joined = pieces.joined(separator: sep)
                guard let ct = PathDetector.cleanToken(joined) else { continue }
                var path = ct.path
                // Same reclassification as the single-line case: a leading slash
                // right after a TUI ellipsis is a truncated prefix, not a root.
                let firstLine = lines[first.li]
                if path.hasPrefix("/"), first.range.lowerBound > firstLine.startIndex,
                   "…⋯".contains(firstLine[firstLine.index(before: first.range.lowerBound)]) {
                    path = String(path.dropFirst())
                }
                guard path.count > 1, path.contains("/") || path.contains("."),
                      !seen.contains(path) else { continue }
                seen.insert(path)
                out.append(TapCandidate(path: path, line: ct.line, column: ct.column,
                                        fastPath: false,
                                        spans: chainSpans(slice, keptCount: ct.keptCount,
                                                          separatorCount: sep.count)))
            }
        }
        if pieces.count > 1 {
            appendJoined(pieces[...])
            if anchorIdx > 0 { appendJoined(pieces[anchorIdx...]) }
            if anchorIdx < pieces.count - 1 { appendJoined(pieces[...anchorIdx]) }
        }
        // Spaced filenames: joins of the single-space run group around the
        // anchor, longest first — before the bare same-line token so the most
        // specific name wins when both would exist. Their presence also demotes
        // the same-line token off the fast path (it must be stat-checked, or a
        // partial name would open a not-found panel while the join resolves).
        let spaceJoins = PathDetector.spaceJoins(in: line, anchor: anchorRange)
        for j in spaceJoins where !seen.contains(j.path) {
            seen.insert(j.path)
            out.append(TapCandidate(path: j.path, line: j.line, column: j.column,
                                    fastPath: false,
                                    spans: rowSpans(lineIdx: li, range: j.range)))
        }
        if let c = sameLine, !seen.contains(c.path) {
            out.append(TapCandidate(path: c.path, line: c.line, column: c.column,
                                    fastPath: c.explicit && pieces.count == 1 && spaceJoins.isEmpty,
                                    spans: rowSpans(lineIdx: li, range: c.range)))
        }
        // Last resort: no pattern matched, but the user deliberately tapped
        // THIS run — a fragment of a real name (the extension half lives on
        // another line, or wrap ate the space). Offer it raw; the resolver's
        // fragment matching against the file index decides. A tap should never
        // be dead when the index knows the file.
        if out.isEmpty, let ct = PathDetector.cleanToken(String(line[anchorRange])),
           ct.path.count >= 2 {
            out.append(TapCandidate(path: ct.path, line: ct.line, column: ct.column,
                                    fastPath: false,
                                    spans: rowSpans(lineIdx: li, range: anchorRange)))
        }
        pathPreviewLog.log("tap chain pieces=\(pieces.count) anchor=\(anchorIdx) candidates=\(out.map { "\($0.path)\($0.fastPath ? "⚡" : "")" }.description, privacy: .public)")
        return out
    }

    /// Candidate roots for relative fragments, gleaned from absolute / `~`
    /// paths visible near the tapped row (nearest first): each such path
    /// contributes its directory and up to two ancestors. When the pane's
    /// shell cwd differs from the directory the agent actually works in —
    /// shell parked in one place, agent editing a project elsewhere — the
    /// agent's own earlier output (tool-call lines with full paths) names the
    /// real root, and the resolver can stat-verify against it.
    public func rootHints(absRow: Int, maxRoots: Int = 6) -> [String] {
        guard let li = lineIndex(forRow: absRow) else { return [] }
        var paths: [String] = []
        var offset = 0
        while paths.count < 4, offset < 120,
              li - offset >= 0 || li + offset < lines.count {
            for idx in Set([li - offset, li + offset])
            where idx >= 0 && idx < lines.count {
                paths.append(contentsOf: PathDetector.explicitPaths(in: lines[idx]))
            }
            offset += 1
        }
        var roots: [String] = []
        var seen = Set<String>()
        for p in paths {
            var dir = (p as NSString).deletingLastPathComponent
            var level = 0
            while level < 3, dir.count > 1, dir != "~", dir != "/" {
                if seen.insert(dir).inserted { roots.append(dir) }
                dir = (dir as NSString).deletingLastPathComponent
                level += 1
            }
            if roots.count >= maxRoots { break }
        }
        return Array(roots.prefix(maxRoots))
    }

    /// Highlight spans of a joined candidate: every piece in full, except the
    /// last which shrinks by whatever `cleanToken` stripped from the end.
    /// `separatorCount` = characters the join inserted between pieces (the
    /// space-restored variant) — phantom characters that exist in the joined
    /// string but not on screen.
    private func chainSpans(_ slice: ArraySlice<(li: Int, range: Range<String.Index>)>,
                            keptCount: Int, separatorCount: Int = 0) -> [Hit.Span] {
        var remaining = keptCount
        var spans: [Hit.Span] = []
        for (i, piece) in slice.enumerated() {
            if i > 0 { remaining -= separatorCount }
            guard remaining > 0 else { break }
            let text = lines[piece.li][piece.range]
            let take = min(text.count, remaining)
            let end = text.index(text.startIndex, offsetBy: take)
            spans += rowSpans(lineIdx: piece.li, range: piece.range.lowerBound..<end)
            remaining -= take
        }
        return spans
    }

    /// The logical line whose wrapped rows contain `row` (greatest start ≤ row).
    private func lineIndex(forRow row: Int) -> Int? {
        guard !starts.isEmpty, row >= 0, row < totalVisualRows else { return nil }
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= row { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
