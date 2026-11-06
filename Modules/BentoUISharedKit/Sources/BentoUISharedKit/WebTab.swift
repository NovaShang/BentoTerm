import Foundation
import Combine
import WebKit
import BentoFoundationKit
import os

private let log = Logger(subsystem: "com.novashang.bento", category: "WebTab")

/// One page open in Bento's own browser.
///
/// The side dock used to show what an agent was WRITING; this is what an agent
/// has BUILT. Same panel, same tab strip, second kind of tab — a file and a
/// running page are two views of the same work, so they live in the same place.
///
/// Two things here are not obvious and are the whole design:
///
/// 1. **`id` is not the URL.** A browser tab navigates. Keying the view on a
///    changing id rebuilds the `WKWebView` on every click and throws away
///    scroll position, form state and login. File tabs can key on their path
///    because a file tab never becomes a different file; this one can't.
///
/// 2. **The address the user sees is the REMOTE one.** `http://localhost:5173`
///    on a build box is loaded through a forwarded local port, but that port is
///    bookkeeping. Showing `127.0.0.1:51234` would be showing the plumbing and
///    would not be copy-pasteable back into the terminal it came from.
@MainActor
public final class WebTab: ObservableObject, Identifiable {

    /// Stable for this tab's whole life. See the note above.
    public let id: String

    /// What the user asked for, in the address the machine it came from uses.
    /// Nil on a tab opened with "+" — it has nothing to show until you type
    /// somewhere to go.
    @Published public private(set) var displayURL: URL?
    @Published public private(set) var title: String
    @Published public private(set) var isLoading = false
    @Published public private(set) var canGoBack = false
    @Published public private(set) var canGoForward = false
    @Published public private(set) var failure: WebTabFailure?
    /// Non-nil once a tunnel is carrying this tab, and the thing the "port
    /// moved" warning is read off.
    @Published public private(set) var forward: PortForward?

    /// Which machine this tab's `localhost` means.
    public let host: LinkHost
    public let origin: LinkOrigin?

    /// Forwards this tab has set up, by REMOTE port. A page's own absolute
    /// links routinely name other ports on the same box (an API on 8080 next to
    /// a UI on 5173), so one tab can end up owning several.
    private var forwards: [Int: PortForward] = [:]
    /// The local side of everything in `forwards` — how a request is recognised
    /// as already-rewritten instead of being rewritten forever.
    private var localPorts: Set<Int> = []

    /// A page asked to open in a NEW tab (`target="_blank"`, `window.open`).
    /// Installed by whatever owns the tab strip; without it such a link does
    /// nothing at all, which is how this shipped the first time.
    public var onOpenInNewTab: (@MainActor (URL) -> Void)?

    /// True until the address bar has been given its one chance to take focus —
    /// a tab opened with "+" is a cursor waiting in an empty field.
    @Published public var wantsAddressFocus: Bool

    /// The live WKWebView, **owned by the tab, not by the view**.
    ///
    /// The dock shows one tab at a time, so switching tabs takes the browser
    /// view out of the hierarchy. If the WebView belonged to the view it would
    /// die there and come back as a blank one that reloads from scratch —
    /// scroll position, form input, and anything the page holds in memory gone
    /// every time you glanced at a file. It lives as long as the tab does; the
    /// view borrows it and hands it back.
    var webView: WKWebView?

    /// A window the page opened with `window.open` — in practice a sign-in
    /// popup (Google's, GitHub's, every OAuth button that isn't a redirect).
    ///
    /// It has to be a real child of THIS page, made from the configuration
    /// WebKit hands over: that is what gives it a `window.opener`, and the
    /// opener is how the popup reports the login back before closing itself.
    /// Loading its URL in a new tab instead — which is what shipped — produced
    /// a Google page that let you sign in and then went nowhere, because the
    /// page that asked was no longer listening (on the phone it had been
    /// replaced outright). Shown over the tab with a way to dismiss it; closed
    /// for us when the page calls `window.close()`.
    @Published var popup: WKWebView?
    @Published var popupTitle: String = ""

