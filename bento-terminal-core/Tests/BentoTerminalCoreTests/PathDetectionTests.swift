import Foundation
import Testing
import BentoFoundationKit
// @testable: the kit exposes PathDetector / PathHitTester as public, but the
// Span memberwise init and PathDetector.spaceJoins are internal.
@testable import BentoFilePreviewKit

// MARK: - Visual-row hit testing

@Suite struct PathHitTesterTests {
    @Test func simpleUnwrapped() throws {
        let text = "first line\nls /var/tmp/thing\nlast"
        let t = PathHitTester(screenText: text, cols: 80)
        #expect(t.totalVisualRows == 3)
        // Row 1, col 3 = inside "/var/tmp/thing".
        let h = try #require(t.hit(absRow: 1, col: 4))
        #expect(h.candidate.path == "/var/tmp/thing")
        #expect(h.spans == [.init(row: 1, startCol: 3, endCol: 17)])
    }

    @Test func wrappedPathSpansRows() throws {
        // cols=10: the 24-cell line wraps to 3 visual rows; the path
        // "/aaaa/bbbb/cc" occupies cells 4..17 → crosses rows 1 and 2.
        let text = "head\nxxx /aaaa/bbbb/cc tail"
        let t = PathHitTester(screenText: text, cols: 10)
        #expect(t.totalVisualRows == 1 + 3)
        // Tap on the SECOND visual row of the wrapped line (absRow 2, col 3 =
        // cell 13 = inside the path).
        let h = try #require(t.hit(absRow: 2, col: 3))
        #expect(h.candidate.path == "/aaaa/bbbb/cc")
        #expect(h.spans == [
            .init(row: 1, startCol: 4, endCol: 10),
            .init(row: 2, startCol: 0, endCol: 7),
        ])
    }

    @Test func missOnBlankRow() {
        let t = PathHitTester(screenText: "a\n\n/x/y\n", cols: 40)
        #expect(t.hit(absRow: 1, col: 0) == nil)
        #expect(t.hit(absRow: 5, col: 0) == nil)   // past the end
        #expect(t.hit(absRow: 2, col: 1) != nil)
    }

    @Test func cjkWrapAccounting() throws {
        // 6 CJK chars = 12 cells → wraps at cols 10 into 2 rows; the following
        // line's rows shift down accordingly.
        let text = "多字符宽度测试\n/etc/fstab"
        let t = PathHitTester(screenText: text, cols: 10)
        #expect(t.totalVisualRows == 3)
        let h = try #require(t.hit(absRow: 2, col: 2))
        #expect(h.candidate.path == "/etc/fstab")
    }
}

// MARK: - Wrap-chain tap candidates (TUI hard-wrapped paths)

@Suite struct TapCandidateChainTests {
    /// tapCandidates at the display cell of `sub`'s first occurrence in the
    /// given LOGICAL line index.
    private func candidates(_ text: String, cols: Int, lineIdx: Int, at sub: String)
        -> [PathHitTester.TapCandidate] {
        let t = PathHitTester(screenText: text, cols: cols)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let line = lines[lineIdx]
        guard let r = line.range(of: sub) else { return [] }
        let cell = PathDetector.cellSpan(inLine: line, of: r).start
        // Convert (lineIdx, cell) → (absRow, col) with the same wrap math.
        var absRow = 0
        for l in lines[0..<lineIdx] { absRow += TerminalGeometry.visualRows(l, cols: cols) }
        return t.tapCandidates(absRow: absRow + cell / cols, col: cell % cols)
    }

