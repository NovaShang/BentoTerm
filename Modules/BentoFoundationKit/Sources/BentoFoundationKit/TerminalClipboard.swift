import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// System pasteboard bridge (one source of truth for both platforms).
///
/// Lives in FoundationKit rather than next to the surfaces because the session
/// engine needs it too: a program copying through tmux (`load-buffer -w`) lands
/// in a paste buffer, and bridging that to the system pasteboard happens in
/// BentoSessionKit, which must not depend on the surface layer.
@MainActor
public enum TerminalClipboard {
    public static func write(_ s: String) {
        guard !s.isEmpty else { return }
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = s
        #endif
    }

    public static func read() -> String? {
        #if canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #elseif canImport(UIKit)
        return UIPasteboard.general.string
        #endif
    }
}

