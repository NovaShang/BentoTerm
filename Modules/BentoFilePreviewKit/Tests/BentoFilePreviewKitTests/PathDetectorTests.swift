import Foundation
import Testing
import BentoFilePreviewKit

// MARK: - Token detection

@Suite struct PathDetectorTests {
    /// Candidate covering the display cell of `marker`'s first occurrence.
    private func hit(_ line: String, at sub: String) -> PathDetector.Candidate? {
        guard let r = line.range(of: sub) else { return nil }
        let cell = PathDetector.cellSpan(inLine: line, of: r).start
        return PathDetector.candidate(in: line, atCell: cell)
    }

    @Test func absolutePath() throws {
        let c = try #require(hit("error in /usr/local/bin/tool something", at: "/usr/local"))
        #expect(c.path == "/usr/local/bin/tool")
        #expect(c.explicit)
    }

    @Test func homePath() throws {
        let c = try #require(hit("see ~/code/app/main.swift here", at: "~/code"))
        #expect(c.path == "~/code/app/main.swift")
        #expect(c.explicit)
    }

    @Test func dotRelative() throws {
        let c = try #require(hit("run ./scripts/build.sh now", at: "./scripts"))
        #expect(c.path == "./scripts/build.sh")
        let p = try #require(hit("cd ../other/dir", at: "../other"))
        #expect(p.path == "../other/dir")
    }

    @Test func bareRelativeIsImplicit() throws {
        let c = try #require(hit("modified: Sources/Core/File.swift", at: "Core"))
        #expect(c.path == "Sources/Core/File.swift")
        #expect(!c.explicit)
    }

    @Test func bareFilenameWithExtension() throws {
        let c = try #require(hit("wrote README.md and more", at: "README"))
        #expect(c.path == "README.md")
        #expect(!c.explicit)
        let gz = try #require(hit("saved backup.tar.gz ok", at: "backup"))
        #expect(gz.path == "backup.tar.gz")
    }

    @Test func fileLineColumnSuffix() throws {
        let c = try #require(hit("src/main.rs:42:7: error: oops", at: "main.rs"))
        #expect(c.path == "src/main.rs")
        #expect(c.line == 42)
        #expect(c.column == 7)
    }

    @Test func absoluteWithLineSuffix() throws {
        let c = try #require(hit("at /a/b/c.py:120", at: "c.py"))
        #expect(c.path == "/a/b/c.py")
        #expect(c.line == 120)
    }

    @Test func trailingPunctuationStripped() throws {
        let c = try #require(hit("check /etc/hosts, then", at: "/etc"))
        #expect(c.path == "/etc/hosts")
        let p = try #require(hit("(see /var/log/system.log)", at: "/var"))
        #expect(p.path == "/var/log/system.log")
    }

    @Test func balancedParensKept() throws {
        let c = try #require(hit("open /tmp/file (1).txt.bak", at: "/tmp"))
        // Unescaped space ends the token — the "(1)" part is a separate word.
        #expect(c.path == "/tmp/file")
    }

    @Test func escapedSpaces() throws {
        let c = try #require(hit(#"cat /tmp/my\ file.txt done"#, at: "/tmp"))
        #expect(c.path == "/tmp/my file.txt")
    }

    @Test func quotedPathWithSpaces() throws {
        let c = try #require(hit(#"open "/Users/me/My Documents/report.pdf" now"#, at: "My Documents"))
        #expect(c.path == "/Users/me/My Documents/report.pdf")
        #expect(c.explicit)
    }

    @Test func urlsAreNotPaths() {
        let line = "fetch https://example.com/a/b.html done"
        // Clicking inside the URL's path part must not produce a file candidate.
        if let r = line.range(of: "/a/b") {
            let cell = PathDetector.cellSpan(inLine: line, of: r).start
            let c = PathDetector.candidate(in: line, atCell: cell)
            #expect(c == nil || c?.explicit == false)
        }
    }

    @Test func versionsAndPlainWordsRejected() {
        #expect(hit("using v1.2.3 today", at: "1.2") == nil)
        #expect(hit("ratio is 3.14 ok", at: "3.14") == nil)
        #expect(hit("plain words only here", at: "words") == nil)
    }

    @Test func loneSlashRejected() {
        #expect(hit("a / b", at: "/") == nil)
    }

    @Test func tapOutsideTokenMisses() {
        let line = "xx /a/b yy"
        let cell = PathDetector.cellSpan(inLine: line, of: line.range(of: "yy")!).start
        #expect(PathDetector.candidate(in: line, atCell: cell) == nil)
    }

