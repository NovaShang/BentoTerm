import Foundation
import WebKit
import BentoFoundationKit
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
    private var imageQueue: [String] = []
    private var imageFilling = false
    private var imageBytesUsed = 0

    /// A single image we're willing to inline. Bigger than this is a photo the
    /// preview has no business holding in the DOM.
    private static let imageMaxBytes = 8 * 1024 * 1024
    /// Total across one document. Every fill stays resident as a base64 data:
    /// URI (~4/3 of the file), so this — not a count of images — is what keeps
    /// a photo-heavy README from evicting the app on iOS.
    private static let imageByteBudget = 24 * 1024 * 1024

    public static func makePreview() -> FilePreviewWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        // The page asks for images as they come into view; this is that channel.
        let bridge = FilePreviewImageBridge()
        cfg.userContentController.add(bridge, name: "bentoImages")
        let v = FilePreviewWebView(frame: .zero, configuration: cfg)
        bridge.owner = v
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
              let json = String(data: data, encoding: .utf8) else { return }
        // The JSON-encoded payload embeds directly as a JS object literal.
        // Raw U+2028/U+2029 (legal in filenames) are valid in JS string
        // literals since ES2019, which every supported WebKit version has.
        evaluateJavaScript("bentoRender(\(json))") { [weak self] _, _ in
            MainActor.assumeIsolated { self?.startImageFill() }
        }
    }

    // MARK: - Markdown image fill

    /// Hand the freshly rendered document a new fill sequence. The page then
    /// requests images as they approach the viewport (`bentoObserveImages`),
    /// and each request comes back through `enqueueImages`. Requesting the
    /// whole document up front is what made a photo-heavy file lose its tail:
    /// the budget ran out and the leftovers stayed blank.
    /// http(s) never gets here — the page stubs those itself.
    private func startImageFill() {
        imageFillSeq += 1
        imageQueue.removeAll()
        imageBytesUsed = 0
        guard imageBase != nil else {
            // No source behind this preview: nothing can ever fill, so say so
            // instead of leaving blank boxes in the document.
            evaluateJavaScript("bentoStubUnfilled()")
            return
        }
        evaluateJavaScript("bentoObserveImages(\(imageFillSeq))")
    }

    /// The page wants these sources. Sequential on purpose — over SSH each one
    /// is a stat plus a read, and a burst of parallel reads on one channel
    /// buys nothing.
    fileprivate func enqueueImages(_ srcs: [String], seq: Int) {
        guard seq == imageFillSeq, imageBase != nil else { return }
        imageQueue.append(contentsOf: srcs)
        pumpImageQueue()
    }

    private func pumpImageQueue() {
        guard !imageFilling, !imageQueue.isEmpty, let base = imageBase else { return }
        imageFilling = true
        let seq = imageFillSeq
        Task { @MainActor [weak self] in
            while true {
                guard let self, self.imageFillSeq == seq, !self.imageQueue.isEmpty else { break }
                await self.fillOne(src: self.imageQueue.removeFirst(), base: base)
            }
            guard let self else { return }
            self.imageFilling = false
            // A render that landed mid-drain abandoned this queue at the seq
            // check above; whatever the new document has asked for since is
            // still waiting, so keep draining.
            self.pumpImageQueue()
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
        let maxBytes = Self.imageMaxBytes
        guard let (resolved, st) = try? await base.source.stat(path: path, cwd: base.directory),
              st.isRegular, st.size <= maxBytes,
              imageBytesUsed + Int(st.size) <= Self.imageByteBudget,
              let mime = FilePreviewImageMIME.table[(resolved as NSString).pathExtension.lowercased()],
              let bytes = try? await base.source.read(resolvedPath: resolved, maxBytes: maxBytes),
              // A transport-truncated read (or a file that grew after the
              // stat — TOCTOU) must not ship a cut-off data: URI; fail the
              // image like any other miss.
              Int64(bytes.count) == st.size
        else {
            callJS("bentoFailImage", src)
            return
        }
        imageBytesUsed += bytes.count
        callJS("bentoSetImage", src, "data:\(mime);base64,\(bytes.base64EncodedString())")
    }

    /// Evaluate `fn(args…)` with each argument JSON-encoded (safe embedding;
    /// raw U+2028/U+2029 are fine on WebKit ≥ ES2019 — see `send`).
    private func callJS(_ fn: String, _ args: String...) {
        let encoded = args.map { arg -> String in
            let data = (try? JSONEncoder().encode([arg])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            return String(data.dropFirst().dropLast())
        }
        evaluateJavaScript("\(fn)(\(encoded.joined(separator: ",")))")
    }

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
        // A tapped link leaves this WebView; nothing else navigates, ever.
        // Where it lands is the router's call, not ours — this renderer's
        // invariant is only that IT never goes online.
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            LinkRouter.open(url.absoluteString)
        }
        decisionHandler(.cancel)
    }
}

/// Carries the page's "these images are coming into view" messages to the
/// view. A separate object because `WKUserContentController` retains its
/// handlers — registering the view itself would be a retain cycle through its
/// own configuration.
private final class FilePreviewImageBridge: NSObject, WKScriptMessageHandler {
    weak var owner: FilePreviewWebView?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let seq = body["seq"] as? Int,
              let srcs = body["srcs"] as? [String]
        else { return }
        // WebKit delivers on the main thread; the view is MainActor-isolated.
        MainActor.assumeIsolated { owner?.enqueueImages(srcs, seq: seq) }
    }
}
