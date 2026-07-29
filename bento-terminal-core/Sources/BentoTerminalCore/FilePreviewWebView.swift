import Foundation
import WebKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Shared web renderer for the `.text` case of file previews: syntax
/// highlighting (highlight.js) for code, rendered GitHub-flavored Markdown
/// (markdown-it) for .md, with a line gutter and `path:42`-style jump.
/// One implementation for the macOS panel and the iOS sheet — the template
/// and vendored JS live in this package's resources.
///
/// Isolation: the page is a local template loaded once via `loadFileURL`;
/// content goes in as a JSON payload through `evaluateJavaScript`, never as
/// interpolated HTML. The navigation delegate cancels everything except the
/// initial template load — link taps open in the system browser, and the
/// page has no way to reach the network (markdown images render as stubs).
@MainActor
public final class FilePreviewWebView: WKWebView, WKNavigationDelegate {

    private struct Payload: Encodable {
        let name: String
        let text: String
        let line: Int?
        let dark: Bool
    }

    /// Where a markdown file's relative images resolve: the FILE's own
    /// directory (standard markdown semantics — never the pane cwd or any
    /// root), read through the same per-transport source the file came from.
    public struct ImageBase {
        public let directory: String
        public let source: FilePreviewSource
        public init(directory: String, source: FilePreviewSource) {
            self.directory = directory
            self.source = source
        }
    }

    private var templateReady = false
    private var pending: Payload?
    private var imageBase: ImageBase?
    private var imageFillSeq = 0

    public static func makePreview() -> FilePreviewWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let v = FilePreviewWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = v
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        v.allowsMagnification = true
        #endif
        if let html = Bundle.module.url(forResource: "preview", withExtension: "html",
                                        subdirectory: "PathPreview") {
            v.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        return v
    }

    /// Render `text` as `fileName`'s content. Safe to call before the
    /// template finished loading — the last payload wins once it's up.
    /// `imageBase` non-nil enables filling markdown-relative images in as
    /// data: URIs after the render.
    public func render(fileName: String, text: String, line: Int?, dark: Bool,
                       imageBase: ImageBase? = nil) {
        self.imageBase = imageBase
        let payload = Payload(name: fileName, text: text, line: line, dark: dark)
        guard templateReady else { pending = payload; return }
        send(payload)
    }

    /// Ship a payload to the page. Separate from `render` on purpose: the
    /// deferred flush in `didFinish` must NOT touch `imageBase` — the very
    /// first render of a fresh WebView always lands there (the panel makes one
    /// view per opened file, so the template is still loading), and clearing
    /// the base there meant markdown images never filled at all.
    private func send(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload),
              var json = String(data: data, encoding: .utf8) else { return }
        // U+2028/2029 are valid JSON but not valid JS string literals.
        json = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        evaluateJavaScript("bentoRender(\(json))") { [weak self] _, _ in
            MainActor.assumeIsolated { self?.fillImages() }
        }
    }

    // MARK: - Markdown image fill

    /// Ask the document which images it wants, then read each through the
    /// file source and hand it back as a data: URI. Bounded (count + bytes),
    /// sequential, and guarded by a sequence so a re-render abandons stale
    /// fills. http(s) never gets here — the page stubs those itself.
    private func fillImages() {
        guard let base = imageBase else { return }
        imageFillSeq += 1
        let seq = imageFillSeq
        evaluateJavaScript("bentoWantedImages()") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, self.imageFillSeq == seq,
                      let srcs = result as? [String], !srcs.isEmpty else { return }
                Task { @MainActor [weak self] in
                    for src in srcs.prefix(12) {
                        guard let self, self.imageFillSeq == seq else { return }
                        await self.fillOne(src: src, base: base)
                    }
                }
            }
        }
    }

    private func fillOne(src: String, base: ImageBase) async {
        let raw = src.removingPercentEncoding ?? src
        let path: String
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            path = raw
        } else {
            path = ((base.directory as NSString).appendingPathComponent(raw)
                as NSString).standardizingPath
        }
        let maxBytes = 8 * 1024 * 1024
        guard let (resolved, st) = try? await base.source.stat(path: path, cwd: base.directory),
              st.isRegular, st.size <= maxBytes,
              let mime = Self.imageMIME[(resolved as NSString).pathExtension.lowercased()],
              let bytes = try? await base.source.read(resolvedPath: resolved, maxBytes: maxBytes)
        else {
            callJS("bentoFailImage", src)
            return
        }
        callJS("bentoSetImage", src, "data:\(mime);base64,\(bytes.base64EncodedString())")
    }

    /// Evaluate `fn(args…)` with each argument JSON-encoded (safe embedding).
    private func callJS(_ fn: String, _ args: String...) {
        let encoded = args.map { arg -> String in
            let data = (try? JSONEncoder().encode([arg])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            return String(data.dropFirst().dropLast())
        }
        evaluateJavaScript("\(fn)(\(encoded.joined(separator: ",")))")
    }

    private static let imageMIME: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml",
        "bmp": "image/bmp", "tiff": "image/tiff", "tif": "image/tiff",
        "ico": "image/x-icon", "heic": "image/heic", "heif": "image/heif",
        "avif": "image/avif",
    ]

    /// Follow an appearance change without re-rendering.
    public func setDark(_ dark: Bool) {
        guard templateReady else {
            if let p = pending {
                pending = Payload(name: p.name, text: p.text, line: p.line, dark: dark)
            }
            return
        }
        evaluateJavaScript("bentoSetTheme(\(dark))")
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        templateReady = true
        if let p = pending {
            pending = nil
            send(p)
        }
    }

    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Initial template load (and only that) is a local file navigation.
        if navigationAction.navigationType == .other,
           navigationAction.request.url?.isFileURL == true, !templateReady {
            decisionHandler(.allow)
            return
        }
        // A tapped link opens outside; nothing else navigates, ever.
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            GhosttyRuntime.openExternalURL(url.absoluteString)
        }
        decisionHandler(.cancel)
    }
}
