import Foundation
import Testing
import BentoFilePreviewKit

// MARK: - Matching / ranking

@Suite struct PathSearchEngineTests {
    private let entries: [FileTreeEntry] = [
        .init(relPath: "README.md", isDir: false),
        .init(relPath: "Sources", isDir: true),
        .init(relPath: "Sources/App", isDir: true),
        .init(relPath: "Sources/App/BentoApp.swift", isDir: false),
        .init(relPath: "Sources/Core/PathDetection.swift", isDir: false),
        .init(relPath: "Tests/Core/PathDetection.swift", isDir: false),
        .init(relPath: "docs/readme.md", isDir: false),
        .init(relPath: "a/b/src/main.rs", isDir: false),
        .init(relPath: "src/main.rs", isDir: false),
        .init(relPath: "src", isDir: true),
    ]

    @Test func basenameExact() {
        let m = PathSearchEngine.match(query: "BentoApp.swift", entries: entries)
        #expect(m == ["Sources/App/BentoApp.swift"])
    }

    @Test func basenamePrefersShallowerThenAlpha() {
        let m = PathSearchEngine.match(query: "PathDetection.swift", entries: entries)
        #expect(m == ["Sources/Core/PathDetection.swift", "Tests/Core/PathDetection.swift"])
    }

    @Test func suffixMatchesOnComponentBoundary() {
        let m = PathSearchEngine.match(query: "src/main.rs", entries: entries)
        // Exact relPath ranks before the deeper suffix match.
        #expect(m == ["src/main.rs", "a/b/src/main.rs"])
        // "ain.rs" is not a component — but the fragment pass (wrap/truncation
        // rescue) finds it as a basename suffix of the real files.
        let frag = PathSearchEngine.match(query: "ain.rs", entries: entries)
        #expect(frag.first == "src/main.rs")
    }

    @Test func fragmentPassRescuesWrapDamage() {
        let spaced: [FileTreeEntry] = entries + [
            .init(relPath: "docs/装饰材料数据标准和要求 V2.0.docx", isDir: false),
        ]
        // The extension half of a spaced name (its own token on screen).
        #expect(PathSearchEngine.match(query: "V2.0.docx", entries: spaced).first
                == "docs/装饰材料数据标准和要求 V2.0.docx")
        // Wrap-eaten-space concatenation → space-stripped equality.
        #expect(PathSearchEngine.match(query: "装饰材料数据标准和要求V2.0.docx", entries: spaced).first
                == "docs/装饰材料数据标准和要求 V2.0.docx")
        // The extensionless front half → basename prefix.
        #expect(PathSearchEngine.match(query: "装饰材料数据标准和要求", entries: spaced).first
                == "docs/装饰材料数据标准和要求 V2.0.docx")
        // Garbage still finds nothing.
        #expect(PathSearchEngine.match(query: "不存在的文件", entries: spaced).isEmpty)
    }

    @Test func caseInsensitiveOnlyAsFallback() {
        // Exact case exists → only the exact one.
        #expect(PathSearchEngine.match(query: "README.md", entries: entries) == ["README.md"])
        // No exact-case match → falls back and finds both, shallow first.
        let m = PathSearchEngine.match(query: "Readme.md", entries: entries)
        #expect(m == ["README.md", "docs/readme.md"])
    }

    @Test func bareNamePrefersFilesOverDirs() {
        let m = PathSearchEngine.match(query: "src", entries: entries)
        #expect(m.first == "src")   // only entry named exactly "src" is the dir
        // Trailing slash names a directory explicitly — dir not penalized.
        let d = PathSearchEngine.match(query: "Sources/", entries: entries)
        #expect(d.first == "Sources")
    }

    @Test func dotLeadingQueryNormalized() {
        let m = PathSearchEngine.match(query: "./src/main.rs", entries: entries)
        #expect(m.first == "src/main.rs")
    }

    @Test func rejectsUnsupportedQueries() {
        #expect(PathSearchEngine.match(query: "/abs/path", entries: entries).isEmpty)
        #expect(PathSearchEngine.match(query: "~/x", entries: entries).isEmpty)
        #expect(PathSearchEngine.match(query: "../up/main.rs", entries: entries).isEmpty)
        #expect(PathSearchEngine.match(query: "", entries: entries).isEmpty)
    }
}

// MARK: - Resolver

