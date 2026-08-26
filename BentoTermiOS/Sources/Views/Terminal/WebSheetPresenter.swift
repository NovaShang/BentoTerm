import UIKit
import SwiftUI
import BentoFoundationKit
import BentoUISharedKit

/// The phone's side dock.
///
/// There is no split view here to put a panel in, so a page gets exactly the
/// standing a file preview has: a sheet over the terminal, same detents, same
/// grabber. Passive only — a page arrives because you tapped a link or took the
/// offer of a dev server, never because you typed an address, which is what ⌘P
/// is for and the phone has no ⌘P.
///
/// Where this really earns its place: on a Mac you can always drop to a shell
/// and run `ssh -L` yourself. On a phone you cannot, so "the agent started a
/// dev server on the build box and I want to look at it from the sofa" is
/// impossible without this.
@MainActor
enum WebSheetPresenter {

    private static weak var liveHost: WebSheetHost?

    /// Returns false when there is nowhere to present — the router then falls
    /// back to Safari rather than swallowing the tap.
    @discardableResult
    static func present(url: URL, origin: LinkOrigin?) -> Bool {
        let tab = WebTab(url: url, origin: origin)
        // There is no tab strip on a phone, so a page asking for a new tab
        // (`target="_blank"`) gets this sheet, pointed somewhere else. Silently
        // doing nothing is the one option that reads as a broken app.
        tab.onOpenInNewTab = { target in
            _ = WebSheetPresenter.present(url: target, origin: origin)
        }

        // A sheet is already up: swap its page rather than stacking a second
        // sheet on top of the first, which iOS allows and nobody wants.
        if let host = liveHost, host.view.window != nil {
            host.replace(with: tab)
            return true
        }
        guard let top = topViewController() else { return false }

        let host = WebSheetHost(tab: tab)
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .large   // a page wants the room
            sheet.prefersGrabberVisible = true
            sheet.prefersEdgeAttachedInCompactHeight = true
        }
        liveHost = host
        top.present(host, animated: true)
        return true
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var vc = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
                ?? scene?.windows.first?.rootViewController
        else { return nil }
        while let presented = vc.presentedViewController, !presented.isBeingDismissed {
            vc = presented
        }
        return vc
    }
}

/// Hosts one `WebTab` and, crucially, stops it when the sheet goes away.
/// Dismissing the sheet is what closes the tunnel — no forward outlives
/// something the user can see.
@MainActor
final class WebSheetHost: UIHostingController<WebBrowserView> {
    /// Not `tab`: `UIViewController.tab` is UIKit's own (`UITab`) as of iOS 18.
    private var webTab: WebTab

    init(tab: WebTab) {
        self.webTab = tab
        super.init(rootView: WebBrowserView(tab: tab))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func replace(with newTab: WebTab) {
        webTab.stop()
        webTab = newTab
        rootView = WebBrowserView(tab: newTab)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || view.window == nil else { return }
        webTab.stop()
    }
}
