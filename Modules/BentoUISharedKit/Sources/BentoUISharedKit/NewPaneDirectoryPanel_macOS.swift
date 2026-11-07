#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// The command field embedded at the bottom of the directory-chooser panel
/// (see `presentNewPaneDirectoryPanel`). Empty = a plain shell.
///
/// The New Window / Split dialog IS a native `NSOpenPanel`: its folder
/// browser picks the working directory, and this accessory says what runs in
/// it, so there's no intermediate form and no secondary "Choose…" popup.
final class NewPaneCommandAccessory: NSView {
    private let field = NSTextField()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 52))

        let label = NSTextField(labelWithString: "Command:")

        field.placeholderString = "Empty = shell"
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [label, field])
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

    /// nil = a plain shell; otherwise what the user typed.
    var chosenCommand: String? {
        let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
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
    onCreate(url.path, accessory.chosenCommand)
}
#endif
