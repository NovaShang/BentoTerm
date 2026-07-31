import Foundation
import BentoTerminalCore
import Citadel
import NIOCore

// MARK: - Direct SSH (Citadel SFTP)

/// File source for direct-TCP SSH hosts: opens one SFTP subsystem channel on
/// the EXISTING Citadel connection (no re-auth, no second socket) and reuses
/// it across previews. Any standard sshd serves this — plain SSH keeps full
/// features, per the transport-independence rule.
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

// MARK: - Relay (bento-file subsystem on the daemon)

/// File source for relay hosts: one-shot `bento-file` subsystem channels over
/// the SAME SSH-over-WSS session the shell rides — no second socket, no
/// re-pairing. The daemon resolves `~`/relative paths server-side and streams
/// back a JSON header + raw bytes (see desktop/internal/sshserver/filefetch.go).
final class RelayFileSource: FilePreviewSource, @unchecked Sendable {
    private weak var client: BentoRelayClient?

    init(client: BentoRelayClient) {
        self.client = client
    }

    func stat(path: String, cwd: String?) async throws -> (resolvedPath: String, stat: FilePreviewStat) {
        let (header, _) = try await fetch(op: "stat", path: path, cwd: cwd, maxBytes: 0)
        return (header.path, header.previewStat)
    }

    func read(resolvedPath: String, maxBytes: Int) async throws -> Data {
        let (_, data) = try await fetch(op: "read", path: resolvedPath, cwd: nil, maxBytes: maxBytes)
        return data
    }

    /// One `list` round trip; the daemon walks with the bounds we send and
    /// streams back a JSON array (see filefetch.go). Matching stays here.
    func listTree(root: String, request: TreeListRequest) async throws -> [FileTreeEntry] {
        guard let client else {
            throw FilePreviewError.unavailable("Connection is gone.")
        }
        let response = try await client.fetchFile(.init(
            op: "list", path: root, cwd: nil, maxBytes: 0,
            depth: request.maxDepth, maxEntries: request.maxEntries,
            maxChildren: request.maxChildrenPerDir,
            skip: request.skipNames.sorted()))
        guard response.header.ok else {
            throw FilePreviewError.unavailable(response.header.error ?? "list failed")
        }
        guard !response.data.isEmpty else {
            // An old daemon treats the unknown op as a stat: ok header, no
            // payload. A new daemon sends "[]" even for an empty directory.
            throw FilePreviewError.unavailable("File search needs a newer BentoTerm on the host.")
        }
        struct WireEntry: Decodable {
            let p: String
            let d: Bool?
        }
        let rows = try JSONDecoder().decode([WireEntry].self, from: response.data)
        return rows.map { FileTreeEntry(relPath: $0.p, isDir: $0.d ?? false) }
    }

    private func fetch(op: String, path: String, cwd: String?, maxBytes: Int) async throws
        -> (BentoFileHeader, Data) {
        guard let client else {
            throw FilePreviewError.unavailable("Connection is gone.")
        }
        let response = try await client.fetchFile(
            .init(op: op, path: path, cwd: cwd, maxBytes: maxBytes))
        guard response.header.ok else {
            let msg = response.header.error ?? "unknown error"
            if msg.contains("no such file") || msg.contains("not exist") {
                throw FilePreviewError.notFound(path)
            }
            throw FilePreviewError.unavailable(msg)
        }
        return (response.header, response.data)
    }
}

/// Wire types for the daemon's `bento-file` subsystem.
struct BentoFileRequest: Encodable {
    let op: String            // "stat" | "read" | "list"
    let path: String
    let cwd: String?
    let maxBytes: Int
    // list-op bounds (client policy; the daemon enforces mechanically).
    // Optionals stay off the wire for stat/read, so old daemons see the
    // exact request shape they always did.
    var depth: Int? = nil
    var maxEntries: Int? = nil
    var maxChildren: Int? = nil
    var skip: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case op, path, cwd, depth, skip
        case maxBytes = "max_bytes"
        case maxEntries = "max_entries"
        case maxChildren = "max_children"
    }
}

struct BentoFileHeader: Decodable {
    let ok: Bool
    let error: String?
    let path: String
    let size: Int64
    let isDir: Bool
    let isRegular: Bool
    let mtime: Int64
    let dataLen: Int64

    enum CodingKeys: String, CodingKey {
        case ok, error, path, size, mtime
        case isDir = "is_dir"
        case isRegular = "is_regular"
        case dataLen = "data_len"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        size = (try? c.decode(Int64.self, forKey: .size)) ?? 0
        isDir = (try? c.decode(Bool.self, forKey: .isDir)) ?? false
        isRegular = (try? c.decode(Bool.self, forKey: .isRegular)) ?? false
        mtime = (try? c.decode(Int64.self, forKey: .mtime)) ?? 0
        dataLen = (try? c.decode(Int64.self, forKey: .dataLen)) ?? 0
    }

    var previewStat: FilePreviewStat {
        FilePreviewStat(size: size, isDirectory: isDir, isRegular: isRegular,
                        modified: mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil)
    }
}
