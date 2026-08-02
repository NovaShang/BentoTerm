import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A human name for THIS device, used only to say who owns a shared session's
/// size ("Sized to Shang iPad Air"). It is a label, never an identity: the
/// identity that matters is the tmux client name, which tmux itself hands out
/// and reclaims (see `TmuxSizingOwner`).
public enum BentoDeviceLabel {
    public static let current: String = {
        #if canImport(UIKit)
        // iOS 16+ returns the model name ("iPad") rather than the user's
        // chosen name unless the app holds the user-assigned-device-name
        // entitlement. Either is fine here — it only has to be recognisable.
        let name = UIDevice.current.name
        return name.isEmpty ? UIDevice.current.model : name
        #else
        let host = ProcessInfo.processInfo.hostName
        // Strip the mDNS suffix: "Shangs-Air.local" reads as noise in a menu.
        return host.hasSuffix(".local") ? String(host.dropLast(6)) : host
        #endif
    }()
}
