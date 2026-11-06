import BentoTmuxKit
import BentoFoundationKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoAgentKit
import BentoUISharedKit

// MARK: - Pane container (title bar + terminal surface)

/// A passive color wash over the terminal surface that signals pane state
/// (working / awaiting / done). Hit-test transparent so it never steals mouse
/// events from the surface — selection, link clicks, and title-bar drag-to-swap
/// all keep working underneath it.
@MainActor
final class PaneStateTintView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class PaneCellView: NSView {
    var onClick: (() -> Void)?
    /// Fired while the title bar is dragged beyond the click slop — the
    /// drag-to-dock gesture. Clicks under the threshold stay clicks.
    var onPaneDrag: ((PaneDrag.Phase) -> Void)?
    var onZoom: (() -> Void)? {
        didSet { titleBar.onZoom = onZoom }
    }
    var onMenu: (() -> Void)? {
        didSet { titleBar.onMenu = onMenu }
    }
    private let titleBar = PaneTitleBar()
    private let stateTint = PaneStateTintView()
    private weak var surface: NSView?

    /// Title-strip height (points). Set to one character cell so the strip fits
    /// exactly in tmux's divider row between stacked panes (see the host's native
    /// layout). The host updates it as the font/cell size changes.
    var titleBarHeight: CGFloat = 20 {
        didSet { needsLayout = true }
    }

    /// Horizontal inset (points) of the surface inside the container. The host
    /// grows each container half a cell into the divider column on each side so
    /// adjacent panes meet (and their borders/highlight land) on the divider
    /// centerline — no visible gap. The surface stays at its exact cell size,
    /// inset by this much so its content keeps its true position.
    var surfaceInsetX: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    /// The button the per-pane menu should anchor to.
    var menuButtonAnchor: NSView { titleBar.menuButton }

    var title: String = "" {
        didSet { titleBar.text = title }
    }

    var paneState: PaneState = .idle {
        didSet { titleBar.paneState = paneState; updateStateTint(); applyBorder() }
    }

    /// Trailing mode glyph — see `PaneTitleBar.ModeBadge`.
    var modeBadge: PaneTitleBar.ModeBadge = .none {
        didSet { titleBar.modeBadge = modeBadge }
    }
    var onModeBadge: (() -> Void)? {
        didSet { titleBar.onModeBadge = onModeBadge }
    }

    var agentFinishedUnseen: Bool = false {
        didSet { titleBar.agentFinishedUnseen = agentFinishedUnseen; updateStateTint(); applyBorder() }
    }

    /// Translucent wash over the surface that mirrors the title-bar glyph
    /// (nil = idle = no wash) — the shared `PaneChrome.Status` table.
    private func stateTintColor() -> NSColor? {
        PaneChromeColors.wash(PaneChrome.Status(state: paneState,
                                                agentFinishedUnseen: agentFinishedUnseen))
    }

    private func updateStateTint() {
        let cg = stateTintColor()?.cgColor
        // Cross-fade so state changes don't pop. AppKit disables implicit
        // animations on layer-backed views, so add the transition explicitly;
        // with no fromValue it animates from the current presentation color.
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.duration = 0.25
        stateTint.layer?.add(anim, forKey: "tint")
        stateTint.layer?.backgroundColor = cg
    }

    var isActivePane: Bool = false {
        didSet {
            applyBorder()
            titleBar.isActive = isActivePane
        }
    }

    /// When only one pane is on screen (a single pane, or a zoomed pane), there's
    /// nothing to disambiguate — hide the focus border so it isn't just noise.
    var focusSuppressed: Bool = false {
        didSet {
            guard oldValue != focusSuppressed else { return }
            applyBorder()
        }
    }

