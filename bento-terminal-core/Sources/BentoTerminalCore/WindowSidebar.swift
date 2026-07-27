import SwiftUI
import SwiftTmux

/// List mode's window switcher for the big screens — ONE implementation
/// shared by macOS (hosted in an `NSHostingView`) and iPad. Native sidebar
/// styling; each row is a window with its live display name and aggregate
/// state dot. The phone uses the bottom tab bar instead.
///
/// Per the two-mode design: no rename (names derive from what's running),
/// creation offers exactly the two seeds (duplicate current / specify
/// path+command), and closing confirms because processes die.
@MainActor
public struct WindowSidebar: View {
    @ObservedObject var viewModel: TerminalViewModel
    @State private var pendingClose: TmuxWindowID?
    @State private var showCustomSheet = false
    @State private var hoveredWindow: TmuxWindowID?
    @State private var pendingMove: TmuxWindowID?
    @State private var moveSessionName = ""
    @State private var landingChoice: (window: TmuxWindowID, session: String)?

    public init(viewModel: TerminalViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Native selection (accent pill) owns the row background untouched.
            // State lives entirely INSIDE the row content — the window name is
            // tinted by state and a trailing semantic glyph flags working /
            // awaiting — so it can never collide with or overflow the pill.
            List(selection: selectionBinding) {
                ForEach(viewModel.windows) { window in
                    row(window)
                        .tag(window.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)   // let the vibrancy chrome show

            newWindowButton
        }
        .confirmationDialog(
            closeDialogTitle,
            isPresented: Binding(
                get: { pendingClose != nil },
                set: { if !$0 { pendingClose = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Close Window", role: .destructive) {
                if let id = pendingClose { viewModel.closeWindow(id) }
                pendingClose = nil
            }
            Button("Cancel", role: .cancel) { pendingClose = nil }
        } message: {
            Text("The processes running in it will be terminated.")
        }
        .sheet(isPresented: $showCustomSheet) {
            NewWindowForm { path, command in
                Task { await viewModel.newListWindow(.custom(path: path, command: command)) }
            }
        }
        .alert("Move to New Session", isPresented: Binding(
            get: { pendingMove != nil },
            set: { if !$0 { pendingMove = nil } }
        )) {
            TextField("Session name", text: $moveSessionName)
            Button("Move") {
                // Same landing pipeline as a menu pick: a typed name may
                // match an EXISTING session, so the prompt can still follow.
                if let id = pendingMove { moveWindow(id, to: moveSessionName) }
                pendingMove = nil
            }
            Button("Cancel", role: .cancel) { pendingMove = nil }
        } message: {
            Text("The window keeps running — it moves to the new session.")
        }
        .confirmationDialog(
            "Move to “\(landingChoice?.session ?? "")”",
            isPresented: Binding(
                get: { landingChoice != nil },
                set: { if !$0 { landingChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Into Current Window (Parallel)") {
                if let c = landingChoice { moveWindow(c.window, to: c.session, landing: .joinCurrentWindow) }
                landingChoice = nil
            }
            Button("As New Window (Focus)") {
                if let c = landingChoice { moveWindow(c.window, to: c.session, landing: .newWindow) }
                landingChoice = nil
            }
            Button("Cancel", role: .cancel) { landingChoice = nil }
        } message: {
            Text("That session isn't settled into Parallel or Focus yet. Where should this land?")
        }
    }

    /// Run the move; an unsettled target bounces back as the landing dialog.
    private func moveWindow(_ id: TmuxWindowID, to session: String,
                            landing: MoveLanding = .auto) {
        Task {
            if await viewModel.moveWindow(id, toSession: session, landing: landing)
                == .needsLandingChoice {
                landingChoice = (id, session)
            }
        }
    }

    private var closeDialogTitle: String {
        let name = pendingClose.map { viewModel.windowDisplayName($0) } ?? ""
        return "Close “\(name)”?"
    }

    /// Selection mirrors the session's current window; picking a row is
    /// select-window. (List drives the native highlight from this binding.)
    private var selectionBinding: Binding<TmuxWindowID?> {
        Binding(
            get: { viewModel.activeWindowID },
            set: { id in if let id, id != viewModel.activeWindowID { viewModel.selectWindow(id) } }
        )
    }

    private func row(_ window: TmuxWindow) -> some View {
        let status = viewModel.windowStatus(window.id)
        return HStack(spacing: 6) {
            // Leading state glyph in a fixed-width slot so names stay aligned.
            // Shown on every row including the selected one — state reads the
            // same whether or not the row is current.
            stateIcon(status)
                .frame(width: 14)
            name(window.id, status: status)
                .lineLimit(1)
            Spacer(minLength: 6)
            closeButton(window.id)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredWindow = window.id }
            else if hoveredWindow == window.id { hoveredWindow = nil }
        }
        .contextMenu {
            WindowMoveToSessionMenu(viewModel: viewModel) { session in
                moveWindow(window.id, to: session)
            } onNewSession: {
                moveSessionName = ""
                pendingMove = window.id
            }
            Button("Close Window", role: .destructive) { pendingClose = window.id }
        }
    }

    /// The window name, tinted by status (idle = default color). Applied on every
    /// row including the selected one, so state color is consistent throughout.
    @ViewBuilder
    private func name(_ id: TmuxWindowID, status: WindowDisplayStatus) -> some View {
        let label = Text(viewModel.windowDisplayName(id))
        if let hex = statusHex(status) {
            label.foregroundStyle(Color(rgbHex: hex))
        } else {
            label
        }
    }

    /// The canonical palette hex for a status, or nil for idle (default color).
    /// Single source of truth shared with the pane chrome (`PaneState`).
    private func statusHex(_ status: WindowDisplayStatus) -> UInt32? {
        switch status {
        case .working:    return PaneState.workingHex
        case .awaiting:   return PaneState.awaitingHex
        case .doneUnseen: return PaneState.doneUnseenHex
        case .idle:       return nil
        }
    }

    /// Leading state glyph — same language as the Tiled pane title: working =
    /// blue play, awaiting = amber question, done = green check, idle = a quiet
    /// hollow gray ring (same `.circle` family, but empty = at rest). Colored
    /// from the canonical palette.
    @ViewBuilder
    private func stateIcon(_ status: WindowDisplayStatus) -> some View {
        switch status {
        case .working:    glyph("play.circle.fill", PaneState.workingHex)
        case .awaiting:   glyph("questionmark.circle.fill", PaneState.awaitingHex)
        case .doneUnseen: glyph("checkmark.circle.fill", PaneState.doneUnseenHex)
        case .idle:       glyph("circle", PaneState.idleHex)
        }
    }

    private func glyph(_ systemName: String, _ hex: UInt32) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12))
            .foregroundStyle(Color(rgbHex: hex))
    }

    /// Trailing per-row close affordance. Faint at rest, full on hover (pointer
    /// devices); the always-visible faint state keeps it reachable on touch.
    /// Routes through the same confirm dialog as the context menu.
    private func closeButton(_ id: TmuxWindowID) -> some View {
        Button {
            pendingClose = id
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close Window")
        .opacity(hoveredWindow == id ? 1 : 0.35)
    }

    /// Bottom-edge creation affordance, styled like Mail/Notes' "New …"
    /// footer: borderless, secondary, leading-aligned. Two seeds inside.
    private var newWindowButton: some View {
        Menu {
            Button {
                Task { await viewModel.newListWindow(.duplicateCurrent) }
            } label: {
                Label("Duplicate Current", systemImage: "plus.square.on.square")
            }
            Button {
                #if canImport(AppKit)
                // macOS: the pane runs a local shell, so the dialog itself IS a
                // native directory chooser (with a command popup baked in) —
                // no intermediate form.
                Task {
                    let cwd = await viewModel.activePaneWorkingDirectory()
                    presentNewPaneDirectoryPanel(
                        title: "New Window", prompt: "Create", initialDirectory: cwd
                    ) { path, command in
                        Task { await viewModel.newListWindow(.custom(path: path, command: command)) }
                    }
                }
                #else
                // iPad: the path lives on the remote host — keep the typed form.
                showCustomSheet = true
                #endif
            } label: {
                Label("Path & Command…", systemImage: "terminal")
            }
        } label: {
            Label("New Window", systemImage: "plus.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// "Move to Session" submenu for a window row/tab context menu — ONE
/// implementation shared by the sidebar (macOS/iPad) and the phone's bottom
/// tabs. Lists the OTHER sessions from the cached list (a refresh kicks off
/// when the menu opens, warming the next open — menus don't update while
/// displayed) plus "New Session…". The CONTAINER owns both follow-ups a
/// pick can need (an alert can't anchor inside the transient menu): the
/// new-session name prompt, and the landing prompt when `moveWindow`
/// returns `.needsLandingChoice`. Always actionable: moving the session's
/// last window makes the client follow it (see `moveWindow`).
@MainActor
public struct WindowMoveToSessionMenu: View {
    @ObservedObject var viewModel: TerminalViewModel
    let onPick: (String) -> Void
    let onNewSession: () -> Void

    public init(viewModel: TerminalViewModel,
                onPick: @escaping (String) -> Void,
                onNewSession: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onPick = onPick
        self.onNewSession = onNewSession
    }

    public var body: some View {
        Menu {
            let others = viewModel.availableTmuxSessions
                .filter { $0 != viewModel.activeTmuxSessionName }
            ForEach(others, id: \.self) { name in
                Button(name) { onPick(name) }
            }
            if !others.isEmpty { Divider() }
            Button {
                onNewSession()
            } label: {
                Label("New Session…", systemImage: "plus")
            }
        } label: {
            Label("Move to Session", systemImage: "rectangle.portrait.and.arrow.right")
        }
        .onAppear {
            Task { await viewModel.refreshTmuxSessions() }
        }
    }
}

/// The "specify path + command" mini-form used on iPad, where the working
/// directory lives on the *remote* host (so a local file picker can't apply)
/// and the path is typed. The command is chosen from the known agents — or a
/// custom command — rather than typed blind. Empty path = inherit the current
/// pane's directory; "No agent" = a plain shell. macOS uses a native directory
/// panel instead (see `presentNewPaneDirectoryPanel`).
@MainActor
struct NewWindowForm: View {
    var onCreate: (String?, String?) -> Void
    @State private var path = ""
    @State private var agentPreset: AgentPreset = .none
    @State private var customCommand = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Window").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Working directory").font(.caption).foregroundStyle(.secondary)
                TextField("Current pane's directory", text: $path)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Command").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Picker("Command", selection: $agentPreset) {
                        ForEach(AgentPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if agentPreset == .custom {
                        TextField("e.g. cursor-agent", text: $customCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    onCreate(path.isEmpty ? nil : path, resolvedCommand)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(minWidth: 400)
    }

    /// nil = plain shell (no agent); otherwise the chosen agent's launch command
    /// or the user's custom command.
    private var resolvedCommand: String? {
        switch agentPreset {
        case .none:
            return nil
        case .custom:
            let trimmed = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return agentPreset.command
        }
    }

    /// Custom needs a non-empty command; every other preset is always valid.
    private var canCreate: Bool {
        agentPreset != .custom
            || !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private extension Color {
    /// Build a SwiftUI Color from a 0xRRGGBB literal, so the sidebar wash can
    /// reuse `PaneState.dotColorHex` — the same palette the pane chrome uses.
    init(rgbHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
