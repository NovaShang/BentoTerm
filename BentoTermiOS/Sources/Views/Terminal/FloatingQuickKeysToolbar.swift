import UIKit
import BentoSessionKit
import BentoFoundationKit
import BentoGhosttyKit

/// Floating control strip for the active pane. Carries the agent-prompt nav
/// keys (↑ ↓ ↵ Esc) and — for tmux panes — the pane menu that used to live in
/// the title bar. In tiled mode the title bar is only one character cell tall,
/// too short to host touch targets, so these moved here.
///
/// Rendered as a Liquid Glass capsule (`UIGlassEffect`, iOS 26+); older systems
/// fall back to an opaque Bento card. The host docks it **just below the active
/// pane**, right-aligned: in non-fullscreen it reserves a dedicated band in
/// `pageRect` (`reservedBand`) so the bar never overlaps the terminal grid; in
/// fullscreen it floats OVER the pane content instead — clamped just above the
/// home-indicator strip for the bottom-most / full-screen pane, or over the
/// neighbour below for a non-bottom tiled pane (the keys belong to the active
/// pane). `reservedBand` also serves as the voice compass's bottom edge clamp.
/// Collapse is a bar-internal state: the bar folds sideways into a
/// perfect-circle chevron (smaller occlusion) but never changes the band — the
/// host's layout is untouched. Hidden while the keyboard is up, where the
/// docked key bar takes over.
final class FloatingQuickKeysToolbar: UIView {

    // MARK: - Public API

    var onKeyTap: ((AccessoryKey) -> Void)?

    /// The pane-menu button — the host sets `.menu` to the active pane's menu
    /// (Find / Maximize / Paste / Split / Profile / Close). Shown only when
    /// `showsPaneActions`.
    let menuButton = UIButton(type: .system)

    /// Show the pane-menu button. False for a non-tmux single pane, which has
    /// no pane menu.
    var showsPaneActions: Bool = false {
        didSet { if oldValue != showsPaneActions { rebuild() } }
    }

    /// Collapsed: the bar folds sideways into a perfect-circle chevron (tap to
    /// unfold back). A bar-internal state — the host's reserved band and grid
    /// are untouched, only the bar's own geometry changes.
    var isCollapsed: Bool = false {
        didSet {
            guard oldValue != isCollapsed else { return }
            // Cross-fade the capsule contents; the width change lands on the
            // host's next re-position (never a layout pass — the grid must not
            // move for a collapse).
            UIView.transition(with: contentHost, duration: 0.15,
                              options: [.transitionCrossDissolve]) { self.rebuild() }
        }
    }

    /// Fired on the collapse/expand tap with the NEW value. The host persists
    /// it and re-positions (the frame's width changed; layout is unaffected).
    var onCollapseToggle: ((Bool) -> Void)?

    // MARK: - Layout constants

    static let toolbarHeight: CGFloat = 38
    static let edgeGap: CGFloat = 10

    private static let buttonWidth: CGFloat = 48
    private static let buttonSpacing: CGFloat = 0

    // MARK: - Keys

    /// Minimal set tuned for agent prompt navigation: arrows step through
    /// option lists, Enter confirms, Esc dismisses. Tab and paste moved off
    /// the bar (2026-08-02 user decision — the bar was longer than the
    /// screen); paste lives in the pane menu, Tab was dropped.
    private static let keys: [Spec] = [
        .symbol(.up, system: "arrow.up"),
        .symbol(.down, system: "arrow.down"),
        .symbol(.enter, system: "return"),
        .text(.escape, label: "Esc"),
    ]

    private enum Spec {
        case symbol(AccessoryKey, system: String)
        case text(AccessoryKey, label: String)

        var key: AccessoryKey {
            switch self {
            case .symbol(let k, _), .text(let k, _): return k
            }
        }
    }

    // MARK: - Subviews