    private func applyBorder() {
        // The border is purely the FOCUS cue: the window highlight color on the
        // pane you're interacting with, a near-invisible hairline on the rest.
        // Suppressed when there's only one pane visible (nothing to focus).
        // Agent state stays on the title bar + status dot + body wash, so the
        // focus ring never competes with green/amber/blue. (Drop targets are
        // previewed by the host's PaneDropZoneOverlay, not the border.)
        let showFocus = isActivePane && !focusSuppressed
        layer?.borderWidth = showFocus ? 2.0 : 0.5
        let color = GhosttyPaneColors.focusBorder(active: showFocus)
        // Resolve the dynamic accent against this view's light/dark appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = color.cgColor
        }
    }

    /// Re-derive every appearance-dependent CGColor (border + title-bar band/ink).
    /// CGColors are static snapshots, so this must run on a light/dark flip.
    func recolorChrome() {
        applyBorder()
        titleBar.recolorChrome()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Clip to the container in case the surface rounds a fraction of a pixel
        // past the edge.
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = PaneChromeColors.neutralHairline().cgColor
        addSubview(titleBar)

        // State wash sits above the terminal surface (added in `embed`) but below
        // the title bar, so the dot + label stay crisp while the terminal body
        // takes the tint. Hit-test transparent (see PaneStateTintView).
        stateTint.wantsLayer = true
        addSubview(stateTint, positioned: .below, relativeTo: titleBar)
        updateStateTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func embed(_ view: NSView) {
        surface = view
        // Keep the surface beneath the state wash so the tint overlays the
        // terminal content (not the other way around).
        addSubview(view, positioned: .below, relativeTo: stateTint)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = titleBarHeight
        titleBar.isHidden = (h <= 0)   // Focus mode: no pane chrome at all
        titleBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        // The surface keeps its exact cell size (= bounds minus the half-cell the
        // host added on each side, and minus the title bar), inset by surfaceInsetX
        // so its content stays put while the container reaches the divider midline.
        let surfaceRect = NSRect(x: surfaceInsetX, y: h,
                                 width: max(bounds.width - 2 * surfaceInsetX, 0),
                                 height: max(bounds.height - h, 0))
        surface?.frame = surfaceRect
        stateTint.frame = surfaceRect
        layoutDevServerChip(in: surfaceRect)
    }

    // MARK: Dev-server offer

    private var devServerChip: DevServerChipView?

    /// A server came up in this pane. Offer it — do not open it.
    ///
    /// Opening on its own would take the side panel away from whatever the user
    /// was looking at, and `vite` reprints this banner on every restart, which
    /// an agent triggers all day. One tap is the whole cost of being sure.
    func offerDevServer(port: Int, onOpen: @escaping () -> Void) {
        devServerChip?.removeFromSuperview()
        let chip = DevServerChipView(port: port, onOpen: onOpen)
        chip.onDismiss = { [weak self] in
            self?.devServerChip?.removeFromSuperview()
            self?.devServerChip = nil
        }
        devServerChip = chip
        addSubview(chip)
        needsLayout = true
        chip.fadeIn()
    }

    private func layoutDevServerChip(in surfaceRect: NSRect) {
        guard let chip = devServerChip else { return }
        let size = chip.fittingSize
        chip.frame = NSRect(
            x: max(surfaceRect.minX, surfaceRect.maxX - size.width - 10),
            y: max(surfaceRect.minY, surfaceRect.maxY - size.height - 10),
            width: size.width, height: size.height)
    }

    // MARK: Title-bar drag (drag-to-swap)
    //
    // Mouse events only reach this view from the title bar (minus its buttons)
    // and the thin border slivers — the surface subview consumes everything
    // else — so a drag here is unambiguously "drag the pane", never text
    // selection or divider resize.
    private var dragPending = false
    private var dragActive = false
    private var dragStart: NSPoint = .zero
    private static let dragSlop: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        onClick?()
        dragPending = true
        dragActive = false
        dragStart = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragPending else {
            super.mouseDragged(with: event)
            return
        }
        let p = event.locationInWindow
        if !dragActive, hypot(p.x - dragStart.x, p.y - dragStart.y) > Self.dragSlop {
            dragActive = true
            onPaneDrag?(.began)
        }
        if dragActive {
            onPaneDrag?(.moved(p))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragActive {
            onPaneDrag?(.ended(event.locationInWindow))
        }
        dragPending = false
        dragActive = false
        super.mouseUp(with: event)
    }
}

// MARK: - Dev-server offer chip

/// "A server just came up in this pane — want to see it?"
///
/// Deliberately an offer and not an action: the side panel may be showing
/// something the user is in the middle of, and a dev server reprints its banner
/// on every restart. It fades itself out, because an offer nobody took should
/// not stay on screen.
private final class DevServerChipView: NSView {
    var onDismiss: (() -> Void)?
    private let onOpen: () -> Void
    private let label = NSTextField(labelWithString: "")
    /// `nonisolated(unsafe)` so `deinit` can invalidate it: the chip is only
    /// ever touched on the main thread, and letting the timer outlive the view
    /// would fire `fadeOut` on a dead one.
    private nonisolated(unsafe) var timer: Timer?

    /// Long enough to notice while reading output scroll past, short enough
    /// that it is gone before it becomes furniture.
    private static let lifetime: TimeInterval = 12

    init(port: Int, onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.92).cgColor

        label.stringValue = "Open :\(port)"
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        addSubview(label)

        timer = Timer.scheduledTimer(withTimeInterval: Self.lifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { timer?.invalidate() }

    override var fittingSize: NSSize {
        NSSize(width: label.frame.width + 22, height: 22)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 11, y: (bounds.height - label.frame.height) / 2,
                             width: label.frame.width, height: label.frame.height)
    }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        timer?.invalidate()
        onOpen()
        onDismiss?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func fadeIn() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.onDismiss?()
        }
    }
}
#endif