/// In-memory source: a fixed set of absolute file paths + a listable tree.
final class MockFileSource: FilePreviewSource, @unchecked Sendable {
    let files: Set<String>            // absolute paths of regular files
    let treeRoot: String
    let tree: [FileTreeEntry]
    let listSupported: Bool
    var statCalls = 0
    var listCalls = 0

    init(files: Set<String>, treeRoot: String = "", tree: [FileTreeEntry] = [],
         listSupported: Bool = true) {
        self.files = files
        self.treeRoot = treeRoot
        self.tree = tree
        self.listSupported = listSupported
    }

    func stat(path: String, cwd: String?) async throws -> (resolvedPath: String, stat: FilePreviewStat) {
        statCalls += 1
        let resolved = try FilePathResolver.resolve(path: path, cwd: cwd, home: "/home/u")
        guard files.contains(resolved) else { throw FilePreviewError.notFound(resolved) }
        return (resolved, FilePreviewStat(size: 1, isDirectory: false, isRegular: true, modified: nil))
    }

    func read(resolvedPath: String, maxBytes: Int) async throws -> Data { Data() }

    func listTree(root: String, request: TreeListRequest) async throws -> [FileTreeEntry] {
        listCalls += 1
        guard listSupported else {
            throw FilePreviewError.unavailable("unsupported")
        }
        guard root == treeRoot else { return [] }
        return tree
    }
}

@Suite struct SmartPathResolverTests {
    private func context(_ source: MockFileSource, cwd: String?) -> PathPreviewContext {
        PathPreviewContext(source: source, cwd: { cwd }, hostLabel: "test", isLocal: true)
    }

    @Test func directHitNeedsNoSearch() async throws {
        let src = MockFileSource(files: ["/repo/README.md"])
        let r = try await SmartPathResolver.resolveFirst(paths: ["README.md"],
                                                         context: context(src, cwd: "/repo"))
        #expect(r.resolvedPath == "/repo/README.md")
        #expect(r.index == 0)
        #expect(src.listCalls == 0)
    }

    @Test func bareFilenameFoundViaIndex() async throws {
        let src = MockFileSource(
            files: ["/repo/Sources/App/BentoApp.swift"],
            treeRoot: "/repo",
            tree: [.init(relPath: "Sources", isDir: true),
                   .init(relPath: "Sources/App", isDir: true),
                   .init(relPath: "Sources/App/BentoApp.swift", isDir: false)])
        let r = try await SmartPathResolver.resolveFirst(paths: ["BentoApp.swift"],
                                                         context: context(src, cwd: "/repo"))
        #expect(r.resolvedPath == "/repo/Sources/App/BentoApp.swift")
    }

    @Test func relativeSuffixFoundViaIndex() async throws {
        let src = MockFileSource(
            files: ["/repo/pkg/src/main.rs"],
            treeRoot: "/repo",
            tree: [.init(relPath: "pkg", isDir: true),
                   .init(relPath: "pkg/src", isDir: true),
                   .init(relPath: "pkg/src/main.rs", isDir: false)])
        let r = try await SmartPathResolver.resolveFirst(paths: ["src/main.rs"],
                                                         context: context(src, cwd: "/repo"))
        #expect(r.resolvedPath == "/repo/pkg/src/main.rs")
    }

    @Test func ancestorWalkFindsRepoRootRelative() async throws {
        // cwd is a subdirectory; the agent printed a repo-root-relative path.
        let src = MockFileSource(files: ["/repo/Bento/Sources/App.swift"],
                                 treeRoot: "/repo/desktop/internal", tree: [])
        let r = try await SmartPathResolver.resolveFirst(
            paths: ["Bento/Sources/App.swift"],
            context: context(src, cwd: "/repo/desktop/internal"))
        #expect(r.resolvedPath == "/repo/Bento/Sources/App.swift")
    }

    @Test func candidateOrderWins() async throws {
        // Both the joined candidate and the fragment exist → longest-first.
        let src = MockFileSource(files: ["/repo/a/b/full.txt", "/repo/full.txt"])
        let r = try await SmartPathResolver.resolveFirst(
            paths: ["a/b/full.txt", "full.txt"], context: context(src, cwd: "/repo"))
        #expect(r.index == 0)
        #expect(r.resolvedPath == "/repo/a/b/full.txt")
    }

