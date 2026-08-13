import Foundation
import Testing
@testable import BentoFilePreviewKit

/// A file source with known bytes. `servedSize` lets a test make the source
/// lie — the host says the file is N bytes and hands over fewer, which is the
/// exact shape of the silent-truncation bug the share path must never ship.
actor MockByteSource: FilePreviewSource {
    let bytes: Data
    let ranged: Bool
    private(set) var readCalls = 0

    init(bytes: Data, ranged: Bool = true) {
        self.bytes = bytes
        self.ranged = ranged
    }

    nonisolated var supportsRangedRead: Bool { ranged }

    func stat(path: String, cwd: String?) async throws -> (resolvedPath: String, stat: FilePreviewStat) {
        (path, FilePreviewStat(size: Int64(bytes.count), isDirectory: false,
                               isRegular: true, modified: nil))
    }

    func read(resolvedPath: String, maxBytes: Int) async throws -> Data {
        readCalls += 1
        return bytes.prefix(maxBytes)
    }

    func read(resolvedPath: String, offset: UInt64, length: Int) async throws -> Data {
        readCalls += 1
        let start = Int(offset)
        guard start < bytes.count else { return Data() }
        return bytes.subdata(in: start ..< min(bytes.count, start + length))
    }

    func calls() -> Int { readCalls }
}

struct FileFetchTests {

    /// Bigger than one chunk, so the walk actually loops.
    private func payload(_ size: Int) -> Data {
        Data((0 ..< size).map { UInt8($0 % 251) })
    }

    private func request(_ source: FilePreviewSource, size: Int, name: String,
                         path: String = "/tmp/\(UUID().uuidString)") -> FileFetchRequest {
        FileFetchRequest(source: source, resolvedPath: path, fileName: name,
                         size: Int64(size), modified: Date(timeIntervalSince1970: 1_700_000_000),
                         hostLabel: "test@host", isLocal: false)
    }

    @Test("A fetched copy is byte-exact and keeps the file's real name")
    func completeCopy() async throws {
        let bytes = payload(1_300_000)
        let source = MockByteSource(bytes: bytes)
        let url = try await FileFetch.localCopy(of: request(source, size: bytes.count,
                                                            name: "report.pdf"))
        #expect(url.lastPathComponent == "report.pdf")
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("A source that serves less than it promised fails instead of truncating")
    func shortServeNeverLands() async throws {
        let served = payload(40_000)
        let source = MockByteSource(bytes: served)
        let name = "half-\(UUID().uuidString).pdf"
        // The stat claims far more than the source will ever hand over.
        let req = request(source, size: 900_000, name: name)

        await #expect(throws: FileFetchError.self) {
            _ = try await FileFetch.localCopy(of: req)
        }
        // Nothing may sit at the shareable name — a partial file there would
        // be handed to the share sheet on the next attempt as if complete.
        #expect(findInTempTree(named: name) == nil)
    }

    @Test("A source that can't seek is still fetched whole")
    func nonRangedSourceIsComplete() async throws {
        let bytes = payload(700_000)
        let source = MockByteSource(bytes: bytes, ranged: false)
        let url = try await FileFetch.localCopy(of: request(source, size: bytes.count,
                                                            name: "notes.rtf"))
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("Progress ends at the full size")
    func progressReachesTotal() async throws {
        let bytes = payload(1_600_000)
        let source = MockByteSource(bytes: bytes)
        let last = Locked<(Int64, Int64)>((0, 0))
        _ = try await FileFetch.localCopy(of: request(source, size: bytes.count, name: "clip.mp4")) {
            received, total in last.set((received, total))
        }
        #expect(last.get() == (Int64(bytes.count), Int64(bytes.count)))
    }

    @Test("The same file isn't pulled down twice")
    func reusesTheCopy() async throws {
        let bytes = payload(600_000)
        let source = MockByteSource(bytes: bytes)
        let req = request(source, size: bytes.count, name: "deck.key")
        let first = try await FileFetch.localCopy(of: req)
        let callsAfterFirst = await source.calls()
        let second = try await FileFetch.localCopy(of: req)
        #expect(first == second)
        #expect(await source.calls() == callsAfterFirst)
    }

    @Test("A local file is handed over in place, never copied")
    func localFileIsNotCopied() async throws {
        let source = MockByteSource(bytes: Data())
        let req = FileFetchRequest(source: source, resolvedPath: "/etc/hosts",
                                   fileName: "hosts", size: 42, modified: nil,
                                   hostLabel: "This Mac", isLocal: true)
        let url = try await FileFetch.localCopy(of: req)
        #expect(url.path == "/etc/hosts")
        #expect(await source.calls() == 0)
    }

    @Test("Only oversized transfers ask first")
    func confirmationGate() {
        let source = MockByteSource(bytes: Data())
        let small = request(source, size: 1_000_000, name: "a.pdf")
        let big = request(source, size: Int(FileFetchLimits.confirmAbove) + 1, name: "b.pdf")
        #expect(small.needsConfirmation == false)
        #expect(big.needsConfirmation == true)
    }

    /// Depth-first hunt for a name anywhere under the fetch cache root.
    private func findInTempTree(named name: String) -> URL? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BentoFileFetch", isDirectory: true)
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return nil }
        for case let entry as String in walker where (entry as NSString).lastPathComponent == name {
            return root.appendingPathComponent(entry)
        }
        return nil
    }
}

/// Minimal box so a `@Sendable` progress callback can report back.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}
