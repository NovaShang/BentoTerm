import Foundation
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Opens a URL in the system browser, if it's a scheme we're willing to hand
/// off (http/https/mailto/ftp/ftps). Cross-platform: AppKit on macOS, UIKit on
/// iOS. Mirrors the copy that historically lived in `GhosttyRuntime` (core);
/// new consumers should use this one.
public func openExternalURL(_ string: String) {
    guard let url = URL(string: string),
          let scheme = url.scheme?.lowercased(),
          ["http", "https", "mailto", "ftp", "ftps"].contains(scheme) else { return }
    DispatchQueue.main.async {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}
