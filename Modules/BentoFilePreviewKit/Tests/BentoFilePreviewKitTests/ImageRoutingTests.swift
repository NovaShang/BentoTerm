import Foundation
import Testing
@testable import BentoFilePreviewKit

/// Where a picture goes now that the app has no image view of its own.
///
/// The app used to decode PNG/JPEG/GIF itself and draw them; that path is gone,
/// so every picture has to reach Quick Look — including the two the type system
/// gets wrong on its own.
@Suite struct ImageRoutingTests {

    /// A source that serves the bytes it was handed, for the extensionless case.
    private final class BytesSource: FilePreviewSource, @unchecked Sendable {
        let bytes: Data
        let path: String
        init(bytes: Data, path: String) {
            self.bytes = bytes
            self.path = path
        }
        func stat(path: String, cwd: String?) async throws
            -> (resolvedPath: String, stat: FilePreviewStat) {
            (self.path, FilePreviewStat(size: Int64(bytes.count), isDirectory: false,
                                        isRegular: true, modified: nil))
        }
        func read(resolvedPath: String, maxBytes: Int) async throws -> Data {
            bytes.prefix(maxBytes)
        }
    }

    private func context(_ source: FilePreviewSource, isLocal: Bool) -> PathPreviewContext {
        PathPreviewContext(source: source, cwd: { nil }, hostLabel: "test", isLocal: isLocal)
    }

    private func isQuickLook(_ content: FilePreviewContent) -> Bool {
        if case .quickLook = content { return true }
        return false
    }

    @Test("Ordinary pictures reach the system renderer by extension")
    func picturesRouteToQuickLook() {
        for name in ["shot.png", "photo.jpg", "photo.jpeg", "loop.gif", "icon.webp",
                     "scan.tiff", "favicon.ico", "live.heic", "frame.avif", "old.bmp"] {
            #expect(FilePreviewImageMIME.table[(name as NSString).pathExtension] != nil,
                    "\(name) must be recognised as a picture")
        }
    }

    @Test("SVG is a picture, not markup to read")
    func svgIsNotTreatedAsXML() {
        // `.svg` conforms to public.xml, so type-based routing alone sends it to
        // the CODE renderer and you get the source of a drawing instead of the
        // drawing. The loader consults the image table first for exactly this.
        #expect(FilePreviewImageMIME.table["svg"] != nil)
    }

    @Test("A picture with no extension still avoids the text renderer")
    func sniffedImageRoutesToQuickLook() async throws {
        // PNG magic bytes, enough of them for the sniff, with no name to help.
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data(repeating: 0, count: 64))
        let source = BytesSource(bytes: png, path: "/tmp/screenshot-no-extension")
        let data = try await FilePreviewLoader.load(
            path: "/tmp/screenshot-no-extension", line: nil,
            context: context(source, isLocal: true))
        #expect(isQuickLook(data.content))
    }

    @Test("A remote picture arrives without a URL, for the fetch path to fill in")
    func remoteImageHasNoURLYet() async throws {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data(repeating: 0, count: 64))
        let source = BytesSource(bytes: png, path: "/remote/pic")
        let data = try await FilePreviewLoader.load(
            path: "/remote/pic", line: nil, context: context(source, isLocal: false))
        guard case .quickLook(let url) = data.content else {
            Issue.record("expected quickLook, got \(data.content)")
            return
        }
        // Quick Look cannot stream: a remote file is downloaded first, and a
        // URL here would point at a path on the wrong machine.
        #expect(url == nil)
    }

    @Test("Text files are untouched by all of this")
    func textStillRendersAsText() async throws {
        let source = BytesSource(bytes: Data("let x = 1\n".utf8), path: "/tmp/main.swift")
        let data = try await FilePreviewLoader.load(
            path: "/tmp/main.swift", line: nil, context: context(source, isLocal: true))
        if case .text = data.content {} else {
            Issue.record("expected text, got \(data.content)")
        }
    }
}
