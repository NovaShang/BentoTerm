#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

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

    /// Fires (debounced) as the user types. Empty string = clear the search.
    var onQueryChanged: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let background = NSVisualEffectView()
    private let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    private var debounce: DispatchWorkItem?

    /// Typing must not fire a search per keystroke — each one walks the whole
    /// scrollback in the engine. Short enough to still feel live.
    private static let debounceMs = 120

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

    /// `total` / `selected` as libghostty reports them (nil = the engine sent -1,
    /// meaning "none"). `selected` is the engine's index into the match list, so
    /// it is displayed +1.
    func setCounts(total: Int?, selected: Int?) {
        guard !field.stringValue.isEmpty else {
            count.stringValue = ""
            layoutCount()
            return
        }
        let totalCount = total ?? 0
        if totalCount == 0 {
            count.stringValue = "0/0"
        } else if let selected, selected >= 0 {
            count.stringValue = "\(selected + 1)/\(totalCount)"
        } else {
            count.stringValue = "–/\(totalCount)"
        }
        layoutCount()
    }

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

    func cancelPendingQuery() {
        debounce?.cancel()
        debounce = nil
    }

    // MARK: - Actions

    @objc private func previousTapped() { onPrevious?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func closeTapped() { onClose?() }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        debounce?.cancel()
        let text = field.stringValue
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounce = nil
            self.onQueryChanged?(text)
            // An empty field has no counts to show.
            if text.isEmpty { self.setCounts(total: nil, selected: nil) }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.debounceMs),
                                      execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Both Return and ⇧Return arrive as insertNewline:, so the modifier
            // has to be read off the live event.
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            // Flush any pending keystroke first, or the first Return navigates
            // the previous needle's results.
            flushPendingQuery()
            if shift { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertBacktab(_:)):
            // Don't let Tab walk the responder chain out of the bar.
            return true
        default:
            return false
        }
    }

    private func flushPendingQuery() {
        guard let work = debounce else { return }
        work.cancel()
        debounce = nil
        onQueryChanged?(field.stringValue)
    }
}
#endif
