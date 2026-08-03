import Foundation
@testable import BentoFilePreviewKit

/// In-memory `FilePreviewSource` for walker/cache tests: canned per-directory
/// listings keyed by absolute path. An actor so `listDirCalls` is race-safe
/// under the walker's parallel waves.
actor MockDirectorySource: FilePreviewSource {
    var dirs: [String: DirectoryListResult]
    var failDirs: Set<String>
    /// Optional: full control over the response per (path, maxChildren) —
    /// used to prove `maxChildren` is part of the cache key.
    var handler: (@Sendable (String, Int) -> DirectoryListResult?)?
    private(set) var listDirCalls = 0

    init(dirs: [String: DirectoryListResult] = [:], failDirs: Set<String> = [],
         handler: (@Sendable (String, Int) -> DirectoryListResult?)? = nil) {
        self.dirs = dirs
        self.failDirs = failDirs
        self.handler = handler
    }

    func stat(path: String, cwd: String?) async throws -> (resolvedPath: String, stat: FilePreviewStat) {
        throw FilePreviewError.unavailable("stat is not used in walker/cache tests")
    }

    func read(resolvedPath: String, maxBytes: Int) async throws -> Data {
        Data()
    }

    func listDirectory(path: String, request: DirectoryListRequest) async throws -> DirectoryListResult {
        listDirCalls += 1
        if failDirs.contains(path) { throw FilePreviewError.unavailable("mock failure: \(path)") }
        if let handler, let r = handler(path, request.maxChildren) { return r }
        guard let r = dirs[path] else { throw FilePreviewError.notFound(path) }
        return r
    }

    /// Stop failing `path` — lets a retry test recover.
    func unfail(_ path: String) {
        failDirs.remove(path)
    }
}

extension DirectoryListResult {
    /// Convenience: a listing from (name, isDir) pairs.
    static func with(_ children: [(name: String, isDir: Bool)]) -> DirectoryListResult {
        DirectoryListResult(entries: children.map { DirectoryEntry(name: $0.name, isDir: $0.isDir) },
                            truncated: false)
    }
}