    /// Opaque fallback capsule for iOS < 26 (no Liquid Glass).
    private let card = UIView()
    /// Liquid Glass capsule on iOS 26+. When present, its `contentView` hosts the
    /// stack + separators; otherwise `card` does. See `contentHost`.
    private var glassView: UIVisualEffectView?
    /// The view that hosts the key stack + separators — glass `contentView` or card.
    private var contentHost: UIView { glassView?.contentView ?? card }
    private let stack = UIStackView()
    /// Collapse / expand chevron — persistent across rebuilds; its icon and
    /// presence depend on `isCollapsed`.
    private let collapseButton = UIButton(type: .system)
    /// Hairlines between buttons, rebuilt with the stack.
    private var separators: [UIView] = []

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        setupViews()
        applyAppearance()
        // Follow the app's light/dark choice (system or the Settings override).
        // `.terminalThemeChanged` fires on both an appearance-mode change and a
        // system flip while in follow-system mode — without this the bar kept its
        // launch appearance when the user switched light/dark.
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyAppearance),
            name: .terminalThemeChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Pin this view's trait to the app's effective appearance so every dynamic
    /// color (glass, card background, separators) resolves to the right side —
    /// works even though the bar is docked outside the main SwiftUI hierarchy.
    /// Setting this flips the trait, so the existing `traitCollectionDidChange`
    /// re-resolves the card's CGColor border.
    @objc private func applyAppearance() {
        overrideUserInterfaceStyle = ThemeStore.shared.effectiveIsDark ? .dark : .light
    }

    private func setupViews() {
        backgroundColor = .clear

        // Background: Liquid Glass capsule on iOS 26+, opaque Bento card below.
        // `host` is where the key stack + separators live.
        let host = installBackground()

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = Self.buttonSpacing
        host.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])

        configureActionButtons()
        rebuild()
    }

    /// Install the capsule background and return the view that hosts the key
    /// stack. iOS 26 gets a translucent Liquid Glass capsule so the terminal
    /// content stays legible beneath the island; older systems keep the opaque
    /// Bento card with its 1px border.
    private func installBackground() -> UIView {
        let radius = Self.toolbarHeight / 2
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = true
            let effectView = UIVisualEffectView(effect: glass)
            effectView.translatesAutoresizingMaskIntoConstraints = false
            effectView.layer.cornerRadius = radius
            effectView.clipsToBounds = true
            addSubview(effectView)
            pin(effectView)
            glassView = effectView
            return effectView.contentView
        } else {
            card.translatesAutoresizingMaskIntoConstraints = false
            card.backgroundColor = BentoBrand.surface
            card.layer.borderColor = BentoBrand.border.cgColor
            card.layer.borderWidth = 1
            card.layer.cornerRadius = radius
            card.clipsToBounds = true
            addSubview(card)
            pin(card)
            return card
        }
    }

    /// Pin a subview to fill the toolbar.
    private func pin(_ v: UIView) {
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// Configure the persistent menu + collapse buttons (reused across rebuilds).
    private func configureActionButtons() {
        menuButton.configuration = symbolConfig("ellipsis")
        applyButtonStyle(menuButton)
        menuButton.showsMenuAsPrimaryAction = true
        // Stable hook for UI tests — the nav bar has its own "More" ellipsis,
        // so the accessibility text alone is ambiguous.
        menuButton.accessibilityIdentifier = "pane-menu"

        // NO 48pt min width: the collapsed state is a 38×38 circle, and the
        // button must fit inside it (the stack's fillEqually stretches it).
        collapseButton.configuration = symbolConfig("chevron.right")
        applyButtonStyle(collapseButton, minWidth: nil)
        collapseButton.accessibilityLabel = "Collapse quick keys"
        collapseButton.addAction(UIAction { [weak self] _ in self?.collapseTapped() },
                                 for: .touchUpInside)
    }

    /// Rebuild the stack from the nav keys plus, when enabled, the pane menu.
    /// Cheap and infrequent (only when the mode flips).
    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        separators.forEach { $0.removeFromSuperview() }
        separators.removeAll()

        // Collapsed: a single chevron in a perfect circle (the bar's height
        // is its diameter — see `layoutFittingSize`), nothing else — the tap
        // that made it small is the one that unfolds it again.
        if isCollapsed {
            collapseButton.configuration = symbolConfig("chevron.left")
            collapseButton.accessibilityLabel = "Expand quick keys"
            stack.addArrangedSubview(collapseButton)
            invalidateIntrinsicContentSize()
            return
        }

        // The bar folds sideways — right-aligned, so its left end retracts
        // toward the right anchor (chevron.right); the circle unfolds back
        // toward the left (chevron.left above).
        collapseButton.configuration = symbolConfig("chevron.right")
        collapseButton.accessibilityLabel = "Collapse quick keys"

        var items: [UIView] = Self.keys.map { makeKeyButton(spec: $0) }
        let actionStart = items.count
        if showsPaneActions {
            items.append(menuButton)
        }
        items.append(collapseButton)

        for (index, btn) in items.enumerated() {
            stack.addArrangedSubview(btn)
            guard index > 0 else { continue }
            // A slightly stronger divider marks the nav-keys ↔ pane-actions seam.
            addSeparator(before: btn, strong: index == actionStart)
        }
        invalidateIntrinsicContentSize()
    }

    private func addSeparator(before btn: UIView, strong: Bool) {
        let sep = UIView()
        sep.backgroundColor = UIColor.bentoDynamic(
            light: UIColor(white: 0, alpha: strong ? 0.14 : 0.06),
            dark:  UIColor(white: 1, alpha: strong ? 0.14 : 0.06))
        sep.translatesAutoresizingMaskIntoConstraints = false
        let host = contentHost
        host.addSubview(sep)
        separators.append(sep)
        let inset: CGFloat = strong ? 6 : 8
        NSLayoutConstraint.activate([
            sep.widthAnchor.constraint(equalToConstant: 0.5),
            sep.topAnchor.constraint(equalTo: host.topAnchor, constant: inset),
            sep.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -inset),
            sep.leadingAnchor.constraint(equalTo: btn.leadingAnchor),
        ])
    }

    // MARK: - Button factory

    private func symbolConfig(_ name: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = BentoBrand.inkPrimary
        config.background.backgroundColor = .clear
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        let symConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        config.image = UIImage(systemName: name, withConfiguration: symConfig)
        config.preferredSymbolConfigurationForImage = symConfig
        return config
    }

    /// Shared highlight + minimum-width styling for every button. `minWidth`
    /// nil = no width floor (the collapse button, which must fit a 38pt circle).
    private func applyButtonStyle(_ btn: UIButton, minWidth: CGFloat? = FloatingQuickKeysToolbar.buttonWidth) {
        if let minWidth {
            btn.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
        }
        btn.configurationUpdateHandler = { button in
            var updated = button.configuration
            updated?.background.backgroundColor = button.isHighlighted
                ? BentoBrand.surfaceHi
                : .clear
            button.configuration = updated
        }
    }

    private func makeKeyButton(spec: Spec) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = BentoBrand.inkPrimary
        config.background.backgroundColor = .clear
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)

        switch spec {
        case .symbol(_, let name):
            let symConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            config.image = UIImage(systemName: name, withConfiguration: symConfig)
            config.preferredSymbolConfigurationForImage = symConfig
        case .text(_, let label):
            config.title = label
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var attrs = incoming
                attrs.font = .systemFont(ofSize: 14, weight: .semibold)
                return attrs
            }
        }

        let btn = UIButton(configuration: config)
        applyButtonStyle(btn)

        let key = spec.key
        btn.addAction(UIAction { [weak self] _ in
            self?.onKeyTap?(key)
        }, for: .touchUpInside)

        return btn
    }

    @objc private func collapseTapped() {
        let next = !isCollapsed
        isCollapsed = next            // didSet → rebuild() (cross-faded)
        onCollapseToggle?(next)
    }

    // MARK: - Positioning

    /// Vertical gap between the active pane's bottom edge and the toolbar.
    static let paneGap: CGFloat = 6
    /// Gap kept below the toolbar, above the safe-area bottom.
    static let bottomGap: CGFloat = 6
    /// Inset of the toolbar's right edge from the pane's right edge.
    private static let rightInset: CGFloat = 8

    /// Band the host reserves for the bar in `pageRect` while non-fullscreen
    /// (the bar docks inside it, never over the grid). Also the height the
    /// voice compass clears at the bottom of the page so its down target
    /// doesn't land on the bar.
    static var reservedBand: CGFloat { toolbarHeight + paneGap + bottomGap }

    /// Frame in `containerBounds`'s space: **right-aligned to the pane and
    /// floated just below its bottom edge**, over the content. The host passes
    /// `containerBounds` with the home-indicator strip already cut off, so the
    /// clamp keeps the toolbar above it; for a non-bottom tiled pane it sits
    /// over the neighbour below (by design). Clamped to stay on screen.
    func computeFrame(paneFrame: CGRect, containerBounds: CGRect) -> CGRect {
        let intrinsicW = max(intrinsicContentSize.width, layoutFittingSize().width)
        let size = CGSize(width: intrinsicW, height: Self.toolbarHeight)
        let edge = Self.edgeGap

        // Right-aligned to the pane, clamped on screen.
        let desiredX = paneFrame.maxX - size.width - Self.rightInset
        let minX = containerBounds.minX + edge
        let maxX = containerBounds.maxX - size.width - edge
        let x = max(minX, min(maxX, desiredX))

        // Docked just below the pane's bottom edge; never past the usable bottom.
        let desiredY = paneFrame.maxY + Self.paneGap
        let y = min(desiredY, containerBounds.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Update the frame, animated on a 200ms ease-out curve.
    func updatePosition(paneFrame: CGRect, containerBounds: CGRect, animated: Bool) {
        let frame = computeFrame(paneFrame: paneFrame, containerBounds: containerBounds)
        let apply = { self.frame = frame }
        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut, animations: apply)
        } else {
            apply()
        }
    }

    // MARK: - Sizing

    override var intrinsicContentSize: CGSize {
        let fitted = layoutFittingSize()
        return CGSize(width: fitted.width, height: Self.toolbarHeight)
    }

    private func layoutFittingSize() -> CGSize {
        // Collapsed: a perfect circle — width == height == the bar height,
        // matching the capsule's existing cornerRadius (height/2).
        if isCollapsed {
            return CGSize(width: Self.toolbarHeight, height: Self.toolbarHeight)
        }
        stack.layoutIfNeeded()
        let buttonsW = stack.arrangedSubviews.reduce(CGFloat(0)) { acc, view in
            acc + max(view.intrinsicContentSize.width,
                      view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width,
                      Self.buttonWidth)
        }
        let total = buttonsW + CGFloat(max(0, stack.arrangedSubviews.count - 1)) * Self.buttonSpacing
        return CGSize(width: total, height: Self.toolbarHeight)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Refresh CGColor on appearance changes — UIColor extensions don't
        // auto-resolve when written into layer properties. Only the opaque
        // fallback card has a border; the glass capsule adapts on its own.
        if glassView == nil {
            card.layer.borderColor = BentoBrand.border.cgColor
        }
    }
}

