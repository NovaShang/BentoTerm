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
    /// What is IN the field, which is not the same as where the tab is: while
    /// you are typing, the tab has not gone anywhere yet.
    @State private var typed: String = ""
    @FocusState private var addressFocused: Bool
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
                if tab.popup != nil {
                    popupBar
                    Divider()
                }
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

    /// Back / forward / reload, the address — editable, because knowing where
    /// you want to go is the ordinary case — and the way out to the real
    /// browser.
    ///
    /// The address shipped read-only on the theory that ⌘P was the address bar.
    /// It isn't: nobody guesses that the file palette takes URLs, and the
    /// palette is not even reachable from a pane with no tmux behind it. A
    /// browser has an address bar.
    ///
    /// There is deliberately no "which machine" chip. It said "This Mac" almost
    /// all the time, and on the occasions it said something else the window
    /// title had already said it — every pane in a window is on the same host,
    /// so the chip was restating the title in a smaller font. `localhost` here
    /// means what it means in the terminal you are looking at, for the same
    /// reason and with the same evidence. The host still gets named where it
    /// actually carries information: in a failure.
    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                button("chevron.left", enabled: tab.canGoBack) { tab.goBack() }
                button("chevron.right", enabled: tab.canGoForward) { tab.goForward() }
                button(tab.isLoading ? "xmark" : "arrow.clockwise", enabled: true) {
                    Task { await tab.reload() }
                }
                addressField
                button("safari", enabled: tab.displayURL != nil) {
                    guard let url = tab.displayURL else { return }
                    LinkRouter.open(url.absoluteString, forceSystem: true)
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

    /// Shown while a sign-in window covers the page. The page is still there
    /// underneath; this is the way back to it if the popup never closes
    /// itself (a login abandoned halfway).
    private var popupBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(tab.popupTitle.isEmpty ? "Sign-in window" : tab.popupTitle)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Close") { tab.closePopup() }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04))
    }

    /// Accepts exactly what ⌘P accepts — `localhost:3000`, `github.com/x`, a
    /// full URL — because they are the same parser. `localhost` means the
    /// machine this tab's pane is on, the same one the window title names.
    private var addressField: some View {
        TextField("Address", text: $typed)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .lineLimit(1)
            .focused($addressFocused)
            .onSubmit {
                // Only give up focus if we actually went somewhere. On an
                // address that doesn't parse, blurring would revert the text
                // and leave no trace that anything was wrong — the cursor
                // staying put is the feedback.
                guard PaletteURL.candidate(for: typed) != nil else { return }
                let text = typed
                Task { await tab.navigate(to: text) }
                addressFocused = false
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            // It has to LOOK like a field. The first version of this chrome
            // rendered the address as plain text and the complaint was not
            // "the address bar is ugly", it was "I can't find where to type
            // a URL" — a bare label reads as a caption, not an input.
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(addressFocused ? Color.accentColor.opacity(0.7)
                                                 : Color.primary.opacity(0.10),
                                  lineWidth: 1))
            // While the field has focus it belongs to the typist; a page that
            // finishes loading must not yank the text out from under them.
            .onChange(of: tab.displayURL) { _, url in
                guard !addressFocused else { return }
                typed = url?.absoluteString ?? ""
            }
            .onChange(of: addressFocused) { _, focused in
                // Leaving without submitting reverts to where the tab actually
                // is, rather than stranding a half-typed address in the bar.
                if !focused { typed = tab.displayURL?.absoluteString ?? "" }
            }
            .onAppear {
                typed = tab.displayURL?.absoluteString ?? ""
                // A "+" tab is a cursor waiting in an empty field. Consumed, so
                // re-selecting the tab later does not steal focus again.
                if tab.wantsAddressFocus {
                    tab.wantsAddressFocus = false
                    addressFocused = true
                }
            }
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

/// The container the representable actually owns. The WKWebView inside it
/// belongs to the `WebTab` and gets moved from one container to the next.
///
/// The dock shows one tab at a time, so selecting another tab takes this view
/// out of the hierarchy. When the WebView was the representable's own view,
/// that killed it: coming back gave you a fresh one that reloaded the URL from
/// scratch, throwing away scroll position, half-filled forms and everything the
/// page was holding. Parking the page instead is what makes going back to a tab
/// feel like going back to it.
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
fileprivate typealias WebContainer = NSView
#elseif canImport(UIKit)
fileprivate typealias WebContainer = UIView
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
private struct WebViewRepresentable: NSViewRepresentable {
    @ObservedObject var tab: WebTab
    let compact: Bool

    func makeNSView(context: Context) -> WebContainer {
        context.coordinator.makeContainer(compact: compact)
    }
    func updateNSView(_ view: WebContainer, context: Context) {
        context.coordinator.update(container: view, compact: compact)
    }
    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator(tab: tab) }
}
#elseif canImport(UIKit)
private struct WebViewRepresentable: UIViewRepresentable {
    @ObservedObject var tab: WebTab
    let compact: Bool

    func makeUIView(context: Context) -> WebContainer {
        context.coordinator.makeContainer(compact: compact)
    }
    func updateUIView(_ view: WebContainer, context: Context) {
        context.coordinator.update(container: view, compact: compact)
    }
    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator(tab: tab) }
}
#endif

