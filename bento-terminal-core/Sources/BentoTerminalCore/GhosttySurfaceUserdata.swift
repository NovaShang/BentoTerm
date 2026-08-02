import Foundation
import GhosttyKit

/// The userdata-carried surface the shared `GhosttyRuntime` routes engine
/// actions to. Both surface variants (iOS UIView, macOS NSView) conform, so
/// the runtime never names a platform type directly — it only knows that the
/// opaque userdata points at one of these.
@MainActor
public protocol GhosttySurfaceUserdata: AnyObject {
    /// Bytes the engine wants written to the host (the `write_to_host_cb`
    /// path — keystrokes, paste, etc.), routed to the surface that owns the
    /// connection.
    func handleHostWrite(_ data: Data)
    func setNeedsDraw()
    func handleScrollbar(total: UInt64, offset: UInt64, len: UInt64)
    func handleColorChange(kind: ghostty_action_color_kind_e, red: UInt8, green: UInt8, blue: UInt8)
    func handlePwd(_ pwd: String?)
    func handleMouseShape(_ shape: ghostty_action_mouse_shape_e)
    func handleMouseVisibility(_ visible: Bool)
    func handleStartSearch(needle: String?)
    func handleEndSearch()
    func handleSearchTotal(_ total: Int?)
    func handleSearchSelected(_ selected: Int?)
    func handleRendererHealth(healthy: Bool)
    func handleMouseOverLink(_ url: String?)
}
