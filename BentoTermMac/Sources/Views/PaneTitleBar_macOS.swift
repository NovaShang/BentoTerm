import BentoTmuxKit
import BentoFoundationKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoAgentKit
import BentoUISharedKit

/// The thin label strip atop each pane, with zoom + menu buttons on the right.
@MainActor
final class PaneTitleBar: NSView {
    private let label = NSTextField(labelWithString: "")
    /// Leading semantic state glyph (the same play/question/check language as the
    /// List sidebar), replacing the old status dot. Empty for idle.
    private let stateIcon = NSImageView()
    let zoomButton = NSButton()
    let menuButton = NSButton()
    /// Trailing mode glyph (copy-mode / mouse reporting off). Hidden by default —
    /// "nothing unusual" must not carry a marker, same rule as idle state.
    private let modeButton = NSButton()
    var onZoom: (() -> Void)?
    var onMenu: (() -> Void)?

    var text: String = "" {
        didSet { label.stringValue = text }
    }

    /// See `PaneChrome.ModeBadge` — the badge vocabulary is shared with the iOS
    /// pane strip, which shows the same modes.
    typealias ModeBadge = PaneChrome.ModeBadge

    /// copy-mode wins when both apply: it changes what the KEYBOARD does, which
    /// is the more surprising of the two.
    var modeBadge: ModeBadge = .none {
        didSet {
            guard oldValue != modeBadge else { return }
            updateModeBadge()
            needsLayout = true
        }
    }
    var onModeBadge: (() -> Void)?

    private func updateModeBadge() {
        guard let symbol = modeBadge.symbol else {
            modeButton.isHidden = true
            return
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        modeButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: modeBadge.help)?
            .withSymbolConfiguration(cfg)
        modeButton.toolTip = modeBadge.help
        modeButton.isHidden = false
    }

    @objc private func modeTapped() { onModeBadge?() }

    /// Pane working/idle/awaiting — drives the leading state glyph (play/question)
    /// and the title-bar band color (blue / amber / green).
    var paneState: PaneState = .idle {
        didSet { updateStateIcon(); updateChrome() }
    }

    /// A coding-agent pane that finished but hasn't been looked at → "done"
    /// (green ✓ glyph + green band), distinct from a plain idle/seen pane.
    var agentFinishedUnseen: Bool = false {
        didSet { updateStateIcon(); updateChrome() }
    }

    /// "Done, unseen" green (a finished ✓). Also drives the pane's state wash +
    /// band (see PaneCellView.stateTintColor / chromeAccent). Sourced from the
    /// shared palette so the List sidebar's green check matches.
    static let doneColor = NSColor(hex: PaneState.doneUnseenHex)

    /// What this pane's chrome is announcing — the shared mapping the iOS strip
    /// and the List sidebar rows also render.
    private var status: PaneChrome.Status {
        PaneChrome.Status(state: paneState, agentFinishedUnseen: agentFinishedUnseen)
    }

    /// The leading glyph + tint for the current state.
    private func stateSymbol() -> (name: String, color: NSColor) {
        (status.symbol, NSColor(hex: status.glyphHex))
    }

    private func updateStateIcon() {
        let (name, color) = stateSymbol()
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        stateIcon.image = img
        stateIcon.contentTintColor = color
    }

    /// Accent for the band/ink: done-unseen wins, otherwise the per-state color
    /// (nil for idle → neutral chrome).
    private func chromeAccent() -> NSColor? {
        status.accentHex.map { NSColor(hex: $0) }
    }

    /// Recompute the band background + label/button ink from (state, active).
    private func updateChrome() {
        // Agent state wins the band color; otherwise a focused-but-idle pane takes
        // the window highlight color, so focus reads from the title bar too — not
        // just the border (the border alone is too quiet for an idle gray pane).
        let accent = chromeAccent() ?? (isActive ? GhosttyPaneColors.focusAccent() : nil)
        layer?.backgroundColor = PaneChromeColors.titleBand(accent: accent, active: isActive).cgColor
        let ink = PaneChromeColors.ink(accent: accent, active: isActive)
        label.textColor = ink
        zoomButton.contentTintColor = ink
        menuButton.contentTintColor = ink
        // Same ink as the rest of the bar: a mode is information, not an alarm,
        // and it must never read as one of the state colors.
        modeButton.contentTintColor = ink
    }

    /// Re-derive the band/ink CGColors on a light/dark flip (see PaneCellView).
    func recolorChrome() { updateChrome() }

