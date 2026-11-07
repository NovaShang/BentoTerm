import SwiftUI
import BentoTmuxKit
import Combine
import BentoVoiceKit
import BentoSessionKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

extension TerminalWrapperView {
    // MARK: - Top Bar

    /// Session name (primary) + host (subtitle). PRD §3.6: tapping the name is a
    /// quick session switcher — a menu of the host's tmux sessions, switch in
    /// place. Plain (non-tappable) text before tmux is attached.
    @ViewBuilder
    var sessionTitle: some View {
        let label = VStack(spacing: 1) {
            // A plain session has no tmux name to show, and falling back to the
            // host printed it twice — once as the title, once under it. Name the
            // kind instead, the way the session list already does.
            Text(viewModel.activeTmuxSessionName ?? (isPlain ? "Shell" : host.displayName))
                .font(.headline).lineLimit(1)
            HStack(spacing: 4) {
                connectionDot
                Text(host.displayName).lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        if viewModel.isTmuxReady {
            Menu {
                ForEach(viewModel.availableTmuxSessions, id: \.self) { name in
                    Button { viewModel.switchSession(name) } label: {
                        if name == viewModel.activeTmuxSessionName {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
                Divider()
                Button { Task { await viewModel.refreshTmuxSessions() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            } label: {
                label
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        } else {
            label
        }
    }

    /// Parallel/Focus is offered once there is something to arrange: a second
    /// pane or a second window (`SessionChrome`). A one-pane session is a plain
    /// terminal, and a switch that changes nothing on screen is only noise.
    var showsModeSwitch: Bool {
        viewModel.isTmuxReady && SessionChrome.showsModeSwitch(
            paneCount: viewModel.sessionPanes.count, windowCount: viewModel.windows.count)
    }

    /// The mode switch itself (a structure transformation shared by every
    /// attached device, not a view preference). The one confirmation:
    /// flattening a mixed external structure into List.
    private func selectMode(_ newMode: TmuxSessionMode) {
        Task {
            let ok = await viewModel.requestMode(newMode)
            if !ok { showMixedFlattenAlert = true }
        }
    }

    /// Layout switch inside the ⋯ menu — the phone's home for it. An inline
    /// picker renders as a checkmark list; Focus leads, since a phone shows one
    /// pane anyway.
    private var modeSection: some View {
        Section("Layout") {
            Picker("Layout", selection: Binding(
                get: { viewModel.sessionMode },
                set: { selectMode($0) }
            )) {
                Label("Focus", systemImage: "rectangle").tag(TmuxSessionMode.list)
                Label("Parallel", systemImage: "square.split.2x2").tag(TmuxSessionMode.tiled)
            }
            .pickerStyle(.inline)
        }
    }

    /// iPad segmented control for the layout switch.
    var modeToggle: some View {
        Picker("Mode", selection: Binding(
            get: { viewModel.sessionMode },
            set: { selectMode($0) }
        )) {
            Text("Parallel").tag(TmuxSessionMode.tiled)
            Text("Focus").tag(TmuxSessionMode.list)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .alert(SessionPromptCopy.flatten.title, isPresented: $showMixedFlattenAlert) {
            Button(SessionPromptCopy.flatten.confirm, role: .destructive) {
                Task { await viewModel.setMode(.list, force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SessionPromptCopy.flatten.message ?? "")
        }
    }

    /// Overflow menu — a native SwiftUI `Menu`. The BUG-010 scroll-reset mis-tap
    /// came from the live Windows list making a LONG menu recompute-and-reset
    /// while open: Focus mode now drops the Windows section entirely (the bottom
    /// WindowTabBar already lists every window) and Parallel keeps it — few
    /// windows, at the very bottom — so the menu never grows long enough to
    /// scroll. Kill Session / Close Window still confirm first (alerts below,
    /// which present after the menu dismisses).
    ///
    /// Split into content + label so the fullscreen floating chrome can render
    /// the same menu behind a glass disc (a Menu's label is the only part that
    /// can carry the glass).
    private var sessionMenuContent: some View {
        Group {
            // Arrange, then the session-wide policy, then the session itself.
            // Creating panes is the pane menu's (it knows which pane to split).
            //
            // iPad only: in fullscreen its bar button is gone with the bar, so
            // this row is the way back. An iPhone follows its orientation
            // instead — landscape is fullscreen, portrait isn't — so it has no
            // state to toggle.
            if isRegularWidth {
                Button(action: toggleFullscreen) {
                    Label(isFullscreen ? "Exit Fullscreen" : "Fullscreen",
                          systemImage: isFullscreen ? "arrow.down.right.and.arrow.up.left"
                                                    : "arrow.up.left.and.arrow.down.right")
                }
            }
            if viewModel.isTmuxReady {
                // The phone has no room for the segmented switch in the bar,
                // so the layout choice lives here instead (see modeSection).
                // Fullscreen shows it everywhere (the iPad bar's toggle is
                // floating then, and there is no bar to host the switch).
                if showsModeSwitch, !isRegularWidth || isFullscreen { modeSection }
                layoutSection
                releaseSizeButton
            }
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gear")
            }
            if viewModel.isTmuxReady {
                windowsSection
                Button(role: .destructive) { pendingKillSession = true } label: {
                    Label("Kill Session", systemImage: "xmark.circle")
                }
            }
        }
    }

    var sessionMenu: some View {
        Menu { sessionMenuContent } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20))
        }
    }

    // MARK: - Fullscreen floating chrome

    /// The nav bar's buttons rehosted as floating glass discs over the pane
    /// background while fullscreen: back top-left, Files + ⋯ top-right, and
    /// the session name in the bottom (non-safe) strip.

    /// Bar button (iPad) — also the label source for the floating discs.
    var fullscreenToggleButton: some View {
        Button(action: toggleFullscreen) {
            Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left"
                                           : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 16, weight: .medium))
        }
        .accessibilityLabel(isFullscreen ? "Exit Fullscreen" : "Fullscreen")
    }

    var fullscreenBackButton: some View {
        Button(action: backTapped) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.bentoInk)
                .frame(width: 40, height: 40)
        }
        .modifier(GlassChrome(shape: .circle))
        .accessibilityLabel("Sessions")
        .padding(.leading, 12)
    }

    var fullscreenTrailingButtons: some View {
        HStack(spacing: 10) {
            if showsFileBrowser {
                Button { paneBridge.container?.presentFileBrowser() } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.bentoInk)
                        .frame(width: 40, height: 40)
                }
                .modifier(GlassChrome(shape: .circle))
                .accessibilityLabel("Files")
            }
            Menu { sessionMenuContent } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.bentoInk)
                    .frame(width: 40, height: 40)
                    .modifier(GlassChrome(shape: .circle))
            }
        }
        .padding(.trailing, 12)
    }

    private var overflowMenuContext: PaneMenuContext {
        PaneMenuContext(sessionMode: viewModel.sessionMode,
                        paneCount: viewModel.paneViewModels.count)
    }

    /// tmux's named layouts — parity with the Mac pane menu. They were always
    /// available on the server; only macOS had ever offered them.
    @ViewBuilder
    private var layoutSection: some View {
        if PaneMenuLayout.iosOverflowShowsLayouts(overflowMenuContext) {
            Section("Layout") {
                ForEach(TmuxNamedLayout.all) { layout in
                    Button {
                        guard let window = viewModel.activeWindowID else { return }
                        Task { await viewModel.applyWindowLayout(window, layout: layout.slug) }
                    } label: {
                        Label(layout.label, systemImage: layout.symbol)
                    }
                }
            }
        }
    }

    /// Release Size — only when something has fixed the session's size.
    /// Taking it over is the banner's job; this hands it back to the default
    /// (the device used last sets the size). The subtitle names who is being
    /// released, which on a second device is the thing it can't otherwise see.
    @ViewBuilder
    private var releaseSizeButton: some View {
        if viewModel.sizingMode.offersRelease {
            Button { viewModel.releaseSessionSize() } label: {
                Label {
                    Text(TerminalSizingMode.releaseTitle)
                    if let note = viewModel.sizingMode.releaseNote(
                        owner: viewModel.sizingOwner, ownerIsMe: viewModel.sizingOwnerIsMe) {
                        Text(note)
                    }
                } icon: {
                    Image(systemName: TerminalSizingMode.releaseSymbol)
                }
            }
        }
    }

    /// Window ops: switch + close. Parallel(Tiled) ONLY, and it sits at the very
    /// bottom of the menu — Focus mode omits it because its bottom WindowTabBar
    /// already lists every window, and a long live list in the menu was the
    /// BUG-010 scroll-reset mis-tap. Creation lives in List's "+" affordances;
    /// there is no bare "New Window".
    @ViewBuilder
    private var windowsSection: some View {
        if viewModel.sessionMode == .tiled, viewModel.windows.count > 1 {
            Section("Windows") {
                ForEach(viewModel.windows) { window in
                    Button { viewModel.selectWindow(window.id) } label: {
                        if window.id == viewModel.activeWindowID {
                            Label(viewModel.windowDisplayName(window.id), systemImage: "checkmark")
                        } else {
                            Text(viewModel.windowDisplayName(window.id))
                        }
                    }
                }
                Button(role: .destructive) {
                    pendingCloseWindow = viewModel.activeWindowID
                } label: {
                    Label("Close Window", systemImage: "xmark.rectangle")
                }
            }
        }
    }

    var closeWindowPrompt: SessionPromptCopy.Prompt {
        SessionPromptCopy.closeWindow(pendingCloseWindow.map { viewModel.windowDisplayName($0) } ?? "")
    }

    var killSessionPrompt: SessionPromptCopy.Prompt {
        SessionPromptCopy.killSession(viewModel.activeTmuxSessionName)
    }

    @ViewBuilder
    private var connectionDot: some View {
        switch viewModel.connectionState {
        case .connected: Circle().fill(.green).frame(width: 5, height: 5)
        case .connecting: ProgressView().scaleEffect(0.5)
        case .failed: Circle().fill(.red).frame(width: 5, height: 5)
        case .disconnected: Circle().fill(.secondary).frame(width: 5, height: 5)
        }
    }

    func backTapped() {
        // If a pane is focused (zoomed), back exits focus first instead of
        // leaving the session — matches the drill-down mental model.
        if let z = viewModel.zoomedPaneID {
            viewModel.toggleZoom(z)
        } else {
            dismiss()
        }
    }
}
