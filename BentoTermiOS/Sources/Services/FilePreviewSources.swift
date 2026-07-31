import Foundation
import BentoTerminalCore
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

    init(client: SSHClient) {
        self.client = client
    }

    private func session() async throws -> SFTPClient {
        if let sftp, sftp.isActive { return sftp }
        let fresh = try await client.openSFTP()
        sftp = fresh
        return fresh
    }

    func stat(path: String, cwd: String?) async throws -> (resolvedPath: String, stat: FilePreviewStat) {
        let sftp = try await session()
        if home == nil {
            // The SFTP session starts in the login home — realpath(".") = home,
            // which unlocks `~/…` resolution.
            home = try? await sftp.getRealPath(atPath: ".")
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

    /// Bounded BFS over SFTP readdir. One round trip per directory, so the
    /// dir/time budgets in `request` are what keep slow links sane; a partial
    /// index is still a useful index.
    func listTree(root: String, request: TreeListRequest) async throws -> [FileTreeEntry] {
        let sftp = try await session()
        var out: [FileTreeEntry] = []
        var queue: [(rel: String, depth: Int)] = [("", 0)]
        var dirsVisited = 0
        let deadline = CFAbsoluteTimeGetCurrent() + request.timeBudget
        while !queue.isEmpty {
            guard dirsVisited < request.maxDirs,
                  CFAbsoluteTimeGetCurrent() < deadline else { break }
            let (rel, depth) = queue.removeFirst()
            dirsVisited += 1
            let dir = rel.isEmpty ? root : root + "/" + rel
            guard let names = try? await sftp.listDirectory(atPath: dir) else { continue }
            let children = names.flatMap(\.components)
                .filter { $0.filename != "." && $0.filename != ".." }
                .sorted { $0.filename < $1.filename }
                .prefix(request.maxChildrenPerDir)
            for comp in children {
                let name = comp.filename
                guard out.count < request.maxEntries else { return out }
                let childRel = rel.isEmpty ? name : rel + "/" + name
                // S_IFMT nibble; symlinked dirs stay files (no loop chasing).
                let isDir = (comp.attributes.permissions ?? 0) & 0o170000 == 0o040000
                out.append(FileTreeEntry(relPath: childRel, isDir: isDir))
                if isDir, depth + 1 < request.maxDepth, !request.skips(name) {
                    queue.append((childRel, depth + 1))
                }
            }
        }
        return out
    }
}