    var isActive: Bool = false {
        didSet { updateChrome() }
    }

    /// Square hit target for each title-bar button.
    private static let buttonSize: CGFloat = 14

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = PaneChromeColors.titleBand(accent: nil, active: false).cgColor

        stateIcon.imageScaling = .scaleProportionallyUpOrDown
        updateStateIcon()
        addSubview(stateIcon)

        configure(zoomButton, symbol: "arrow.up.left.and.arrow.down.right",
                  fallback: "⤢", action: #selector(zoomTapped))
        configure(menuButton, symbol: "ellipsis", fallback: "⋯", action: #selector(menuTapped))
        configure(modeButton, symbol: "cursorarrow.slash", fallback: "⊘", action: #selector(modeTapped))
        modeButton.isHidden = true

        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor(white: 0.65, alpha: 1.0)
        label.lineBreakMode = .byTruncatingTail
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.cell?.usesSingleLineMode = true
        addSubview(label)

        updateChrome()
    }

    /// Manual layout (the bar's own frame is set by the parent), so the buttons
    /// sit at a fixed small size flush-right and never depend on intrinsic sizes.
    override func layout() {
        super.layout()
        let s = Self.buttonSize
        let y = ((bounds.height - s) / 2).rounded()
        let menuX = bounds.width - 6 - s
        let zoomX = menuX - 4 - s
        menuButton.frame = NSRect(x: menuX, y: y, width: s, height: s)
        zoomButton.frame = NSRect(x: zoomX, y: y, width: s, height: s)
        // Mode glyph sits leftmost in the trailing cluster, and like the other
        // buttons yields its slot to the label when there is no mode.
        var modeX = zoomX
        if modeBadge != .none {
            modeX -= 4 + s
            modeButton.frame = NSRect(x: modeX, y: y, width: s, height: s)
        }
        let chromeLeftX = modeBadge != .none ? modeX : zoomX
        // Fixed-width leading slot for the state glyph, so the title never shifts
        // as state changes (idle = empty slot, same x for the label).
        let icon: CGFloat = 13
        stateIcon.frame = NSRect(x: 8, y: ((bounds.height - icon) / 2).rounded(), width: icon, height: icon)
        let labelX = stateIcon.frame.maxX + 5
        let labelRight = chromeLeftX - 6
        // Center the label on its line height (a full-height NSTextField frame
        // top-aligns the glyphs, which looks off in a one-cell-tall strip).
        let font = label.font ?? .systemFont(ofSize: 10, weight: .medium)
        let lineH = ceil(font.ascender - font.descender + font.leading)
        let labelY = ((bounds.height - lineH) / 2).rounded()
        label.frame = NSRect(x: labelX, y: labelY, width: max(labelRight - labelX, 0), height: lineH)
    }

    private func configure(_ button: NSButton, symbol: String, fallback: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = action
        button.contentTintColor = NSColor(white: 0.65, alpha: 1.0)
        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            img.isTemplate = true
            button.image = img
        } else {
            button.imagePosition = .noImage
            button.title = fallback
            button.font = .systemFont(ofSize: 10)
        }
        addSubview(button)
    }

    @objc private func zoomTapped() { onZoom?() }
    @objc private func menuTapped() { onMenu?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // Let the buttons receive clicks, but everything else falls through to the
    // pane container (so clicking the title to focus the pane still works).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        let buttons: [NSView] = [zoomButton, menuButton]
        return buttons.contains(where: { $0 === hit }) ? hit : nil
    }
}

/// The one genuinely platform-sourced pane color — the window highlight the
/// focused pane wears. Everything else (band, ink, hairlines) is the shared
/// `PaneChromeColors`, which the iOS strip renders identically.
@MainActor
enum GhosttyPaneColors {
    static let accentNSColor = NSColor(srgbRed: 0.30, green: 0.90, blue: 0.62, alpha: 1.0)

    /// The system/window highlight color (the user's macOS accent) as a concrete
    /// sRGB color — the focus color for the active pane's border + title band.
    static func focusAccent() -> NSColor {
        NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? accentNSColor
    }

    /// Focus outline for the pane border: the window highlight color on the active
    /// pane, a near-invisible hairline otherwise — so the focused tile reads at a
    /// glance regardless of its agent state (which the title bar / dot / wash carry).
    static func focusBorder(active: Bool) -> NSColor {
        active ? focusAccent() : PaneChromeColors.idleBorder()
    }
}
#endif
