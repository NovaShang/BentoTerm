import SwiftUI
import BentoTmuxKit
import BentoSessionKit
import BentoFilePreviewKit

/// What a window row or tab has asked for and not yet finished: the dialogs a
/// context menu raises can't live inside the menu (it's gone by the time they
/// show), so the list that owns the menu holds them here and attaches
/// `.windowActionDialogs`. The sidebar (macOS/iPad) and the iPhone tab bar
/// both use it; the Mac window strip asks with NSAlerts and only shares the
/// words (`SessionPromptCopy`) and the landing flow.
@MainActor
public final class WindowActionsState: ObservableObject {
    @Published public var pendingClose: TmuxWindowID?
    @Published public var pendingRename: TmuxWindowID?
    @Published public var renameText = ""
    @Published public var pendingMove: TmuxWindowID?
    @Published public var moveSessionName = ""
    /// The "Path & Command…" form (iOS — the Mac picks with a directory panel).
    @Published public var showsNewWindowForm = false
    /// Asks where a moved window lands when the target session is unsettled.
    public let landingPrompt = MoveLandingPrompt()

    public init() {}

    public func requestRename(_ id: TmuxWindowID, current: String) {
        renameText = current
        pendingRename = id
    }

    public func requestMoveToNewSession(_ id: TmuxWindowID) {
        moveSessionName = ""
        pendingMove = id
    }

    /// Run the move; an unsettled target asks through the landing dialog.
    public func moveWindow(_ id: TmuxWindowID, to session: String,
                           in viewModel: TerminalViewModel) {
        let prompt = landingPrompt
        Task {
            await viewModel.moveWindow(id, toSession: session,
                                       chooseLanding: prompt.ask)
        }
    }

    /// Whether `id` can step `earlier` (or later) in `windows` — the first
    /// can't go earlier, the last can't go later.
    nonisolated public static func canShift(_ id: TmuxWindowID, earlier: Bool,
                                            in windows: [TmuxWindowID]) -> Bool {
        guard let index = windows.firstIndex(of: id) else { return false }
        return earlier ? index > 0 : index < windows.count - 1
    }
}

/// How the close confirmation is raised: the sidebar uses a confirmation
/// dialog, the phone's tab bar a centred alert.
public enum WindowCloseConfirmation: Sendable {
    case dialog, alert
}

public extension View {
    /// The close / rename / move-to-new-session / landing dialogs and the
    /// "Path & Command…" form for a list of windows whose menus write `state`.
    /// `pathContextProvider` lets the iOS form browse the pane's remote tree
    /// instead of typing a path (nil = typed only).
    func windowActionDialogs(
        viewModel: TerminalViewModel,
        state: WindowActionsState,
        close: WindowCloseConfirmation = .dialog,
        pathContextProvider: (() -> PathPreviewContext?)? = nil
    ) -> some View {
        modifier(WindowActionDialogs(viewModel: viewModel, state: state, close: close,
                                     pathContextProvider: pathContextProvider))
    }
}

private struct WindowActionDialogs: ViewModifier {
    @ObservedObject var viewModel: TerminalViewModel
    @ObservedObject var state: WindowActionsState
    let close: WindowCloseConfirmation
    let pathContextProvider: (() -> PathPreviewContext?)?

    func body(content: Content) -> some View {
        content
            .modifier(CloseConfirmation(style: close, prompt: closePrompt,
                                        isPresented: isPending(\.pendingClose)) {
                if let id = state.pendingClose { viewModel.closeWindow(id) }
                state.pendingClose = nil
            })
            .alert(SessionPromptCopy.renameWindow.title,
                   isPresented: isPending(\.pendingRename)) {
                TextField(SessionPromptCopy.renameWindow.placeholder ?? "",
                          text: $state.renameText)
                Button(SessionPromptCopy.renameWindow.confirm) {
                    if let id = state.pendingRename { viewModel.renameWindow(id, to: state.renameText) }
                    state.pendingRename = nil
                }
                Button("Cancel", role: .cancel) { state.pendingRename = nil }
            } message: {
                Text(SessionPromptCopy.renameWindow.message ?? "")
            }
            .alert(SessionPromptCopy.moveWindowToNewSession.title,
                   isPresented: isPending(\.pendingMove)) {
                TextField(SessionPromptCopy.moveWindowToNewSession.placeholder ?? "",
                          text: $state.moveSessionName)
                Button(SessionPromptCopy.moveWindowToNewSession.confirm) {
                    // Same landing pipeline as a menu pick: a typed name may
                    // match an EXISTING session, so the prompt can still follow.
                    if let id = state.pendingMove {
                        state.moveWindow(id, to: state.moveSessionName, in: viewModel)
                    }
                    state.pendingMove = nil
                }
                Button("Cancel", role: .cancel) { state.pendingMove = nil }
            } message: {
                Text(SessionPromptCopy.moveWindowToNewSession.message ?? "")
            }
            .moveLandingDialog(state.landingPrompt)
            #if os(iOS)
            .sheet(isPresented: $state.showsNewWindowForm) {
                PathAndCommandSheet(title: "New Window",
                                    pathContextProvider: pathContextProvider) { path, command in
                    Task { await viewModel.newListWindow(.custom(path: path, command: command)) }
                }
            }
            #endif
    }

