import BentoFoundationKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Bottom bar for scroll-review-compose (macOS). Display-only — it never becomes
/// first responder; the surface owns all key routing and pushes state here. Two
/// looks: a low-key hint while the draft is empty (REVIEW_IDLE) and the live
/// draft text + caret while composing (REVIEW_DRAFT).
final class ComposeBarView: NSView {

    /// Terminal-matching monospaced font for draft text (it's literally headed
    /// into the terminal, so mono is honest here). Set by the surface.
    var monoFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { needsDisplay = true }
    }

    private var isHint = true
    private var before = ""
    private var preedit = ""
    private var after = ""

    private var caretOn = true
    private var blinkTimer: Timer?

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Empty-draft hint look.
    func showHint() {
        isHint = true
        before = ""; preedit = ""; after = ""
        stopBlink()
        needsDisplay = true
    }

    /// Draft look. `before`/`after` straddle the caret; `preedit` is the in-flight
    /// IME composition rendered (underlined) at the caret.
    func showDraft(before: String, preedit: String, after: String) {
        isHint = false
        self.before = before
        self.preedit = preedit
        self.after = after
        startBlink()
        needsDisplay = true
    }

    private func startBlink() {
        guard blinkTimer == nil else { return }
        caretOn = true
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.caretOn.toggle()
            self.needsDisplay = true
        }
    }

    private func stopBlink() {
        blinkTimer?.invalidate(); blinkTimer = nil
        caretOn = true
    }

    deinit { blinkTimer?.invalidate() }

    // MARK: Drawing

    private let pad: CGFloat = 10
    private let accent = NSColor(calibratedRed: 0.30, green: 0.72, blue: 0.78, alpha: 1.0)
    // Appearance-aware ink/background: the draft bar sits over the terminal, so it
    // tracks the app's light/dark like the rest of the pane chrome.
    private var isDark: Bool { ThemeStore.shared.effectiveIsDark }
    private var labelColor: NSColor {
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.45)
    }
    private var textColor: NSColor {
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.95)
    }
    private var fillColor: NSColor {
        isDark ? NSColor(calibratedWhite: 0.07, alpha: 0.92)
               : NSColor(calibratedWhite: 0.97, alpha: 0.94)
    }

    /// Flatten newlines for the single-line bar (the real draft keeps them).
    private func flat(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ↵ ") }

    override func draw(_ dirtyRect: NSRect) {
        // Background + top hairline.
        fillColor.setFill()
        bounds.fill()
        accent.withAlphaComponent(0.9).setFill()
        NSRect(x: 0, y: bounds.height - 1.5, width: bounds.width, height: 1.5).fill()

        let baselineY = (bounds.height - monoFont.ascender + monoFont.descender) / 2

        if isHint {
            let label = NSAttributedString(string: "⌨  Type to draft · ⏎ send · Esc dismiss", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: labelColor,
            ])
            let h = label.size().height
            label.draw(at: NSPoint(x: pad, y: (bounds.height - h) / 2))
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [.font: monoFont, .foregroundColor: textColor]
        var x = pad

        let beforeStr = NSAttributedString(string: flat(before), attributes: attrs)
        beforeStr.draw(at: NSPoint(x: x, y: baselineY))
        x += beforeStr.size().width

        // Caret.
        if caretOn {
            accent.setFill()
            NSRect(x: x, y: baselineY, width: 2, height: monoFont.ascender).fill()
        }

        if !preedit.isEmpty {
            let pre = NSAttributedString(string: flat(preedit), attributes: [
                .font: monoFont,
                .foregroundColor: textColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
            pre.draw(at: NSPoint(x: x, y: baselineY))
            x += pre.size().width
        }

        let afterStr = NSAttributedString(string: flat(after), attributes: attrs)
        afterStr.draw(at: NSPoint(x: x, y: baselineY))
    }
}
#endif
