#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Overlay drawn over the terminal surface while ⌘-hovering a recognized file
/// path: a soft accent wash + underline per visual row the token crosses.
/// Hit-test transparent — all mouse events keep flowing to the surface.
final class PathHighlightView: NSView {
    var rects: [CGRect] = [] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }          // match the surface
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let accent = NSColor.controlAccentColor
        for r in rects {
            ctx.setFillColor(accent.withAlphaComponent(0.18).cgColor)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -1, dy: 0),
                               cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()
            // Underline hugs the bottom of the row — the "this is a link" cue.
            ctx.setFillColor(accent.withAlphaComponent(0.9).cgColor)
            ctx.fill(CGRect(x: r.minX, y: r.maxY - 1.5, width: r.width, height: 1.5))
        }
    }
}
#endif