    private var closePrompt: SessionPromptCopy.Prompt {
        SessionPromptCopy.closeWindow(state.pendingClose.map { viewModel.windowDisplayName($0) } ?? "")
    }

    private func isPending(_ key: ReferenceWritableKeyPath<WindowActionsState, TmuxWindowID?>)
        -> Binding<Bool> {
        Binding(get: { state[keyPath: key] != nil },
                set: { if !$0 { state[keyPath: key] = nil } })
    }
}

private struct CloseConfirmation: ViewModifier {
    let style: WindowCloseConfirmation
    let prompt: SessionPromptCopy.Prompt
    let isPresented: Binding<Bool>
    let confirm: () -> Void

    func body(content: Content) -> some View {
        switch style {
        case .dialog:
            content.confirmationDialog(prompt.title, isPresented: isPresented,
                                       titleVisibility: .visible) {
                buttons
            } message: {
                Text(prompt.message ?? "")
            }
        case .alert:
            content.alert(prompt.title, isPresented: isPresented) {
                buttons
            } message: {
                Text(prompt.message ?? "")
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button(prompt.confirm, role: .destructive, action: confirm)
        Button("Cancel", role: .cancel) { isPresented.wrappedValue = false }
    }
}

/// A window's context menu, for a sidebar row (`.vertical`: Rename) or a
/// phone tab (`.horizontal`: Move Left/Right with arrows).
/// Every follow-up dialog goes through `state`.
@MainActor
public struct WindowContextMenu: View {
    public enum Axis: Sendable { case vertical, horizontal }

    @ObservedObject var viewModel: TerminalViewModel
    let state: WindowActionsState
    let window: TmuxWindowID
    let axis: Axis

    public init(viewModel: TerminalViewModel, state: WindowActionsState,
                window: TmuxWindowID, axis: Axis) {
        self.viewModel = viewModel
        self.state = state
        self.window = window
        self.axis = axis
    }

    public var body: some View {
        if axis == .vertical {
            // Renaming lives here rather than on the toolbar's centre label,
            // which in Focus is a read-only title.
            Button("Rename Window…") {
                state.requestRename(window, current: viewModel.windowBodyName(window))
            }
        }
        // The drag's one-step equivalent on a phone tab strip, where a long
        // drag along a scrolling row is the hard way. A sidebar row reorders
        // by drag (and ⌥⌘↑/↓ on the Mac), so it doesn't spend two rows on it.
        if axis == .horizontal {
            shiftButton(earlier: true)
            shiftButton(earlier: false)
        }
        WindowMoveToSessionMenu(viewModel: viewModel) { session in
            state.moveWindow(window, to: session, in: viewModel)
        } onNewSession: {
            state.requestMoveToNewSession(window)
        }
        Button(role: .destructive) {
            state.pendingClose = window
        } label: {
            if axis == .vertical {
                Text("Close Window")
            } else {
                Label("Close Window", systemImage: "xmark")
            }
        }
    }

    @ViewBuilder
    private func shiftButton(earlier: Bool) -> some View {
        let enabled = WindowActionsState.canShift(window, earlier: earlier,
                                                  in: viewModel.windows.map(\.id))
        Button {
            Task { await viewModel.shiftWindow(window, earlier: earlier) }
        } label: {
            Label(earlier ? "Move Left" : "Move Right",
                  systemImage: earlier ? "arrow.left" : "arrow.right")
        }
        .disabled(!enabled)
    }
}

/// The two ways to start a window — duplicate the current one, or pick a path
/// and command — behind whatever label the host draws. `onPathAndCommand`
/// is the host's: the Mac opens a directory panel, iOS raises the form.
@MainActor
public struct NewWindowSeedMenu<MenuLabel: View>: View {
    @ObservedObject var viewModel: TerminalViewModel
    let onPathAndCommand: () -> Void
    let label: MenuLabel

    public init(viewModel: TerminalViewModel,
                onPathAndCommand: @escaping () -> Void,
                @ViewBuilder label: () -> MenuLabel) {
        self.viewModel = viewModel
        self.onPathAndCommand = onPathAndCommand
        self.label = label()
    }

    public var body: some View {
        Menu {
            Button {
                Task { await viewModel.newListWindow(.duplicateCurrent) }
            } label: {
                Label("Duplicate Current", systemImage: "plus.square.on.square")
            }
            Button(action: onPathAndCommand) {
                Label("Path & Command…", systemImage: "terminal")
            }
        } label: {
            label
        }
    }
}

#if os(iOS)
/// The "specify path + command" sheet, shared by List's "New Window" (iPhone
/// tabs and iPad sidebar) and Tiled's "Split — Path & Command…". Empty
/// command = plain shell; empty path = inherit the current pane's directory.
///
/// The directory is BROWSED (a pushed `DirectoryPickerView` over the pane's
/// own remote file source) whenever there is one to browse — typing a path on
/// a touch screen is not a real affordance. The text field survives as the
/// escape hatch, and is the whole section when no source is reachable. (macOS
/// never shows this: its pane runs locally, so a native directory panel is
/// the chooser — see `presentNewPaneDirectoryPanel`.)
public struct PathAndCommandSheet: View {
    var title: String
    /// Reaches the focused pane's REMOTE file source, so the directory can be
    /// browsed instead of typed. nil — or a provider that returns nil (no
    /// tmux, SSH down) — degrades the section to the plain text field.
    var pathContextProvider: (() -> PathPreviewContext?)?
    var onCreate: (String?, String?) -> Void

    @State private var path = ""
    @State private var command = ""
    @State private var showPicker = false
    /// The tree needs room: browsing pushes the sheet to .large and coming
    /// back drops it to .medium, so the form stays the compact thing it was.
    @State private var detent: PresentationDetent = .medium
    @Environment(\.dismiss) private var dismiss

    public init(title: String,
                pathContextProvider: (() -> PathPreviewContext?)? = nil,
                onCreate: @escaping (String?, String?) -> Void) {
        self.title = title
        self.pathContextProvider = pathContextProvider
        self.onCreate = onCreate
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Working Directory") {
                    // Browsable when the pane has a reachable file source. The
                    // field stays as the escape hatch (jump anywhere) and is
                    // the ONLY control when there's nothing to browse.
                    if browsableContext != nil {
                        Button {
                            showPicker = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(Color.accentColor)
                                Text(path.isEmpty ? "Current directory" : path)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if !path.isEmpty {
                            Button("Use Current Directory") { path = "" }
                        }
                    }
                    TextField(browsableContext == nil ? "Empty = current directory"
                                                      : "Or type a path",
                              text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Command") {
                    TextField("Empty = shell", text: $command)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showPicker) { directoryPicker }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(path.isEmpty ? nil : path, resolvedCommand)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .onChange(of: showPicker) { _, browsing in
            detent = browsing ? .large : .medium
        }
    }

    /// The pane's file context right now — re-asked on every body pass because
    /// the transport reconnects (and the answer flips to nil when it's down).
    private var browsableContext: PathPreviewContext? {
        pathContextProvider?()
    }

    /// Pushed, not a second sheet: a sheet-over-sheet at .medium would have
    /// left the tree a few rows tall.
    @ViewBuilder private var directoryPicker: some View {
        DirectoryPickerView(
            contextProvider: { pathContextProvider?() },
            confirmTitle: "Use This Folder",
            onPick: { picked in
                path = picked
                showPicker = false
            })
            .navigationTitle("Choose Folder")
            .navigationBarTitleDisplayMode(.inline)
    }

    /// nil = plain shell; otherwise what the user typed.
    private var resolvedCommand: String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