// MARK: - Find bar

/// Find-in-scrollback bar for the active pane (the touch counterpart of the
/// Mac's ⌘F bar). Same floating-chrome family as the quick-keys toolbar above:
/// Liquid Glass capsule on iOS 26+, Bento card below.
///
/// It docks at the BOTTOM, just above the keyboard, rather than floating over
/// the top-right the way the Mac one does. Two reasons, both about touch:
/// typing a needle raises the keyboard, so the field has to live where the
/// keyboard leaves room; and the bottom strip is where iOS users already look
/// for find (Safari puts it there). The host positions it — see
/// `PaneContainerVC.positionFindBar` — reusing the keyboard occlusion the
/// compose bar and toolbar already track.
///
/// The engine owns the search: match highlighting, the hit cursor and the
/// counts all come from libghostty. This is a field and two chevrons.
final class PaneFindBar: UIView, UITextFieldDelegate {

    /// Shared find-bar state — debounce, counts, callbacks (see SearchBarModel,
    /// the same model the Mac bar uses). The host wires
    /// `onQueryChanged`/`onNext`/`onPrevious`/`onClose`; the count label tracks
    /// `onCountsChanged`.
    let model = SearchBarModel()

    static let barHeight: CGFloat = 44
    static let edgeGap: CGFloat = 10

