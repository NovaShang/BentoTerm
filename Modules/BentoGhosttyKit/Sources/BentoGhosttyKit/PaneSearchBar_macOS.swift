#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoFoundationKit

/// Find bar for one pane's scrollback (⌘F). Floats over the TOP-RIGHT of the
/// surface and deliberately never reflows it: the surface's pixel size IS the
/// tmux grid, so pushing content aside to make room would resize the pane,
/// SIGWINCH the program inside it, and repaint the whole screen — to show a text
/// field. Overlaying is also what every modern find affordance does (Safari,
/// Chrome, VS Code), so it needs no explanation.
///
/// Scope note: this searches ONE pane, which is why it lives on the pane and not
/// in the toolbar. The toolbar's omnibox is app-scoped (commands / files /
/// sessions / windows / panes); two different scopes get two different homes.
///
/// The engine owns the actual search — match highlighting, the hit cursor, and
/// the counts all come from libghostty. This view only supplies the needle and
/// displays what comes back.
@MainActor
final class PaneSearchBar: NSView, NSTextFieldDelegate {

    /// Shared find-bar state — debounce, counts, callbacks. The surface wires
    /// `onQueryChanged`/`onNext`/`onPrevious`/`onClose`; the count label tracks
    /// `onCountsChanged` (see SearchBarModel).
    let model = SearchBarModel()

    private let background = NSVisualEffectView()
    private let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    static let barHeight: CGFloat = 30
    /// Preferred width. A pane narrower than this gets the full width instead
    /// (minus the inset), so the bar never overhangs its own pane.
    static let preferredWidth: CGFloat = 320
    static let inset: CGFloat = 8

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(background)

        // SF Pro, not mono: this is chrome, and what you type here is a query,
        // not something headed into the terminal.
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "Find"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        addSubview(field)

        // The one place mono is honest here — it's a number that changes as you
        // navigate, and a proportional font makes it jitter.
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        addSubview(count)

        model.onCountsChanged = { [weak self] text in
            guard let self else { return }
            self.count.stringValue = text ?? ""
            self.layoutCount()
        }

        configure(prevButton, symbol: "chevron.up", description: "Previous match",
                  action: #selector(previousTapped))
        configure(nextButton, symbol: "chevron.down", description: "Next match",
                  action: #selector(nextTapped))
        configure(closeButton, symbol: "xmark", description: "Close find bar",
                  action: #selector(closeTapped))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure(_ button: NSButton, symbol: String, description: String,
                           action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = description
        button.target = self
        button.action = action
        addSubview(button)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        background.frame = bounds
        let pad: CGFloat = 6
        let buttonW: CGFloat = 22
        var x = bounds.width - pad
        for button in [closeButton, nextButton, prevButton] {
            x -= buttonW
            button.frame = NSRect(x: x, y: 0, width: buttonW, height: bounds.height)
        }
        let countW = max(count.intrinsicContentSize.width, 8)
        x -= countW + 6
        count.frame = NSRect(x: x, y: (bounds.height - 14) / 2, width: countW, height: 14)
        let fieldX = pad + 2
        field.frame = NSRect(x: fieldX, y: (bounds.height - 17) / 2,
                             width: max(0, x - fieldX - 6), height: 17)
    }

    /// Frame for this bar inside a surface of `size`, honoring the inset and
    /// degrading to full width in a narrow pane.
    static func frame(in size: NSSize) -> NSRect {
        let width = min(preferredWidth, max(0, size.width - inset * 2))
        return NSRect(x: size.width - inset - width, y: inset,
                      width: width, height: barHeight)
    }

    // MARK: - State

    private func layoutCount() {
        count.sizeToFit()
        needsLayout = true
    }

    /// Put the caret in the field. The bar takes first responder while it is
    /// open — this is the one moment Bento holds keys back from the terminal, so
    /// the field is visibly focused and Esc always gives them back.
    func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Whether the field (or its field editor) currently holds first responder.
    var fieldHasFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === field { return true }
        if let textView = responder as? NSTextView, textView.delegate === field { return true }
        return false
    }

    // MARK: - Actions

    @objc private func previousTapped() { model.onPrevious?() }
    @objc private func nextTapped() { model.onNext?() }
    @objc private func closeTapped() { model.onClose?() }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        model.queryChanged(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            model.onClose?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Both Return and ⇧Return arrive as insertNewline:, so the modifier
            // has to be read off the live event.
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            // Flush any pending keystroke first, or the first Return navigates
            // the previous needle's results.
            model.flushPendingQuery(field.stringValue)
            if shift { model.onPrevious?() } else { model.onNext?() }
            return true
        case #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertBacktab(_:)):
            // Don't let Tab walk the responder chain out of the bar.
            return true
        default:
            return false
        }
    }
}
#endif
