import Foundation
import os

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Same category as the surfaces' link detectors, so one predicate follows a
/// click all the way from "which URL is under the cursor" to "where did it go":
/// `log stream --predicate 'category == "Link"'`.
private let routerLog = Logger(subsystem: "com.novashang.bento", category: "Link")

// MARK: - Where a link comes from

/// Which machine a link's `localhost` means.
///
/// A terminal is routinely somewhere else. `http://localhost:5173` printed by a
/// dev server in a pane that is ssh'd into a build box does NOT point at this
/// device, and opening it here is not a degraded answer — it is the wrong page,
/// or nothing at all. Every link therefore carries the machine it was printed
/// on, and the port forwarder is what makes that address reachable.
public struct LinkHost: Sendable, Equatable, Hashable {
    /// Stable identity of the machine, or nil for this device.
    ///
    /// Opaque to the router: macOS puts the `~/.ssh/config` alias here, iOS the
    /// saved host's id. All it has to be is stable, and equal for two panes on
    /// the same machine — that is what lets one forward serve both.
    public let remoteID: String?
    /// What a human sees: "This Mac", "user@build-box".
    public let label: String

    public var isLocal: Bool { remoteID == nil }

    public init(remoteID: String?, label: String) {
        self.remoteID = remoteID
        self.label = label
    }

    public static func local(label: String) -> LinkHost {
        LinkHost(remoteID: nil, label: label)
    }
}

/// The pane a link was clicked in. `nil` origin means "no terminal was
/// involved" (⌘P, a link inside a file preview) — which resolves to this
/// device, the same answer a local pane would give.
public struct LinkOrigin: Sendable, Equatable {
    public let paneID: String?
    public let host: LinkHost

    public init(paneID: String?, host: LinkHost) {
        self.paneID = paneID
        self.host = host
    }
}

/// What the in-app browser is handed.
public struct LinkOpenRequest: Sendable {
    public let url: URL
    public let origin: LinkOrigin?

    public init(url: URL, origin: LinkOrigin?) {
        self.url = url
        self.origin = origin
    }
}

// MARK: - The decision

public enum LinkDestination: Sendable, Equatable {
    /// Bento's own browser: the side dock on macOS, a sheet on iOS.
    case inApp
    /// The system default browser / mail client.
    case system
    /// Not a scheme we open at all.
    case refused
}

/// The user's setting for where web links land.
public enum LinkOpenPreference: String, Sendable, CaseIterable, Codable {
    case inApp
    case system
}

// MARK: - The one entry point

/// The single place a link becomes an action.
///
/// There used to be two `openExternalURL`s — one in this module, one on
/// `GhosttyRuntime` — and the engine's `OPEN_URL` action, the macOS ⌘-click
/// path and the iOS tap chip did not all go through the same one. Two entry
/// points means every future routing rule has to be written twice and will
/// eventually be written once; this type exists so there is nowhere else to
/// put it.
public enum LinkRouter {

    /// Schemes the app is willing to act on at all. Terminal output is
    /// attacker-controlled in the ordinary case (you `cat` a log, you `curl`
    /// someone's endpoint), so a crafted OSC 8 link must not be able to launch
    /// `file://` or a custom app scheme.
    private static let openableSchemes: Set<String> = ["http", "https", "mailto", "ftp", "ftps"]

    /// Whether the app would act on this string at all. Callers that OFFER a
    /// link before opening it (the iOS tap chip, the tap router) ask first, so
    /// a link the app will refuse is never presented as tappable.
    public nonisolated static func canOpen(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased()
        else { return false }
        return openableSchemes.contains(scheme)
    }

    /// Where this link should go. Pure, so the routing rules are asserted in a
    /// test rather than read off three call sites.
    ///
    /// - `forceSystem` is the escape hatch (⌘⇧-click, "Open in Safari"). It can
    ///   push a link out to the system browser but can never pull a refused
    ///   scheme in — the allowlist is not a preference.
    public nonisolated static func destination(
        for string: String,
        preference: LinkOpenPreference,
        forceSystem: Bool = false
    ) -> LinkDestination {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              openableSchemes.contains(scheme) else { return .refused }
        // mailto/ftp are not web pages; an embedded browser has nothing to show
        // for them, so they always belong to whatever the OS registered.
        guard scheme == "http" || scheme == "https" else { return .system }
        if forceSystem || preference == .system { return .system }
        return .inApp
    }

    // MARK: Wiring

    /// Where web links land by default. Set from the app's settings at launch.
    @MainActor public static var preference: LinkOpenPreference = .inApp

    /// Installed by the platform UI (the macOS side dock, the iOS sheet).
    ///
    /// Returns false when it cannot take this link right now — no window, the
    /// browser disabled — and the router falls back to the system browser
    /// rather than dropping the click on the floor. A click that does nothing
    /// visible is the one outcome worse than opening in the wrong place.
    @MainActor public static var inAppHandler: (@MainActor (LinkOpenRequest) -> Bool)?

    /// Open a link. Callable from any isolation (the engine's action dispatch,
    /// a gesture handler, a WebView delegate); the decision and the opening
    /// both happen on the main actor.
    public nonisolated static func open(
        _ string: String,
        from origin: LinkOrigin? = nil,
        forceSystem: Bool = false
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                route(string, from: origin, forceSystem: forceSystem)
            }
        }
    }

    @MainActor
    private static func route(_ string: String, from origin: LinkOrigin?, forceSystem: Bool) {
        let decided = destination(for: string, preference: preference, forceSystem: forceSystem)
        guard decided != .refused, let url = URL(string: string) else {
            routerLog.log("refused ⟨\(string, privacy: .public)⟩")
            return
        }
        if decided == .inApp,
           let handler = inAppHandler,
           handler(LinkOpenRequest(url: url, origin: origin)) {
            routerLog.log("in-app ⟨\(string, privacy: .public)⟩ host=\(origin?.host.label ?? "-", privacy: .public)")
            return
        }
        routerLog.log("system ⟨\(string, privacy: .public)⟩")
        openInSystemBrowser(url)
    }

    @MainActor
    private static func openInSystemBrowser(_ url: URL) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}
