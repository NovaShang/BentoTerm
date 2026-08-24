import SwiftUI
import WebKit
import BentoFoundationKit

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Bento's own browser pane.
///
/// **This is deliberately NOT `FilePreviewWebView`.** That renderer's whole
/// invariant is that it never goes online: the template is the only navigation
/// it allows, markdown is sanitised, and every non-`data:` image source is
/// stripped. A browser needs the exact opposite of all three. They share no
/// configuration and no instance on purpose — one `allowsContentJavaScript` set
/// on the wrong object would quietly retire that invariant.
@MainActor
public struct WebBrowserView: View {
    @ObservedObject var tab: WebTab
    /// Narrow enough that a desktop layout would be unreadable → render as a
    /// phone would. Widening the dock past this is what turns it back into a
    /// desktop viewport, which makes dragging the divider a responsive preview.
    private static let mobileViewportBelow: CGFloat = 620

    public init(tab: WebTab) {
        self.tab = tab
    }

    public var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                chrome
                Divider()
                if let failure = tab.failure {
                    FailurePanel(failure: failure) {
                        Task { await tab.reload() }
                    }
                } else {
                    WebViewRepresentable(
                        tab: tab,
                        compact: geo.size.width < Self.mobileViewportBelow)
                }
            }
        }
    }

    // MARK: Chrome

    /// Back / forward / reload, the machine this page lives on, its address,
    /// and the way out to the real browser. No address bar to type in — that is
    /// ⌘P's job, and it already knows how to take a URL.
    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                button("chevron.left", enabled: tab.canGoBack) { tab.goBack() }
                button("chevron.right", enabled: tab.canGoForward) { tab.goForward() }
                button(tab.isLoading ? "xmark" : "arrow.clockwise", enabled: true) {
                    Task { await tab.reload() }
                }
                hostChip
                Text(addressText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                button("safari", enabled: true) {
                    LinkRouter.open(tab.displayURL.absoluteString, forceSystem: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            if let warning = renumberWarning {
                Text(warning)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 5)
            }
        }
    }

    /// Which machine this page is on. Present even for local pages: with three
    /// panes on three boxes, "which one is this" is the first question.
    private var hostChip: some View {
        Text(tab.host.label)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
            .help(tab.host.isLocal ? "On this device" : "Tunnelled over SSH")
    }

    private var addressText: String {
        tab.displayURL.absoluteString
    }

    /// The one piece of plumbing worth surfacing: we could not get the same
    /// port number locally, so links the page writes with its own port in them
    /// will not resolve. Nothing we can fix from out here — so we say it.
    private var renumberWarning: String? {
        guard let f = tab.forward, f.isRenumbered else { return nil }
        return "Port \(f.remotePort) was busy here — using \(f.localPort). "
             + "Links inside the page that spell out :\(f.remotePort) won’t work."
    }

    private func button(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

// MARK: - Failure

/// Three failures, three sentences. The distinction that earns its keep is
/// "the tunnel is up but nothing is listening" vs "that machine is gone" —
/// a browser shows one blank page for both, and we know which it is.
private struct FailurePanel: View {
    let failure: WebTabFailure
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(failure.title)
                .font(.system(size: 13, weight: .medium))
            Text(failure.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Reload", action: onRetry)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var icon: String {
        switch failure {
        case .nothingListening: return "clock.arrow.circlepath"
        case .hostUnreachable: return "bolt.horizontal.circle"
        case .loadFailed: return "exclamationmark.triangle"
        }
    }
}

// MARK: - The WKWebView itself

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
private struct WebViewRepresentable: NSViewRepresentable {
    @ObservedObject var tab: WebTab
    let compact: Bool

    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView(compact: compact) }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.apply(compact: compact, to: view)
    }
    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator(tab: tab) }
}
#elseif canImport(UIKit)
private struct WebViewRepresentable: UIViewRepresentable {
    @ObservedObject var tab: WebTab
    let compact: Bool

    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeWebView(compact: compact) }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.apply(compact: compact, to: view)
    }
    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator(tab: tab) }
}
#endif

@MainActor
final class WebViewCoordinator: NSObject, WKNavigationDelegate {
    private let tab: WebTab
    private var observations: [NSKeyValueObservation] = []
    private var appliedCompact: Bool?

    init(tab: WebTab) {
        self.tab = tab
        super.init()
    }

    func makeWebView(compact: Bool) -> WKWebView {
        let config = WKWebViewConfiguration()
        // A persistent store, so logging into something once is once. Note this
        // is Bento's jar, not Safari's — WebKit gives no app access to Safari's,
        // which is exactly why "Open in Safari" stays in the chrome.
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        tab.webView = view
        apply(compact: compact, to: view)

        observations = [
            view.observe(\.isLoading, options: [.new]) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.sync(v) }
            },
            view.observe(\.title, options: [.new]) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.tab.noteNavigation(to: v.url, title: v.title) }
            },
        ]
        Task { await tab.load() }
        return view
    }

    /// A narrow dock renders as a phone would; widening it hands the page a
    /// desktop viewport. Only re-applied on a real change — resetting the
    /// content mode reloads the page.
    func apply(compact: Bool, to view: WKWebView) {
        guard appliedCompact != compact else { return }
        appliedCompact = compact
        // Optional on macOS, where the content mode is a no-op anyway.
        view.configuration.defaultWebpagePreferences?
            .preferredContentMode = compact ? .mobile : .desktop
    }

    private func sync(_ view: WKWebView) {
        tab.noteLoading(view.isLoading, back: view.canGoBack, forwardable: view.canGoForward)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        // A page on a build box linking to another port on the same box (a UI
        // on 5173 pointing at an API on 8080) is asking for a second tunnel.
        // Without this the browser would try that port on THIS machine.
        guard let rewritten = tab.rewriteTarget(for: url) else {
            decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
        if rewritten != url {
            webView.load(URLRequest(url: rewritten))
            return
        }
        Task { [weak self] in
            guard let self, let resolved = await self.tab.resolve(url) else { return }
            webView.load(URLRequest(url: resolved))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab.noteNavigation(to: webView.url, title: webView.title)
        sync(webView)
    }

    /// Connection-level failures only. A 404 or a 500 arrives as a SUCCESSFUL
    /// navigation carrying the site's own error page, and that page is a better
    /// answer than any panel we could put in front of it.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        Task { await tab.noteFailure(error) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { await tab.noteFailure(error) }
    }
}