@MainActor
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let tab: WebTab
    private var observations: [NSKeyValueObservation] = []
    private var appliedCompact: Bool?
    /// The WebView this coordinator has already wired itself into. A
    /// coordinator is made every time the browser view appears; the WebView it
    /// finds waiting for it usually is not new.
    private weak var adopted: WKWebView?

    init(tab: WebTab) {
        self.tab = tab
        super.init()
    }

    fileprivate func makeContainer(compact: Bool) -> WebContainer {
        let container = WebContainer()
        update(container: container, compact: compact)
        return container
    }

    fileprivate func update(container: WebContainer, compact: Bool) {
        let view = tab.webView ?? makeWebView()
        adopt(view)
        install(view, in: container)
        apply(compact: compact, to: view)
        // The popup sits over the page, in the same container, so it goes
        // wherever the page goes — and disappears with it.
        if let popup = tab.popup {
            popup.navigationDelegate = self
            popup.uiDelegate = self
            install(popup, in: container)
        }
    }

    /// First time this tab has ever been shown — everything below happens once
    /// per tab, not once per look at it.
    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // A persistent store, so logging into something once is once. Note this
        // is Bento's jar, not Safari's — WebKit gives no app access to Safari's,
        // which is exactly why "Open in Safari" stays in the chrome.
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Off by default on iOS: a `window.open` that isn't inside the click
        // itself (a sign-in button that opens its popup after a fetch) would be
        // dropped silently. Popups are real windows here now, so let them.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        tab.webView = view
        // UA first, THEN the first load — a request that goes out with the
        // default UA is the one that gets the legacy bundle, and reloading
        // afterwards would be visible.
        Task {
            await UserAgentCache.apply(to: view)
            await tab.load()
        }
        return view
    }

    /// Point a WebView's delegates and observations at THIS coordinator.
    ///
    /// Needed on every fresh coordinator, not just on a new WebView: the
    /// previous one went away with the view, leaving a live page with nobody
    /// listening to it.
    private func adopt(_ view: WKWebView) {
        guard adopted !== view else { return }
        adopted = view
        view.navigationDelegate = self
        // Without a UI delegate, WebKit silently drops every `target="_blank"`
        // and `window.open` — the link just does nothing, which is exactly how
        // this shipped.
        view.uiDelegate = self
        observations = [
            view.observe(\.isLoading, options: [.new]) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.sync(v) }
            },
            view.observe(\.title, options: [.new]) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.tab.noteNavigation(to: v.url, title: v.title) }
            },
        ]
        // The page kept going while it was parked; catch the chrome up.
        sync(view)
        tab.noteNavigation(to: view.url, title: view.title)
    }

    fileprivate func install(_ view: WKWebView, in container: WebContainer) {
        guard view.superview !== container else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// iOS only, and measured: `preferredContentMode` does not change the UA
    /// on macOS (all three settings produce a byte-identical string), so it is
    /// inert there and setting it would just be a lie in the code.
    ///
    /// Responsiveness on macOS does not need it. A site's `@media` queries key
    /// on the actual view width, so a narrow dock already gets the narrow
    /// layout — which is what makes dragging the divider a live preview.
    func apply(compact: Bool, to view: WKWebView) {
        #if canImport(UIKit)
        guard appliedCompact != compact else { return }
        appliedCompact = compact
        view.configuration.defaultWebpagePreferences?
            .preferredContentMode = compact ? .mobile : .desktop
        #endif
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
        if webView === tab.popup {
            tab.popupTitle = webView.title.flatMap { $0.isEmpty ? nil : $0 }
                ?? webView.url.map(WebTab.shortTitle(for:)) ?? ""
            return
        }
        tab.noteNavigation(to: webView.url, title: webView.title)
        sync(webView)
    }

    /// Connection-level failures only. A 404 or a 500 arrives as a SUCCESSFUL
    /// navigation carrying the site's own error page, and that page is a better
    /// answer than any panel we could put in front of it.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard webView !== tab.popup else { return }   // the page underneath is fine
        Task { await tab.noteFailure(error) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView !== tab.popup else { return }
        Task { await tab.noteFailure(error) }
    }
}

// MARK: - Links that ask for a new tab

extension WebViewCoordinator {

    /// `target="_blank"` / `window.open`.
    ///
    /// Two different requests hide behind this one callback, and they need
    /// opposite answers:
    ///
    /// - A link the user tapped that names a new tab. It wants a tab, and gets
    ///   one from whoever owns the tab strip. Returning nil here used to be the
    ///   whole implementation; nil with no delegate at all makes the link do
    ///   NOTHING, which reads as the app being broken.
    /// - Script opening a window — a sign-in popup. That one must be a child of
    ///   the calling page, built from the configuration WebKit passes in (it
    ///   refuses anything else), or there is no `window.opener` for the login
    ///   to report back through. It is shown over this tab and closes itself.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if navigationAction.navigationType == .linkActivated {
            if let open = tab.onOpenInNewTab {
                open(url)
            } else {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.navigationDelegate = self
        popup.uiDelegate = self
        tab.adoptPopup(popup)
        if let container = webView.superview { install(popup, in: container) }
        return popup   // WebKit loads the request into it
    }

    /// The popup called `window.close()` — a login that finished.
    func webViewDidClose(_ webView: WKWebView) {
        guard webView === tab.popup else { return }
        tab.closePopup()
    }
}


// MARK: - User agent

/// Resolves the Safari-shaped UA once and reuses it.
///
/// The default has to be read out of a live WebView (`navigator.userAgent`);
/// there is no supported synchronous getter, and the private `userAgent` key is
/// not worth the risk. One round trip on the first tab, cached for the rest.
@MainActor
enum UserAgentCache {
    /// Outer nil = not asked yet. Inner nil = asked, and the answer is "leave
    /// WebKit's default alone".
    private static var resolved: String??

    static func apply(to view: WKWebView) async {
        if let resolved {
            view.customUserAgent = resolved
            return
        }
        let raw = try? await view.evaluateJavaScript("navigator.userAgent")
        guard let defaultUA = raw as? String, !defaultUA.isEmpty else { return }
        let answer = BentoUserAgent.string(appending: defaultUA)
        resolved = .some(answer)
        view.customUserAgent = answer
    }
}