    @Test func cjkWidthMapping() throws {
        // "构建" occupies 4 cells, so the path starts at cell 5.
        let line = "构建 /tmp/out.log 完成"
        let c = try #require(PathDetector.candidate(in: line, atCell: 5))
        #expect(c.path == "/tmp/out.log")
    }
}

// MARK: - CJK punctuation boundaries (user-reported false positives)

@Suite struct PathDetectorCJKBoundaryTests {
    private func hit(_ line: String, at sub: String) -> PathDetector.Candidate? {
        guard let r = line.range(of: sub) else { return nil }
        let cell = PathDetector.cellSpan(inLine: line, of: r).start
        return PathDetector.candidate(in: line, atCell: cell)
    }

    @Test func fullwidthEnumerationComma() throws {
        // Reported: "/tmp/…/sample.txt、notes.md）。" was detected as ONE path.
        let line = "样本在 /tmp/bento-preview-test/sample.txt、notes.md）。"
        let c = try #require(hit(line, at: "/tmp"))
        #expect(c.path == "/tmp/bento-preview-test/sample.txt")
        let n = try #require(hit(line, at: "notes.md"))
        #expect(n.path == "notes.md")
    }

    @Test func cjkParentheticalAfterExtension() throws {
        // Reported: "docs/…-zh.md(和渠道文档放一起)" swallowed the parenthetical.
        let line = "docs/marketing/solar-power-world-article-zh.md(和渠道文档放一起)"
        let c = try #require(hit(line, at: "docs/"))
        #expect(c.path == "docs/marketing/solar-power-world-article-zh.md")
    }

    @Test func fullwidthPunctuationVariants() throws {
        let period = try #require(hit("看 /var/log/x.log。", at: "/var"))
        #expect(period.path == "/var/log/x.log")
        let comma = try #require(hit("文件 /etc/hosts，还有别的", at: "/etc"))
        #expect(comma.path == "/etc/hosts")
        let paren = try #require(hit("（见 ~/notes/todo.md）", at: "~/notes"))
        #expect(paren.path == "~/notes/todo.md")
        let colon = try #require(hit("路径：/opt/app/config.yaml：确认", at: "/opt"))
        #expect(colon.path == "/opt/app/config.yaml")
    }

    @Test func cjkFileNamesStillWork() throws {
        // CJK is fine INSIDE a path — only CJK punctuation ends the token.
        let c = try #require(hit("打开 docs/渠道/说明文档.md 看看", at: "渠道"))
        #expect(c.path == "docs/渠道/说明文档.md")
        let abs = try #require(hit("cat /tmp/中文文件名.txt、其他", at: "/tmp"))
        #expect(abs.path == "/tmp/中文文件名.txt")
    }
}

// MARK: - Dot-leading relatives & TUI-truncated prefixes

@Suite struct PathDetectorDotAndTruncationTests {
    private func hit(_ line: String, at sub: String) -> PathDetector.Candidate? {
        guard let r = line.range(of: sub) else { return nil }
        let cell = PathDetector.cellSpan(inLine: line, of: r).start
        return PathDetector.candidate(in: line, atCell: cell)
    }

    @Test func dotDirRelative() throws {
        let c = try #require(hit("edit .claude/settings.json please", at: "settings"))
        #expect(c.path == ".claude/settings.json")
        #expect(!c.explicit)
    }

    @Test func bareDotfiles() throws {
        let g = try #require(hit("see .gitignore for rules", at: ".gitignore"))
        #expect(g.path == ".gitignore")
        #expect(!g.explicit)
        let e = try #require(hit("loaded .env.local ok", at: ".env"))
        #expect(e.path == ".env.local")
    }

    @Test func dotfileWithLineSuffix() throws {
        let c = try #require(hit("in .zshrc:12 there", at: ".zshrc"))
        #expect(c.path == ".zshrc")
        #expect(c.line == 12)
    }

    @Test func truncatedPrefixBecomesRelativeSuffix() throws {
        // Claude Code shortens long paths to "…/tail" — that's a suffix to
        // search for, not an absolute path.
        let c = try #require(hit("wrote …/Views/Terminal/PathPreviewUI.swift ok", at: "Terminal"))
        #expect(c.path == "Views/Terminal/PathPreviewUI.swift")
        #expect(!c.explicit)
    }

    @Test func genuineAbsoluteUnaffected() throws {
        let c = try #require(hit("wrote /Views/File.swift ok", at: "/Views"))
        #expect(c.path == "/Views/File.swift")
        #expect(c.explicit)
    }

    @Test func versionsStillRejected() {
        #expect(hit("bump to v2.10.4 now", at: "2.10") == nil)
    }
}