    @Test func unsupportedListingDegradesGracefully() async throws {
        let src = MockFileSource(files: ["/repo/deep/hidden.txt"],
                                 treeRoot: "/repo", tree: [], listSupported: false)
        await #expect(throws: (any Error).self) {
            _ = try await SmartPathResolver.resolveFirst(paths: ["hidden.txt"],
                                                         context: self.context(src, cwd: "/repo"))
        }
    }

    @Test func rootHintBridgesWrongCwd() async throws {
        // Live-debugged case: shell (and agent) cwd is an EMPTY directory,
        // the agent edits a project elsewhere and prints paths relative to
        // it. An absolute path from its own output names the real root.
        let src = MockFileSource(files: ["/home/u/code/proj/docs/navigation-map.md"],
                                 treeRoot: "/tmp/empty", tree: [])
        let r = try await SmartPathResolver.resolveFirst(
            paths: ["docs/navigation-map.md"],
            rootHints: ["~/code/proj/docs", "~/code/proj", "~/code"],
            context: context(src, cwd: "/tmp/empty"))
        #expect(r.resolvedPath == "/home/u/code/proj/docs/navigation-map.md")
    }

    @Test func rootHintsScannedFromScreenContext() {
        let text = """
        ⏺ Update(~/code/proj/docs/design-spec.md)
          done editing
        ⏺ 导航地图写好了：docs/navigation-map.md（已在 Zed 打开）
        """
        let t = PathHitTester(screenText: text, cols: 120)
        // Tap row = the relative-path line (row 2).
        let hints = t.rootHints(absRow: 2)
        #expect(hints.contains("~/code/proj/docs"))
        #expect(hints.contains("~/code/proj"))
        #expect(!hints.contains("~"))
    }

    @Test func noCwdMeansDirectOnly() async throws {
        let src = MockFileSource(files: ["/abs/file.txt"])
        let r = try await SmartPathResolver.resolveFirst(paths: ["/abs/file.txt"],
                                                         context: context(src, cwd: nil))
        #expect(r.resolvedPath == "/abs/file.txt")
        await #expect(throws: (any Error).self) {
            _ = try await SmartPathResolver.resolveFirst(paths: ["file.txt"],
                                                         context: self.context(src, cwd: nil))
        }
    }

    @Test func localSourceListsBoundedTree() async throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "bento-tree-test-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/a/b", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/node_modules/x", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/dd.noindex/y", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/a/b/deep.txt", contents: Data())
        fm.createFile(atPath: root + "/node_modules/x/skip.js", contents: Data())
        fm.createFile(atPath: root + "/dd.noindex/y/junk.o", contents: Data())
        fm.createFile(atPath: root + "/top.md", contents: Data())

        let entries = try await LocalFileSource().listTree(root: root, request: TreeListRequest())
        let paths = Set(entries.map(\.relPath))
        #expect(paths.contains("a/b/deep.txt"))
        #expect(paths.contains("top.md"))
        #expect(paths.contains("node_modules"))          // listed…
        #expect(!paths.contains("node_modules/x"))       // …but not descended
        #expect(!paths.contains("dd.noindex/y"))         // suffix-skip pruned
    }

    @Test func skipMatcherHandlesSuffixPatterns() {
        let req = TreeListRequest()
        #expect(req.skips(".git"))
        #expect(req.skips("Build"))
        #expect(req.skips("Intermediates.noindex"))
        #expect(req.skips("GhosttyKit.xcframework"))
        #expect(!req.skips("Sources"))
        #expect(!req.skips("builder"))     // "Build" is exact, not a prefix
        #expect(!req.skips("distX"))
    }

    @Test func perDirChildCapLimitsFlatDirs() async throws {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "bento-flat-test-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/flat", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/zz-src", withIntermediateDirectories: true)
        for i in 0..<40 {
            fm.createFile(atPath: root + String(format: "/flat/f%03d.txt", i), contents: Data())
        }
        fm.createFile(atPath: root + "/zz-src/real.swift", contents: Data())

        var req = TreeListRequest()
        req.maxChildrenPerDir = 10
        let entries = try await LocalFileSource().listTree(root: root, request: req)
        let flat = entries.filter { $0.relPath.hasPrefix("flat/") }
        #expect(flat.count == 10)
        // The flat directory didn't starve its siblings.
        #expect(entries.contains { $0.relPath == "zz-src/real.swift" })
    }
}
