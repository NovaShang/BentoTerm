import BentoFilePreviewKit
import BentoFoundationKit
#if canImport(UIKit)
import UIKit
import GhosttyKit

extension GhosttyTerminalSurface {

    // MARK: - Selection

    /// Mouse position for ghostty in LOGICAL POINTS (not backing pixels).
    /// ghostty applies the surface content scale internally, so multiplying by
    /// `currentScale` double-applies it — selection landed at 2× the row on
    /// Retina (click row n → selected row 2n−1). Matches the macOS surface.
    func pxPoint(_ point: CGPoint) -> (x: Double, y: Double) {
        return (Double(point.x), Double(point.y))
    }

    // Selection logic is shared with macOS via `GhosttySel` — these are thin
    // forwarders that supply the surface handle and view-point→pixel conversion.

    /// Select the word under `point`. Returns whether a selection now exists.
    @discardableResult
    public func selectWord(at point: CGPoint) -> Bool {
        guard let surface else { return false }
        let ok = GhosttySel.selectWord(surface, px: pxPoint(point))
        setNeedsDraw()
        return ok
    }

    /// Begin a drag selection (anchor) at `point`.
    public func selectionBegin(at point: CGPoint) {
        guard let surface else { return }
        GhosttySel.begin(surface, px: pxPoint(point))
        setNeedsDraw()
    }

    /// Extend the in-progress drag selection to `point`.
    public func selectionExtend(to point: CGPoint) {
        guard let surface else { return }
        GhosttySel.extend(surface, px: pxPoint(point))
        setNeedsDraw()
    }

    /// Finish the drag selection.
    public func selectionEnd() {
        guard let surface else { return }
        GhosttySel.end(surface)
        setNeedsDraw()
    }

    public var hasSelection: Bool {
        guard let surface else { return false }
        return GhosttySel.hasSelection(surface)
    }

    /// Geometry for laying out selection handles: the selection's top-left in
    /// THIS view's points, and the cell size in points. nil if no selection.
    ///
    /// Coordinate-space trap (measured, not assumed): `ghostty_text_s.tl_px`
    /// arrives in the surface's POINT space — the same space the mouse input
    /// takes — despite the `_px` name (verified: selectWord at y=524.5 reported
    /// tl.y=524.0 on a scale-2 device). Dividing it by the content scale put
    /// the iOS selection handles at half the true offset, completely detached
    /// from the highlight ghostty renders. The cell sizes from `currentSize`
    /// ARE device pixels, so only those divide by scale.
    public func selectionGeometry() -> (topLeft: CGPoint, cell: CGSize)? {
        guard let surface, let cell = cellSize,
              let tl = GhosttySel.selectionTopLeftPx(surface) else { return nil }
        return (CGPoint(x: tl.x, y: tl.y), cell)
    }

    /// The currently selected text, or nil.
    public func selectedText() -> String? {
        guard let surface else { return nil }
        return GhosttySel.selectedText(surface)
    }

    /// Select the entire scrollback/screen via the ghostty keybind action.
    @discardableResult
    public func selectAll() -> Bool {
        guard let surface else { return false }
        let ok = GhosttySel.selectAll(surface)
        setNeedsDraw()
        return ok
    }

    /// Clear any selection (a plain left click collapses it).
    public func clearSelection(at point: CGPoint? = nil) {
        guard let surface else { return }
        GhosttySel.clear(surface, px: point.map { pxPoint($0) })
        setNeedsDraw()
    }

    /// Paste the system clipboard into the terminal at the cursor. Mirrors the
    /// macOS surface: route through ghostty's `paste_from_clipboard` action (not
    /// raw `ghostty_surface_text`) so multi-line text gets bracketed-paste
    /// wrapping — otherwise every newline fires Enter and a pasted block runs
    /// line by line (e.g. can't paste a multi-line command into Claude Code).
    /// The action pulls the text back through the runtime's `read_clipboard_cb`,
    /// which completes on the surface registered here.
    public func pasteFromClipboard() {
        guard let surface, let text = TerminalClipboard.read(), !text.isEmpty else { return }
        GhosttyRuntime.shared.pasteSurface = surface
        GhosttySel.bindingAction("paste_from_clipboard", on: surface)
        // The clipboard read completes synchronously inside the action (see
        // GhosttyRuntime.pasteSurface), so drop the registration now — a stale
        // pointer must never answer a later OSC 52 read on a freed surface.
        if GhosttyRuntime.shared.pasteSurface == surface { GhosttyRuntime.shared.pasteSurface = nil }
    }
}
#endif
