#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import QuickLookUI
import WebKit

/// A `QLPreviewView` that makes the system's WebKit-backed previews use the
/// width they are given.
///
/// Word/Excel/Keynote-family documents are drawn by a Quick Look display
/// bundle that lays the file out as a fixed-width page — A4 is 595pt — and
/// then pins its web view to that page and centres it. In a side dock that is
/// wrong at both ends: wider than the page the preview stops growing and sits
/// in a pool of background, and narrower than it the page is cut off at the
/// right edge, because a laid-out page never reflows.
///
/// So: learn the page's own width, then zoom to fit the dock — "fit width",
/// the way any document reader does it. Everything else Quick Look draws
/// (images, PDF, video: no web view anywhere in the hierarchy) is left exactly
/// as the system renders it.
final class FittingPreviewView: QLPreviewView {

    /// The page's own width, in points. Nil until it has been learned — and it
    /// can only be learned from a loaded document, which arrives well after
    /// `previewItem` is set.
    private var pageWidth: CGFloat?
    private weak var web: WKWebView?
    private var measuring = false
    /// Bounded retries: a preview that never reveals a width of its own is one
    /// that reflows on its own, and must not be touched.
    private var attempts = 0
    private static let maxAttempts = 12

    /// The next item is a different document with a different width — and may
    /// not be a web preview at all.
    func previewItemChanged() {
        web?.pageZoom = 1
        web = nil
        pageWidth = nil
        attempts = 0
    }

    override func layout() {
        super.layout()
        fitWidth()
    }

    private func fitWidth() {
        guard let web = locateWebView(), let host = web.superview else { return }

        if pageWidth == nil {
            // Two ways to learn the width, and which one is available depends
            // on the very thing being fixed:
            //
            //  • The view is wider than the page. The bundle has pinned the
            //    web view to the page's box and centred it — that pinned width
            //    IS the page, no question needed. (It runs a little wider than
            //    the paper itself; it's the bundle's own idea of the page box,
            //    margin included, so it's the better number of the two.)
            //  • The view is narrower. Nothing is pinned, the page is spilling
            //    off the right edge, and only the page knows how far.
            if web.frame.width > 1, web.frame.width < host.bounds.width - 1 {
                pageWidth = web.frame.width
            } else {
                measure(web)
                return
            }
        }
        guard let pageWidth, pageWidth > 1 else { return }

        // Undo the pinning first, or zooming past 1:1 just spills off the
        // right edge instead of filling the dock.
        if web.frame != host.bounds {
            web.frame = host.bounds
            web.autoresizingMask = [.width, .height]
        }
        // A4 in the narrowest dock the window allows is about 0.48, so the
        // floor never bites a document; it is there for a page so wide that
        // fitting it would mean shrinking it out of legibility, which is worth
        // a horizontal scrollbar instead.
        let zoom = min(max(host.bounds.width / pageWidth, 0.4), 4)
        if abs(web.pageZoom - zoom) > 0.005 { web.pageZoom = zoom }
    }

    private func locateWebView() -> WKWebView? {
        if let web, web.superview != nil { return web }
        web = Self.firstWebView(in: self)
        return web
    }

    private static func firstWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews {
            if let web = firstWebView(in: sub) { return web }
        }
        return nil
    }

    /// Asks a page too wide for its view how wide it actually is. Both numbers
    /// are in CSS points and neither is affected by `pageZoom` — which is
    /// still 1 here, because nothing is zoomed until this succeeds.
    private func measure(_ web: WKWebView) {
        guard !measuring, attempts < Self.maxAttempts else { return }
        measuring = true
        attempts += 1
        web.evaluateJavaScript(
            "[document.documentElement.scrollWidth, document.documentElement.clientWidth]"
        ) { [weak self] value, _ in
            guard let self else { return }
            self.measuring = false
            guard let pair = value as? [Double], pair[0] > pair[1] + 1 else {
                // Either nothing is loaded yet, or the page fits and there is
                // nothing to learn from it right now.
                self.retry()
                return
            }
            self.pageWidth = CGFloat(pair[0])
            // Applied straight away rather than through `needsLayout`: this
            // lands asynchronously, and a view nothing is redrawing would sit
            // un-zoomed until something else dirtied it.
            self.fitWidth()
        }
    }

    private func retry() {
        guard attempts < Self.maxAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.fitWidth()
        }
    }
}
#endif