    public init(url: URL?, origin: LinkOrigin?) {
        self.id = "web:" + UUID().uuidString
        self.displayURL = url
        self.origin = origin
        self.host = origin?.host ?? .local(label: "This device")
        self.title = url.map(WebTab.shortTitle(for:)) ?? "New Tab"
        self.wantsAddressFocus = (url == nil)
    }

    /// Go to whatever was typed in the address bar.
    ///
    /// Parsed by `WebAddress`: `localhost:3000`, `github.com/x` and a full URL
    /// all work, and `localhost` means the machine THIS TAB is on.
    public func navigate(to text: String) async {
        guard let url = WebAddress.candidate(for: text) else { return }
        displayURL = url
        title = WebTab.shortTitle(for: url)
        failure = nil
        await load(url)
    }

    /// The tab strip's label: the host, or the port when the host is just
    /// "localhost" and the port is the only thing that tells two tabs apart.
    static func shortTitle(for url: URL) -> String {
        let h = url.host ?? url.absoluteString
        if isLoopbackHost(h), let port = url.port { return ":\(port)" }
        return h
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
            || host == "[::1]" || host.hasSuffix(".localhost")
    }

    // MARK: Loading

    /// Load `displayURL`, setting up a tunnel first if it points at a port on
    /// another machine.
    public func load() async {
        guard let displayURL else { return }   // a blank "+" tab has nowhere to go yet
        failure = nil
        await load(displayURL)
    }

