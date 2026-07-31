import UIKit

enum AccessoryKey: CaseIterable {
    case escape, tab, ctrl, enter
    case up, down, left, right
    case pipe, slash, tilde, dash
    case paste
}

final class KeyboardAccessoryView: UIInputView {
    var onKeyTap: ((AccessoryKey) -> Void)?
    /// Tapped the "hide keyboard" button (double-tap no longer dismisses, since
    /// in keyboard mode it selects text).
    var onDismissKeyboard: (() -> Void)?
    /// Tapped the "switch to the compose box" button — the one-tap way back from
    /// raw keyboard to the managed input box.
    var onSwitchToCompose: (() -> Void)?
    private(set) var isCtrlActive = false
    private var ctrlButton: UIButton?

    private let keyHeight: CGFloat = 36
    private let spacing: CGFloat = 6

    init() {
        super.init(
            frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44),
            inputViewStyle: .keyboard
        )
        setupKeys()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func toggleCtrl() {
        isCtrlActive.toggle()
        updateCtrlAppearance()
    }

    func deactivateCtrl() {
        isCtrlActive = false
        updateCtrlAppearance()
    }

    private func setupKeys() {
        // Fixed "hide keyboard" button pinned to the trailing edge (always
        // visible, doesn't scroll with the key row).
        let dismiss = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        dismiss.setImage(UIImage(systemName: "keyboard.chevron.compact.down", withConfiguration: cfg), for: .normal)
        dismiss.tintColor = .white
        dismiss.translatesAutoresizingMaskIntoConstraints = false
        dismiss.addAction(UIAction { [weak self] _ in self?.onDismissKeyboard?() }, for: .touchUpInside)
        addSubview(dismiss)

        // Fixed "back to the compose box" button pinned to the leading edge — the
        // one-tap way from raw keyboard back to the managed input box.
        let compose = UIButton(type: .system)
        compose.setImage(UIImage(systemName: "square.and.pencil", withConfiguration: cfg), for: .normal)
        compose.tintColor = .white
        compose.translatesAutoresizingMaskIntoConstraints = false
        compose.addAction(UIAction { [weak self] _ in self?.onSwitchToCompose?() }, for: .touchUpInside)
        addSubview(compose)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            dismiss.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dismiss.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismiss.widthAnchor.constraint(equalToConstant: 34),

            compose.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            compose.centerYAnchor.constraint(equalTo: centerYAnchor),
            compose.widthAnchor.constraint(equalToConstant: 34),

            scrollView.leadingAnchor.constraint(equalTo: compose.trailingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = spacing
        stack.alignment = .center
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let keys: [(AccessoryKey, String)] = [
            (.escape, "Esc"),
            (.tab, "Tab"),
            (.ctrl, "Ctrl"),
            (.paste, "Paste"),
            (.up, "\u{2191}"),
            (.down, "\u{2193}"),
            (.left, "\u{2190}"),
            (.right, "\u{2192}"),
            (.pipe, "|"),
            (.slash, "/"),
            (.tilde, "~"),
            (.dash, "-"),
        ]

        for (key, label) in keys {
            let button = makeButton(label: label, key: key)
            stack.addArrangedSubview(button)
            if key == .ctrl {
                ctrlButton = button
            }
        }
    }

    private func makeButton(label: String, key: AccessoryKey) -> UIButton {
        // iOS-native keycap style: solid white/dark keys with drop shadow
        var config = UIButton.Configuration.filled()
        config.title = label
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor(hex: 0x6B6B6E)
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attrs = incoming
            attrs.font = UIFont.systemFont(ofSize: 14, weight: .regular)
            return attrs
        }

        let button = UIButton(configuration: config)
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.45
        button.layer.shadowRadius = 0
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.addAction(UIAction { [weak self] _ in
            self?.onKeyTap?(key)
        }, for: .touchUpInside)

        button.heightAnchor.constraint(equalToConstant: keyHeight).isActive = true
        return button
    }

    private func updateCtrlAppearance() {
        guard let button = ctrlButton else { return }
        var config = button.configuration
        config?.baseBackgroundColor = isCtrlActive ? STTheme.ChromeDark.accent : UIColor(hex: 0x6B6B6E)
        config?.baseForegroundColor = .white
        button.configuration = config
    }
}
