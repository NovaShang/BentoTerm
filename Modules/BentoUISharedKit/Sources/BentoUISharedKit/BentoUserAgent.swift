import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The User-Agent the embedded browser sends.
///
/// **This is not cosmetic.** `WKWebView`'s default UA is Safari's minus the two
/// tokens every sniffer keys on:
///
///     Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)
///
/// Safari sends the same string plus `Version/27.0 Safari/605.1.15`. Without
/// them, ua-parser-js, bowser and every hand-rolled `indexOf("Safari")` fall
/// through to their unknown-browser branch — which in practice means the ES5
/// bundle, feature gates turned off, or a "please upgrade your browser" page.
/// The engine is current WebKit either way; only the label was missing, and the
/// label is what sites read.
///
/// The claim is honest: we append the version of Safari actually installed on
/// this machine, and the engine really is that WebKit. We are not pretending to
/// be Chrome.
public enum BentoUserAgent {

    /// `nil` means "leave WebKit's default alone" — only possible if we could
    /// not read a Safari version, in which case inventing one would be worse.
    public static func string(appending defaultUA: String) -> String? {
        guard let version = safariVersion else { return nil }
        // Already complete (a future WebKit that fixed this): don't double it.
        guard !defaultUA.contains("Safari/") else { return nil }
        // Keyed on the SHAPE of the string, not on the compile target. An iOS
        // UA carries `Mobile/15E148` and Safari puts `Version/` before it;
        // macOS has no such token and takes it at the end. Deciding from the
        // string means this is testable from either platform, and right under
        // Catalyst — where the compile target would have answered "Mac" for a
        // UA that says iPad.
        if let range = defaultUA.range(of: " Mobile/") {
            let head = String(defaultUA[..<range.lowerBound])
            let tail = String(defaultUA[range.lowerBound...])
            return "\(head) Version/\(version)\(tail) Safari/604.1"
        }
        return "\(defaultUA) Version/\(version) Safari/605.1.15"
    }

    /// The Safari on this machine, so the version we claim is one that exists.
    ///
    /// macOS can read it off the app bundle. iOS cannot see other bundles, so
    /// it derives from the OS version — which is how Safari's own UA is built
    /// there anyway (iOS 27 ships Safari 27).
    static var safariVersion: String? {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let plist = "/Applications/Safari.app/Contents/Info.plist"
        if let dict = NSDictionary(contentsOfFile: plist),
           let v = dict["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return v
        }
        return nil
        #else
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard os.majorVersion > 0 else { return nil }
        return "\(os.majorVersion).\(os.minorVersion)"
        #endif
    }
}