    public func reload() async {
        // A manual reload is the answer to "the dev server was restarting", so
        // it has to retry the tunnel too, not just poke the WebView.
        await load()
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    /// Take a popup on. Only one at a time: a page opening a second sign-in
    /// window has abandoned the first.
    func adoptPopup(_ view: WKWebView) {
        closePopup()
        popup = view
        popupTitle = view.url.map(WebTab.shortTitle(for:)) ?? ""
    }

    func closePopup() {
        guard let popup else { return }
        popup.stopLoading()
        popup.navigationDelegate = nil
        popup.uiDelegate = nil
        popup.removeFromSuperview()
        self.popup = nil
        popupTitle = ""
    }

    private func load(_ url: URL) async {
        guard let resolved = await resolve(url) else { return }
        webView?.load(URLRequest(url: resolved))
    }

    /// Turn an address on `host` into one this device can actually open.
    ///
    /// Returns nil when it could not, having set `failure` — the caller has
    /// nothing left to do.
    func resolve(_ url: URL) async -> URL? {
        // Only loopback needs a tunnel, and only when "here" isn't the machine
        // that printed it. Everything else (github.com, a LAN address the phone
        // can already reach) loads as-is.
        guard WebTab.isLoopbackHost(url.host), !host.isLocal else { return url }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        // Already rewritten by us on a previous hop.
        if localPorts.contains(port) { return url }
        if let existing = forwards[port] { return existing.localURL(replacing: url) }

        guard let forwarder = PortForwarders.current else {
            failure = .hostUnreachable("Port forwarding isn’t available in this build")
            return nil
        }
        do {
            let made = try await forwarder.forward(remotePort: port, on: host)
            forwards[port] = made
            localPorts.insert(made.localPort)
            if forward == nil || port == displayURL?.port { forward = made }
            return made.localURL(replacing: url)
        } catch let error as PortForwardError {
            failure = WebTabFailure(error, host: host, port: port)
            return nil
        } catch {
            failure = WebTabFailure(.couldNotReach(host), host: host, port: port)
            return nil
        }
    }

    /// A navigation inside the page landed on a loopback address — decide
    /// whether it needs its own tunnel. Returns the URL to load instead, or nil
    /// to let the original through.
    func rewriteTarget(for url: URL) -> URL? {
        guard WebTab.isLoopbackHost(url.host), !host.isLocal else { return nil }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        if localPorts.contains(port) { return nil }
        if let existing = forwards[port] { return existing.localURL(replacing: url) }
        return url   // needs a new forward; the caller goes async
    }

    // MARK: Reporting back from the WebView

    func noteNavigation(to url: URL?, title pageTitle: String?) {
        if let url { displayURL = remoteFacing(url) }
        if let pageTitle, !pageTitle.isEmpty { title = pageTitle }
        else if let displayURL { title = WebTab.shortTitle(for: displayURL) }
    }

    /// Put the remote port back into an address we rewrote, so the bar shows
    /// what the user would type over there.
    private func remoteFacing(_ url: URL) -> URL {
        guard let port = url.port, localPorts.contains(port),
              let match = forwards.first(where: { $0.value.localPort == port })
        else { return url }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.host = "localhost"
        c?.port = match.key
        return c?.url ?? url
    }

    func noteLoading(_ loading: Bool, back: Bool, forwardable: Bool) {
        isLoading = loading
        canGoBack = back
        canGoForward = forwardable
    }

    /// A load failed at the CONNECTION level. HTTP errors (404, 500) are not
    /// routed here — those are pages, and the site's own error page is a better
    /// answer than anything we could write.
    func noteFailure(_ error: Error) async {
        let ns = error as NSError
        // Cancelled = we navigated away on purpose (a rewrite), not a failure.
        guard ns.domain != NSURLErrorDomain || ns.code != NSURLErrorCancelled else { return }
        guard let current = forward else {
            failure = .loadFailed(ns.localizedDescription)
            return
        }
        // The one thing we know that a browser does not: whether the tunnel is
        // still up. "Nothing is listening over there" and "that machine is
        // gone" look identical in a browser and need different sentences.
        let alive = await PortForwarders.current?.isAlive(current) ?? false
        failure = alive
            ? .nothingListening(port: current.remotePort, host: host.label)
            : .hostUnreachable("The connection to \(host.label) is gone — reconnect the session")
        log.log("load failed, tunnel alive=\(alive, privacy: .public)")
    }

    // MARK: Teardown

    /// Closing the tab is what closes the tunnels. Nothing invisible keeps
    /// carrying traffic.
    public func stop() {
        closePopup()
        if let webView {
            webView.stopLoading()
            // The tab owns it, so closing the tab is the only thing that
            // releases it — detach the delegates first so a navigation already
            // in flight can't call back into a tab that's on its way out.
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
            self.webView = nil
        }
        for f in forwards.values { PortForwarders.current?.close(f) }
        forwards.removeAll()
        localPorts.removeAll()
        forward = nil
    }
}

// MARK: - What went wrong

public enum WebTabFailure: Equatable, Sendable {
    /// The machine is not reachable.
    case hostUnreachable(String)
    /// The tunnel is fine; nothing is listening on that port over there. Almost
    /// always a dev server mid-restart, which is a thing agents do constantly.
    case nothingListening(port: Int, host: String)
    /// Everything was reachable and the load still failed.
    case loadFailed(String)

    init(_ error: PortForwardError, host: LinkHost, port: Int) {
        switch error {
        case .hostUnreachable(let why): self = .hostUnreachable(why)
        case .nothingListening: self = .nothingListening(port: port, host: host.label)
        case .noLocalPort:
            self = .hostUnreachable("No free local port to open the tunnel on")
        case .unsupported(let why): self = .hostUnreachable(why)
        }
    }

    /// The headline. Says what is wrong, not why the protocol works this way.
    public var title: String {
        switch self {
        case .hostUnreachable: return "Can’t reach that machine"
        case .nothingListening(let port, let host): return "Nothing is running on \(host):\(port)"
        case .loadFailed: return "This page didn’t load"
        }
    }

    /// The line under it. Says what to check or do.
    public var detail: String {
        switch self {
        case .hostUnreachable(let why): return why
        case .nothingListening:
            return "The server may still be starting up — reload in a moment."
        case .loadFailed(let why): return why
        }
    }
}
