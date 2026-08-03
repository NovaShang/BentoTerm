import Foundation
import BentoSessionKit
import BentoFoundationKit
import BentoFilePreviewKit
import Citadel
import NIOCore

// MARK: - SSH (Citadel SFTP)

/// File source for SSH hosts: opens one SFTP subsystem channel on the
/// EXISTING Citadel connection (no re-auth, no second socket) and reuses it
/// across previews. Any standard sshd serves this, which is the whole point —
/// preview and file search need nothing installed on the host.
actor CitadelSFTPFileSource: FilePreviewSource {
    /// Citadel's SSHClient predates Sendable; it's the same instance
    /// SSHService already drives from multiple tasks, and openSFTP() is
    /// internally thread-safe (NIO event loop), so region-checking is noise.
    private nonisolated(unsafe) let client: SSHClient
    private var sftp: SFTPClient?
    private var home: String?
    /// In-flight openSFTP() — the search walker now lists directories in
    /// parallel waves, so several calls can race the very first session: two
    /// openSFTP() calls would open two channels. Dedup them.
    private var sessionTask: Task<SFTPClient, Error>?
    private var homeTask: Task<String?, Never>?

    init(client: SSHClient) {
        self.client = client
    }

    private func session() async throws -> SFTPClient {
        if let sftp, sftp.isActive { return sftp }
        if let sessionTask { return try await sessionTask.value }
        let task = Task { try await client.openSFTP() }
        sessionTask = task
        defer { sessionTask = nil }
        let fresh = try await task.value
        sftp = fresh
        return fresh
    }

    private func homePath(sftp: SFTPClient) async -> String? {
        if let homeTask { return await homeTask.value }
        // The SFTP session starts in the login home — realpath(".") = home,
        // which unlocks `~/…` resolution.
        let task = Task { try? await sftp.getRealPath(atPath: ".") }
        homeTask = task
        defer { homeTask = nil }
        return await task.value
    }

    func stat(path: String, cwd: String?) async throws -> (resolvedPath: String, stat: FilePreviewStat) {
        let sftp = try await session()
        if home == nil {
            home = await homePath(sftp: sftp)
        }
        var resolved = try FilePathResolver.resolve(path: path, cwd: cwd, home: home)
        if !resolved.hasPrefix("/") {
            resolved = try await sftp.getRealPath(atPath: resolved)   // "~user/…" etc.
        }
        do {
            let attrs = try await sftp.getAttributes(at: resolved)
            let type = (attrs.permissions ?? 0o100000) & 0o170000
            return (resolved, FilePreviewStat(
                size: Int64(attrs.size ?? 0),
                isDirectory: type == 0o040000,
                isRegular: type == 0o100000,
                modified: attrs.accessModificationTime?.modificationTime))
        } catch {
            throw FilePreviewError.notFound(resolved)
        }
    }

    func read(resolvedPath: String, maxBytes: Int) async throws -> Data {
        let sftp = try await session()
        let length = UInt32(clamping: maxBytes)
        return try await sftp.withFile(filePath: resolvedPath, flags: .read) { file in
            var buf = try await file.read(from: 0, length: length)
            return buf.readData(length: buf.readableBytes) ?? Data()
        }
    }

    /// One directory's immediate children over SFTP — one round trip. The
    /// old bounded whole-tree BFS moved to `TreeWalker` (shared kit code);
    /// this source is now just the dumb per-directory pipe.
    func listDirectory(path: String, request: DirectoryListRequest) async throws -> DirectoryListResult {
        let sftp = try await session()
        guard let all = try? await sftp.listDirectory(atPath: path) else {
            throw FilePreviewError.notFound(path)
        }
        let children = all.flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .sorted { $0.filename < $1.filename }
        // truncation computed BEFORE prefixing (exactly-maxChildren is not truncation)
        let truncated = children.count > request.maxChildren
        let out = children.prefix(request.maxChildren).map { comp in
            // S_IFMT nibble; symlinked dirs stay files (no loop chasing).
            let isDir = (comp.attributes.permissions ?? 0) & 0o170000 == 0o040000
            return DirectoryEntry(name: comp.filename, isDir: isDir)
        }
        return DirectoryListResult(entries: out, truncated: truncated)
    }
}