    @Test func twoLineWrapJoins() throws {
        // 44 cols: the tool-call line runs to the width and continues.
        let text = "⏺ Read(bento-core/Sources/Core/GhosttyTermi\n"
                 + "  nalSurface.swift)\ndone"
        for (lineIdx, sub) in [(0, "Sources"), (1, "nalSurface")] {
            let c = candidates(text, cols: 44, lineIdx: lineIdx, at: sub)
            #expect(c.first?.path == "bento-core/Sources/Core/GhosttyTerminalSurface.swift",
                    "tap on line \(lineIdx)")
            #expect(c.first?.fastPath == false)
        }
    }

    @Test func threeLineWrapWithMidExtensionBreak() throws {
        // Break lands INSIDE ".swift" — the tail fragment alone matches no
        // regex, only the chain finds it.
        let text = "⏺ Update(bento-core/Sources/Core/PathDetect\n"
                 + "  ion_and_more_padding_to_reach_the_width.sw\n"
                 + "  ift)"
        let c = candidates(text, cols: 44, lineIdx: 2, at: "ift")
        #expect(c.first?.path
                == "bento-core/Sources/Core/PathDetection_and_more_padding_to_reach_the_width.swift")
    }

    @Test func shortLineDoesNotJoin() throws {
        // First line ends well short of the wrap width — no wrap continuation
        // onto the next line. (Same-line space-joins may still guess prose-
        // glued variants; the stat oracle discards those.)
        let text = "saved to src/out.log\nnext.txt is unrelated"
        let c = candidates(text, cols: 60, lineIdx: 0, at: "out.log")
        #expect(c.contains { $0.path == "src/out.log" })
        #expect(!c.contains { $0.path.contains("next.txt") })   // no cross-line glue
    }

    @Test func selfContainedExplicitIsFastPath() throws {
        let text = "cat /etc/hosts\nmore"
        let c = candidates(text, cols: 60, lineIdx: 0, at: "/etc")
        #expect(c.count == 1)
        #expect(c.first?.fastPath == true)
        #expect(c.first?.path == "/etc/hosts")
    }

    @Test func explicitFragmentAtLineStartLosesFastPath() throws {
        // A wrapped path that breaks right before a "/" looks absolute on its
        // own line — the join must come first and nothing is fastPath.
        let line0 = "note bento-core/Sources/BentoTerminalCore"   // 41 chars ≥ 44-8
        let text = line0 + "\n/GhosttySurface.swift here"
        let c = candidates(text, cols: 44, lineIdx: 1, at: "/Ghostty")
        #expect(c.first?.path == "bento-core/Sources/BentoTerminalCore/GhosttySurface.swift")
        #expect(c.allSatisfy { !$0.fastPath })
        // The fragment itself stays available as a fallback candidate.
        #expect(c.contains { $0.path == "/GhosttySurface.swift" })
    }

    @Test func proseTailDoesNotGlueOntoRootedPath() throws {
        // Previous line ends in a plain word (no slash/dot) — an absolute
        // path at the next line's start must NOT join backward onto it.
        let line0 = "The following file was just now written"     // 40 chars, ≥ 36
        let text = line0 + "\n/tmp/out.log written ok"
        let c = candidates(text, cols: 44, lineIdx: 1, at: "/tmp")
        #expect(c.first?.path == "/tmp/out.log")
        #expect(c.count == 1)
    }

    @Test func joinedSpansCoverBothLines() throws {
        // ASCII-only so cell widths are deterministic for the span asserts.
        let text = "x Read(bento-core/Sources/Core/GhosttyTermi\n"
                 + "  nalSurface.swift)"
        let c = candidates(text, cols: 44, lineIdx: 0, at: "Sources")
        let spans = try #require(c.first?.spans)
        let rows = Set(spans.map(\.row))
        #expect(rows == [0, 1])
        // Trailing ")" is stripped from the highlight on the last line.
        let last = try #require(spans.last)
        #expect(last.startCol == 2)
        #expect(last.endCol == 2 + "nalSurface.swift".count)
    }

    @Test func truncatedAndWrappedCombine() throws {
        // "…/long/tail" wrapped across two lines → relative suffix query.
        let line0 = "⎿ wrote …/Sources/Views/Terminal/PathPrevi"  // 43 cells
        let text = line0 + "\n  ewUI.swift"
        let c = candidates(text, cols: 44, lineIdx: 0, at: "Views")
        #expect(c.first?.path == "Sources/Views/Terminal/PathPreviewUI.swift")
    }

    @Test func tapOnProseYieldsOnlyTheRawFragment() {
        // Prose taps now hand the resolver the bare word (last-resort fragment
        // matching against the index) — never a fast path, and the resolver
        // finding no such file means nothing opens.
        let text = "plain words only here\nand here too"
        let c = candidates(text, cols: 44, lineIdx: 0, at: "words")
        #expect(c.map(\.path) == ["words"])
        #expect(!c.contains { $0.fastPath })
    }
}

// MARK: - Spaced filenames (space-join candidates)

@Suite struct SpaceJoinTests {
    private func joins(_ line: String, at sub: String) -> [String] {
        let r = line.range(of: sub)!
        return PathDetector.spaceJoins(in: line, anchor: r).map(\.path)
    }

    @Test func spacedNameFromNonExtensionWord() {
        let paths = joins("已更新 装饰材料数据标准和要求 V2.0.docx。", at: "装饰")
        #expect(paths.contains("装饰材料数据标准和要求 V2.0.docx"))
        // Longest (prose-glued) guess first; the stat oracle discards it.
        #expect(paths.first == "已更新 装饰材料数据标准和要求 V2.0.docx")
    }