    private let field = UITextField()
    private let countLabel = UILabel()
    private let prevButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let stack = UIStackView()
    private let card = UIView()
    private var glassView: UIVisualEffectView?

    var query: String {
        get { field.text ?? "" }
        set { field.text = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let host = installBackground()

        let magnifier = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        magnifier.tintColor = BentoBrand.inkSecondary
        magnifier.contentMode = .scaleAspectFit
        magnifier.setContentHuggingPriority(.required, for: .horizontal)

        // SF Pro, not mono: this is a query, not something headed into the
        // terminal. (The count below is the one honest place for mono here.)
        field.borderStyle = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = BentoBrand.inkPrimary
        field.attributedPlaceholder = NSAttributedString(
            string: "Find in pane",
            attributes: [.foregroundColor: BentoBrand.inkMuted])
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        // Return jumps to the next match instead of dismissing — the keyboard
        // stays up because you are usually stepping through hits.
        field.returnKeyType = .search
        field.enablesReturnKeyAutomatically = false
        field.delegate = self
        field.addTarget(self, action: #selector(textChanged), for: .editingChanged)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countLabel.textColor = BentoBrand.inkSecondary
        countLabel.textAlignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        model.onCountsChanged = { [weak self] text in
            self?.countLabel.text = text ?? ""
        }

        configure(prevButton, symbol: "chevron.up", label: "Previous match",
                  action: #selector(previousTapped))
        configure(nextButton, symbol: "chevron.down", label: "Next match",
                  action: #selector(nextTapped))
        configure(closeButton, symbol: "xmark", label: "Close find bar",
                  action: #selector(closeTapped))

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        [magnifier, field, countLabel, prevButton, nextButton, closeButton]
            .forEach { stack.addArrangedSubview($0) }
        host.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10),
            magnifier.widthAnchor.constraint(equalToConstant: 16),
            prevButton.widthAnchor.constraint(equalToConstant: 34),
            nextButton.widthAnchor.constraint(equalToConstant: 34),
            closeButton.widthAnchor.constraint(equalToConstant: 34),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure(_ button: UIButton, symbol: String, label: String, action: Selector) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = BentoBrand.inkSecondary
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func installBackground() -> UIView {
        let radius = Self.barHeight / 2
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = true
            let effectView = UIVisualEffectView(effect: glass)
            effectView.translatesAutoresizingMaskIntoConstraints = false
            effectView.layer.cornerRadius = radius
            effectView.clipsToBounds = true
            addSubview(effectView)
            pinToSelf(effectView)
            glassView = effectView
            return effectView.contentView
        } else {
            card.translatesAutoresizingMaskIntoConstraints = false
            card.backgroundColor = BentoBrand.surface
            card.layer.borderColor = BentoBrand.border.cgColor
            card.layer.borderWidth = 1
            card.layer.cornerRadius = radius
            card.clipsToBounds = true
            addSubview(card)
            pinToSelf(card)
            return card
        }
    }

    private func pinToSelf(_ v: UIView) {
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: - State

    func focusField() {
        field.becomeFirstResponder()
        field.selectAll(nil)
    }

    func dismissKeyboard() { field.resignFirstResponder() }

    var fieldHasFocus: Bool { field.isFirstResponder }

    // MARK: - Actions

    @objc private func previousTapped() {
        model.flushPendingQuery(query)
        model.onPrevious?()
    }
    @objc private func nextTapped() {
        model.flushPendingQuery(query)
        model.onNext?()
    }
    @objc private func closeTapped() { model.onClose?() }

    @objc private func textChanged() {
        model.queryChanged(query)
    }

    // MARK: - UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        model.flushPendingQuery(query)
        model.onNext?()
        return false   // keep the keyboard up; you're stepping through hits
    }

    /// Escape closes the bar — but ONLY here. This view is in the responder
    /// chain just while its field holds the keyboard, so the terminal keeps Esc
    /// (which it very much needs) the rest of the time.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                      action: #selector(closeTapped))]
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if glassView == nil {
            card.layer.borderColor = BentoBrand.border.cgColor
        }
    }
}
