#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoAgentKit
import BentoSessionKit

/// The command-selection strip embedded at the bottom of the directory-chooser
/// panel (see `presentNewPaneDirectoryPanel`): a popup of the known agents plus
/// a custom-command field that appears only for "Custom command…".
///
/// This is the whole point of the redesign — the New Window / Split dialog IS a
/// native `NSOpenPanel`. Its folder browser picks the working directory, and
/// this accessory picks what runs in it, so there's no intermediate form and no
/// secondary "Choose…" popup.
final class NewPaneCommandAccessory: NSView {
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let customField = NSTextField()
    private static let presets = AgentPreset.allCases

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 52))

        let label = NSTextField(labelWithString: "Command:")

        popup.addItems(withTitles: Self.presets.map(\.rawValue))
        if let i = Self.presets.firstIndex(of: .none) { popup.selectItem(at: i) }
        popup.target = self
        popup.action = #selector(popupChanged)
        popup.setContentHuggingPriority(.required, for: .horizontal)

        customField.placeholderString = "e.g. cursor-agent"
        customField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        customField.isHidden = true   // only shown for "Custom command…"
        customField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [label, popup, customField])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var selectedPreset: AgentPreset {
        let idx = popup.indexOfSelectedItem
        return Self.presets.indices.contains(idx) ? Self.presets[idx] : .none
    }

    /// nil = a plain shell; otherwise the chosen agent's launch command or the
    /// user's custom command.
    var chosenCommand: String? {
        switch selectedPreset {
        case .none:
            return nil
        case .custom:
            let t = customField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        default:
            return selectedPreset.command
        }
    }

    @objc private func popupChanged() {
        let custom = (selectedPreset == .custom)
        customField.isHidden = !custom
        if custom { window?.makeFirstResponder(customField) }
    }
}

/// Present a native directory-chooser `NSOpenPanel` whose accessory picks the
/// command to run — the dialog itself is the folder browser (no separate form,
/// no secondary "Choose…" step). Seeds at `initialDirectory` (typically the
/// active pane's cwd) so confirming immediately reuses that folder, while the
/// user can still navigate to or create another. `onCreate(path, command)`
/// fires on confirm with the chosen directory and command; nothing on cancel.
@MainActor
public func presentNewPaneDirectoryPanel(
    title: String,
    prompt: String,
    initialDirectory: String?,
    onCreate: @escaping (String?, String?) -> Void
) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.title = title
    panel.message = "Choose a working directory, then pick what to run in it."
    panel.prompt = prompt
    let accessory = NewPaneCommandAccessory()
    panel.accessoryView = accessory
    panel.isAccessoryViewDisclosed = true
    if let initialDirectory, !initialDirectory.isEmpty {
        panel.directoryURL = URL(fileURLWithPath: (initialDirectory as NSString).expandingTildeInPath)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    // Every caller of this panel (Split, New Window from the sidebar, New
    // Window from the toolbar) is CREATING something at a directory the user
    // just picked by hand — the strongest possible signal that they'll want it
    // again. Recording here covers all of them at once.
    PaletteRecents.shared.recordLaunchIfUseful(dir: url.path, command: accessory.chosenCommand)
    onCreate(url.path, accessory.chosenCommand)
}
#endif