    @Test func spacedNameFromExtensionWordExtendsLeft() {
        let paths = joins("已更新 装饰材料数据标准和要求 V2.0.docx", at: "V2.0.docx")
        #expect(paths.contains("装饰材料数据标准和要求 V2.0.docx"))
    }

    @Test func toolCallParenVariant() {
        let paths = joins("⏺ Read(装饰材料数据标准和要求 V2.0.docx)", at: "装饰")
        #expect(paths.contains("装饰材料数据标准和要求 V2.0.docx"))
    }

    @Test func rootedAnchorNeverGluesLeftProse() {
        #expect(joins("删除了 /Users/nova/report.txt", at: "/Users").isEmpty)
    }

    @Test func rootedPathWithSpaceExtendsRight() {
        let paths = joins("见 /Users/nova/我的 文档/说明.docx", at: "/Users")
        #expect(paths == ["/Users/nova/我的 文档/说明.docx"])
    }

    @Test func doubleSpaceIsColumnGapNotName() {
        let paths = joins("结果  报告 V2.0.docx", at: "报告")
        #expect(paths == ["报告 V2.0.docx"])
    }

    @Test func englishSpacedName() {
        let paths = joins("saved My Report v3.pdf just now", at: "Report")
        #expect(paths.contains("My Report v3.pdf"))
        // Nothing right of the extension run joins.
        #expect(!paths.contains { $0.hasSuffix("just") || $0.hasSuffix("now") })
    }

    @Test func tapCandidatesIncludeSpacedJoin() {
        let line = "已更新 装饰材料数据标准和要求 V2.0.docx。"
        let tester = PathHitTester(screenText: line, cols: 200)
        let col = PathDetector.cellSpan(inLine: line, of: line.range(of: "材料")!).start
        let cands = tester.tapCandidates(absRow: 0, col: col)
        #expect(cands.contains { $0.path == "装饰材料数据标准和要求 V2.0.docx" })
        #expect(!cands.contains { $0.fastPath })
    }

    @Test func hoverFallbackCoversSpacedName() {
        let line = "已更新 装饰材料数据标准和要求 V2.0.docx"
        let tester = PathHitTester(screenText: line, cols: 200)
        let col = PathDetector.cellSpan(inLine: line, of: line.range(of: "标准")!).start
        let hit = tester.hit(absRow: 0, col: col)
        #expect(hit?.candidate.path == "装饰材料数据标准和要求 V2.0.docx")
        #expect(hit?.candidate.explicit == false)
    }

    @Test func plainAbsoluteTapKeepsFastPath() {
        let line = "⏺ Read(/Users/nova/code/App.swift)"
        let tester = PathHitTester(screenText: line, cols: 200)
        let col = PathDetector.cellSpan(inLine: line, of: line.range(of: "/Users")!).start
        let cands = tester.tapCandidates(absRow: 0, col: col)
        #expect(cands.first?.fastPath == true)
        #expect(cands.first?.path == "/Users/nova/code/App.swift")
    }

    @Test func wrapAtSpaceOffersSpaceRestoredJoin() {
        // The TUI word-wrapped a spaced filename AT its space (space eaten at
        // the boundary): first logical line ends with the CJK half near the
        // wrap width, next line starts with the extension half.
        // "已更新 装饰材料数据标准和要求" = 31 cells; cols 36 → reaches 36-8=28. ✓
        let text = "已更新 装饰材料数据标准和要求\nV2.0.docx"
        let tester = PathHitTester(screenText: text, cols: 36)
        // Tap the extension half on the second line (visual row 1, col 0).
        let cands = tester.tapCandidates(absRow: 1, col: 0)
        let paths = cands.map(\.path)
        #expect(paths.contains("装饰材料数据标准和要求 V2.0.docx"))   // space restored
        #expect(paths.contains("装饰材料数据标准和要求V2.0.docx"))    // direct join kept
    }

    @Test func tapOnLoneFragmentOffersItRaw() {
        // The front half of a spaced name with no extension anywhere nearby:
        // no pattern matches, but the tap must still hand the resolver the
        // fragment (its index fragment-matching finds the real file).
        let line = "装饰材料数据标准和要求"
        let tester = PathHitTester(screenText: line, cols: 200)
        let cands = tester.tapCandidates(absRow: 0, col: 2)
        #expect(cands.map(\.path) == ["装饰材料数据标准和要求"])
        #expect(cands.first?.fastPath == false)
    }
}
