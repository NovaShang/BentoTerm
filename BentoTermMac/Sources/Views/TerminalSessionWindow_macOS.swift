#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// A session window that gives its toolbar first refusal on right-clicks.
///
/// The window strip is an `NSToolbarItemGroup` rendered by AppKit, and its
/// control eats `rightMouseDown` without consulting the `menu` property — so a
/// context menu on a window tab cannot be installed the normal way. `sendEvent`
/// sees the event before dispatch, and `self` is by construction the window
/// that received it: safe attribution without an event monitor, which is what
/// made the previous title-bar menu act on the wrong session.
final class TerminalSessionWindow: NSWindow {
    /// Returns true when the click landed on the window strip and was handled.
    var onRightClick: ((NSPoint) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown, onRightClick?(event.locationInWindow) == true { return }
        super.sendEvent(event)
    }

    /// **Every** Bento window is built here.
    @MainActor
    static func makeShell() -> TerminalSessionWindow {
        let win = TerminalSessionWindow(
            contentRect: NSRect(origin: .zero, size: TerminalWindowManager.defaultContentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        // Native window tabs: same identifier → one tab group, and AppKit hides
        // the tab bar entirely at one tab, which is why a session strip only
        // appears once there is more than one session to switch between.
        win.tabbingIdentifier = "bento.terminal"
        // `.preferred` when we're about to tab: `.automatic` defers to the
        // system preference at a moment AppKit picks, and with this window's
        // hidden title + full-size content that ended in windows joined to a
        // group whose tab bar never appeared — sessions became invisible
        // 33-pixel strips offscreen. Stating the intent avoids the ambiguity;
        // `tabbingIdentifier` is set either way, so Merge All Windows and
        // dragging a tab out still work in both modes.
        win.tabbingMode = BentoTerminalWindow.shouldOpenAsTab ? .preferred : .automatic
        win.titleVisibility = .hidden
        // Full-size content: the sidebar column runs the window's full height
        // (Finder-style) and the title bar blends into the terminal — the
        // window chrome wears the ghostty theme's background.
        win.styleMask.insert(.fullSizeContentView)
        win.titlebarAppearsTransparent = true
        win.titlebarSeparatorStyle = .none
        return win
    }
}

/// The one saved frame every Bento window shares, and who currently holds it.
///
/// Frame autosave is per WINDOW NAME, and every Bento window wants the same remembered geometry, so they would all fight over
/// one name. AppKit settles it by refusing: a second live window claiming a
/// held name silently gets nothing. Whichever window opens into an empty screen
/// therefore holds the name, and the others ride its tab group's frame.
///
/// This was a one-shot `didRestoreFrame` flag once, set on the first window of
/// the process and never cleared, so after closing every window the next one
/// got no name at all — it neither restored the size you left nor recorded the
/// one you set. Ownership is released on close now, so the next window into an
/// empty screen picks it up again.
@MainActor
enum BentoWindowFrame {
    nonisolated static let name = "BentoMainTerminalWindow"

    private static weak var owner: NSWindow?

    /// Give `win` the autosave name if nobody holds it. Returns whether `win`
    /// holds it afterwards.
    @discardableResult
    static func claim(_ win: NSWindow) -> Bool {
        if owner === win { return true }
        guard owner == nil else { return false }
        owner = win
        win.setFrameAutosaveName(name)
        return true
    }

    /// Record the arrangement the user is leaving and hand the name back.
    ///
    /// The save is unconditional. Autosave only fires on move/resize and only
    /// for the name's owner, so without this a window closed straight after a
    /// resize — or any window that isn't the owner — left nothing behind. Tabs
    /// in a group share one frame, so whichever closes last writes the same
    /// answer.
    static func release(_ win: NSWindow) {
        win.saveFrame(usingName: name)
        guard owner === win else { return }
        // Hand the name back BEFORE the window goes away: AppKit rejects a
        // second window claiming an autosave name that is still held.
        win.setFrameAutosaveName("")
        owner = nil
    }
}
#endif
