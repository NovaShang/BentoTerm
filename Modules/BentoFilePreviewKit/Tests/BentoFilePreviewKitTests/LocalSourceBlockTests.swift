import Foundation
import Testing
@testable import BentoFilePreviewKit

/// A Mac tab attached to tmux over ssh shows panes whose cwd is a path on the
/// remote host, while the foreground command is a plain shell. A local file
/// source must refuse there — not resolve the remote path against this Mac.
@Suite("Local source refuses remote panes")
struct LocalSourceBlockTests {

    @Test func aLocalSessionWithAShellIsServed() {
        #expect(PathPreviewContext.localSourceBlock(sessionHost: nil,
                                                    foregroundCommand: "zsh") == nil)
    }

    @Test func aRemoteSessionIsRefusedWhateverThePaneRuns() {
        let reason = PathPreviewContext.localSourceBlock(sessionHost: "devbox",
                                                         foregroundCommand: "zsh")
        #expect(reason?.contains("devbox") == true)
    }

    @Test func anSSHPaneInALocalSessionIsRefused() {
        #expect(PathPreviewContext.localSourceBlock(sessionHost: nil,
                                                    foregroundCommand: "ssh") != nil)
    }

    /// The file exists on THIS machine — exactly the case that used to preview
    /// the wrong file. The refusal has to come before any local read.
    @Test @MainActor func theLoaderRefusesBeforeTouchingTheLocalDisk() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-source-block-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt")
        try Data("this Mac's copy".utf8).write(to: file)

        let reason = PathPreviewContext.localSourceBlock(sessionHost: "devbox",
                                                         foregroundCommand: "zsh")
        let context = PathPreviewContext(
            source: LocalFileSource(), cwd: { dir.path }, hostLabel: "This Mac",
            isLocal: true, remoteBlock: reason.map { r in { @Sendable @MainActor in r } })
        await #expect(throws: FilePreviewError.self) {
            _ = try await FilePreviewLoader.load(path: file.path, line: nil, context: context)
        }
    }
}
