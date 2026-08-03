#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoFoundationKit

/// A small transient message that floats near the bottom of a pane and fades
/// itself out. It exists for one job: explain a failure AT THE MOMENT IT
/// HAPPENS, where the user is already looking.
///
/// Used when a pane silently refuses to do the obvious thing — dragging to
/// select in a pane whose program has grabbed the mouse, typing into a pane that
/// tmux has put in copy-mode. Those are the cases where the terminal looks
/// broken rather than busy, and a chip beats any amount of documentation.
///
/// Chrome, not terminal: SF Pro and a material background. (Key names like ⇧
/// are glyphs, not mono cosplay.)
@MainActor
final class PaneHintChip: NSView {

    private let background = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    nonisolated(unsafe) private var dismissWork: DispatchWorkItem?

    override var isFlipped: Bool { true }
    /// Never steal the mouse — the gesture that triggered this chip is usually
    /// still in flight underneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        addSubview(background)

        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        background.frame = bounds
        label.frame = bounds.insetBy(dx: 10, dy: 0)
        label.frame.origin.y = (bounds.height - label.intrinsicContentSize.height) / 2
        label.frame.size.height = label.intrinsicContentSize.height
    }

    /// Show `text` centred near the bottom of `host`, then fade out.
    /// Re-showing while visible just restarts the timer with the new text.
    static func show(_ text: String, in host: NSView, for seconds: TimeInterval = 3.2) {
        let chip = (host.subviews.compactMap { $0 as? PaneHintChip }.first) ?? {
            let c = PaneHintChip(frame: .zero)
            host.addSubview(c)
            return c
        }()
        chip.present(text, in: host, for: seconds)
    }

    /// Remove any chip currently shown in `host`.
    static func dismiss(in host: NSView) {
        host.subviews.compactMap { $0 as? PaneHintChip }.forEach { $0.finish() }
    }

    private func present(_ text: String, in host: NSView, for seconds: TimeInterval) {
        dismissWork?.cancel()
        label.stringValue = text
        label.sizeToFit()

        let width = min(host.bounds.width - 24, label.intrinsicContentSize.width + 24)
        let height: CGFloat = 26
        // isFlipped hosts put y = 0 at the top, so "near the bottom" is max-y.
        let y = host.isFlipped ? host.bounds.height - height - 16 : 16
        frame = NSRect(x: (host.bounds.width - width) / 2, y: y, width: width, height: height)
        needsLayout = true

        alphaValue = 0
        isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.finish() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func finish() {
        dismissWork?.cancel()
        dismissWork = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.removeFromSuperview()
        }
    }

    deinit { dismissWork?.cancel() }
}
#endif
