import SwiftUI
import BentoTmuxKit
import Combine
import BentoVoiceKit
import BentoSessionKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

/// Bridges the UIKit terminal views into SwiftUI navigation.
/// The session has already been picked (and the SSH is up) before this view
/// is pushed; the view model comes in, the voice controller is owned here —
/// voice input exists only inside a terminal, so the controller lives and
/// dies with this screen.
struct TerminalWrapperView: View {
    @ObservedObject var viewModel: TerminalViewModel
    @StateObject private var voiceController: VoiceInputController

    init(viewModel: TerminalViewModel) {
        self.viewModel = viewModel
        _voiceController = StateObject(wrappedValue: VoiceInputController())
    }

    /// Route results into this session's VM — the same wiring the macOS host
    /// uses (GhosttyTiledPaneHost wires `viewModel.handleVoiceResult`).
    ///
    /// Wired on appear, NOT in `init`: a `@StateObject`'s wrappedValue is not
    /// final until the view is mounted — an instance captured in init can be
    /// discarded and replaced, leaving `onResult` set on a dead instance while
    /// ComposeBar talks to the live one (compose send then silently dropped).
    private func wireVoiceController() {
        voiceController.onResult = { [weak viewModel] result in
            viewModel?.handleVoiceResult(result)
        }
    }

    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State var showSettings = false
    /// In-session immersive fullscreen (hides the nav bar; its buttons float
    /// as glass discs). Pure UI state — deliberately not in the VM (which
    /// macOS shares) and not a size-class change (which would remount the
    /// terminal, see `chrome`).
    @State private(set) var isFullscreen = false
    @State private var sizingResolved = false
    @State var showMixedFlattenAlert = false
    /// The one-shot notice for something the app did on the user's behalf
    /// (see `applyPhoneFocusDefault`). Nil when there is nothing to say.
    @State private var tipToast: String?
    private let tips = TipCenter.shared
    @State var pendingCloseWindow: TmuxWindowID?
    /// Kill Session is destructive AND irreversible (every window/pane dies), so
    /// it goes through a confirmation before it runs.
    @State var pendingKillSession = false
    /// A take-over waiting on confirmation — set only when a NAMED device is
    /// being dispossessed (see `SessionSizeMismatch.needsConfirmation`).
    @State private var pendingSizeTakeover: SessionSizeMismatch?
    /// iPad only: which split-view columns are up. Driven by the mode, never by
    /// the user (see `syncSidebarVisibility`).
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly
    /// Reaches the live pane container (see PaneContainerBridge).
    @StateObject var paneBridge = PaneContainerBridge()

    var host: Host { viewModel.host }

    // MARK: - Fullscreen

    /// The iPad's fullscreen choice, remembered per DEVICE (not per
    /// host/session) so its manual toggle survives re-entry. Keyed globally:
    /// it is a personal UI preference, not a property of any session. An
    /// iPhone ignores it — it follows its orientation (`syncFullscreenToOrientation`).
    private var fullscreenPreferenceKey: String { "fullscreenMode" }

    func toggleFullscreen() {
        isFullscreen.toggle()
        UserDefaults.standard.set(isFullscreen, forKey: fullscreenPreferenceKey)
    }

    /// First mount (a fresh mount doesn't fire the size-class onChange).
    private func restoreFullscreenPreference() {
        if isRegularWidth {
            isFullscreen = UserDefaults.standard.bool(forKey: fullscreenPreferenceKey)
        } else {
            syncFullscreenToOrientation()
        }
    }

    /// iPhone: landscape is fullscreen, portrait isn't, both ways. It used to
    /// auto-enter only and leave the exit to a ⋯ row, plus remember a manual
    /// choice that then overrode rotation; with the row gone, following the
    /// orientation is the whole rule, and a choice saved by an older build
    /// can't strand the phone in fullscreen. iPad is manual (its bar button).
    private func syncFullscreenToOrientation() {
        guard !isRegularWidth else { return }
        isFullscreen = verticalSizeClass == .compact
    }

    /// The pane background as a SwiftUI color — the full-screen backdrop of
    /// the terminal screen (status-bar / nav-bar strips, home-indicator strip)
    /// and the window tab bar. Reads the terminal's LIVE reported background
    /// (via the bridge) so the strips fuse with whatever the terminal actually
    /// renders; falls back to the theme bg until the first report / after a
    /// theme change.
    private var paneBgColor: Color {
        // The terminal's live reported background (via the bridge), FUSED with
        // the foreground pane's running state — the full-screen backdrop, so
        // the now-transparent nav bar and window tab bar let it flow through
        // the top/bottom strips and match the reserved band below the toolbar.
        // Falls back to the theme bg until the first report / after a theme
        // change.
        let bg = paneBridge.terminalBgColor ?? ThemeStore.shared.current.bgColor
        if let signal = foregroundPaneSignal {
            return Color(uiColor: PaneChromeColors.washed(
                bg, status: PaneChrome.Status(state: signal.state,
                                              doneUnseen: signal.doneUnseen)))
        }
        return Color(uiColor: bg)
    }

    /// The pane the backdrop speaks for (zoomed/focused, else active) and its
    /// state — same resolution as `PaneContainerVC.effectiveFocusID`. Re-read
    /// on every body render, which `stateVersion` (bumped each state poll)
    /// drives, so the backdrop tracks state changes.
    private var foregroundPaneSignal: (state: PaneState, doneUnseen: Bool)? {
        let id = viewModel.zoomedPaneID
            ?? (viewModel.paneViewModels.count == 1 ? viewModel.paneViewModels.first?.paneID : nil)
            ?? viewModel.activePaneID
        guard let id, let pvm = viewModel.paneViewModels.first(where: { $0.paneID == id }) else { return nil }
        return (pvm.paneState, pvm.doneUnseen)
    }

    /// Persistence key for the sizing choice (per host + tmux session).
    private var sessionKey: String {
        "\(host.id.uuidString).\(viewModel.activeTmuxSessionName ?? "default")"
    }

    /// iPad (regular width) shows List mode as a leading window sidebar; the
    /// phone (compact width) uses the bottom window tab bar instead.
    var isRegularWidth: Bool { horizontalSizeClass == .regular }

    /// Bottom window tab bar: List mode's switcher on compact-width devices.
    /// Pure navigation chrome — the terminal above keeps showing the CURRENT
    /// window; tapping a tab is select-window only (zero zoom, zero resize).
    private var showsWindowTabs: Bool {
        viewModel.isTmuxReady && viewModel.sessionMode == .list && !isRegularWidth
    }

    /// The file browser roots at a tmux pane's working directory. (A plain
    /// shell never reaches this screen — it gets `PlainShellView`.)
    var showsFileBrowser: Bool { viewModel.isTmuxReady }

    var body: some View {
        terminalChrome
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("Connection Error", isPresented: $viewModel.showError) {
                Button("Retry") { viewModel.retry() }
                Button("Dismiss", role: .cancel) { dismiss() }
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error")
            }
            // Raised from the pane menu's "Split — Path & Command…", which
            // lives in the UIKit container; the bridge carries the request.
            .sheet(isPresented: $paneBridge.showsSplitPathCommand) {
                PathAndCommandSheet(title: "Split — Path & Command",
                               pathContextProvider: { paneBridge.container?.focusedPathPreviewContext() }) { path, command in
                    Task { await viewModel.splitPane(horizontal: true, seed: .custom(path: path, command: command)) }
                }
            }
            .alert(closeWindowPrompt.title, isPresented: Binding(
                get: { pendingCloseWindow != nil },
                set: { if !$0 { pendingCloseWindow = nil } }
            )) {
                Button(closeWindowPrompt.confirm, role: .destructive) {
                    if let id = pendingCloseWindow { viewModel.closeWindow(id) }
                    pendingCloseWindow = nil
                }
                Button("Cancel", role: .cancel) { pendingCloseWindow = nil }
            } message: {
                Text(closeWindowPrompt.message ?? "")
            }
            .alert(pendingSizeTakeover?.confirmTitle ?? "", isPresented: Binding(
                get: { pendingSizeTakeover != nil },
                set: { if !$0 { pendingSizeTakeover = nil } }
            )) {
                Button(pendingSizeTakeover?.actionTitle ?? "Take Over") {
                    pendingSizeTakeover = nil
                    viewModel.claimSessionSize()
                }
                Button("Cancel", role: .cancel) { pendingSizeTakeover = nil }
            } message: {
                Text(pendingSizeTakeover?.confirmMessage ?? "")
            }
            .alert(killSessionPrompt.title, isPresented: $pendingKillSession) {
                Button(killSessionPrompt.confirm, role: .destructive) {
                    // Leave the screen now; the kill awaits tmux's reply before it
                    // tears the connection down (see `killSession`), and holding
                    // the alert open for that round trip would look like a hang.
                    Task { await viewModel.killSession() }
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(killSessionPrompt.message ?? "")
            }
            .onChange(of: viewModel.isTmuxReady) { _, ready in
                if ready {
                    resolveSizing()
                    // Populate the session switcher (PRD §3.6) once attached.
                    Task { await viewModel.refreshTmuxSessions() }
                }
            }
            .onAppear { if viewModel.isTmuxReady { resolveSizing() } }
    }

    /// The terminal plus its floating chrome, kept separate from the modal
    /// chain so the compiler can type-check each half on its own.
    private var terminalChrome: some View {
        chrome
            .ignoresSafeArea(.keyboard)
            .onAppear {
                wireVoiceController()
                restoreFullscreenPreference()
            }
            // iPhone: fullscreen follows the orientation. A width change (iPad
            // split view, Slide Over) re-applies whichever rule now holds.
            .onChange(of: verticalSizeClass) { _, _ in syncFullscreenToOrientation() }
            .onChange(of: horizontalSizeClass) { _, _ in restoreFullscreenPreference() }
            .overlay(alignment: .top) { reconnectingBanner }
            // Voice compass, quick-keys bar, compose bar — shared with the
            // plain shell screen.
            .modifier(TerminalInputOverlays(voiceController: voiceController,
                                            paneBridge: paneBridge))
            .overlay(alignment: .top) { tipToastView }
    }

    /// Everything sizing-related now comes from the server (the view model
    /// adopts `window-size` + `@bento_size_owner` on attach), so first connect
    /// has nothing to resolve and — critically — nothing to WRITE. Writing a
    /// local default here is what let this device silently overrule a policy
    /// another device had chosen for the shared session.
    private func resolveSizing() {
        guard !sizingResolved, viewModel.isTmuxReady else { return }
        sizingResolved = true
        applyPhoneFocusDefault()
    }

    /// Phones open a multi-pane tiling in Focus by default — an act-and-inform
    /// default instead of the old "Open in Focus Mode?" prompt. The transform
    /// is lossless and one toggle away from reversal, which is what makes the
    /// silent default safe. Complex external layouts (setMode returns false
    /// without force) are left untouched — never auto-flatten.
    private func applyPhoneFocusDefault() {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              viewModel.isTmuxReady,
              viewModel.sessionStructure == .tiled,
              viewModel.paneViewModels.count > 1,
              !UserDefaults.standard.bool(forKey: "listModePrompt.\(sessionKey)")
        else { return }
        UserDefaults.standard.set(true, forKey: "listModePrompt.\(sessionKey)")
        Task {
            let ok = await viewModel.setMode(.list)
            if ok, tips.consume(.focusAutoSwitch) {
                showTipToast("Opened in Focus: each pane is now its own tmux window. Switch back to Parallel any time — nothing was closed.")
            }
        }
    }

    /// Show a transient, non-blocking toast (auto-hides).
    private func showTipToast(_ text: String) {
        withAnimation { tipToast = text }
        Task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation { if tipToast == text { tipToast = nil } }
        }
    }

    /// The session's chrome.
    ///
    /// iPad (regular width) uses the platform's split view, which is what makes
    /// the sidebar a full-height floating panel and gives EACH COLUMN its own
    /// toolbar — so the back button lands in the content region beside the
    /// sidebar rather than in a banner stretched over both (Files, Notes and
    /// Mail all read this way). The pushed navigation bar is hidden here for
    /// exactly that reason: one full-width bar above two columns reads as a lid
    /// over the UI, and it pushed the sidebar down out of the top.
    ///
    /// The phone has no sidebar, so it keeps the plain pushed bar. The branch is
    /// on SIZE CLASS, not on mode — it never flips under a live session, so the
    /// terminal is never remounted (and no PTY resized) by it.
    @ViewBuilder
    private var chrome: some View {
        if isRegularWidth {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                WindowSidebar(viewModel: viewModel,
                              pathContextProvider: { paneBridge.container?.focusedPathPreviewContext() })
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                    // The sidebar is mode-driven, never user-toggled (the same
                    // rule the macOS window follows), so there's nothing for a
                    // toggle button to mean.
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                terminalDetail
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { syncSidebarVisibility() }
            .onChange(of: showsWindowSidebar) { _, _ in syncSidebarVisibility() }
        } else {
            terminalDetail
        }
    }

    /// The terminal plus (on the phone) the window tab bar — the split view's
    /// detail column, and the whole screen on a phone. Owns the session toolbar.
    private var terminalDetail: some View {
        ZStack {
            // Full-screen pane backdrop. A plain Color with .ignoresSafeArea()
            // genuinely fills the status-bar / nav-bar strips above and the
            // home-indicator strip below — unlike `.background(ignoresSafeArea
            // Edges:)` on an in-safe-area view (extends by its zero insets,
            // i.e. nowhere) or a UIKit subview stretched past its parent's
            // bounds (SwiftUI clips it). The grid keeps its exact geometry:
            // tmux never resizes for this.
            paneBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                terminalSurface
                if showsWindowTabs {
                    WindowTabBar(viewModel: viewModel,
                                 pathContextProvider: { paneBridge.container?.focusedPathPreviewContext() })
                }
            }
            // Landscape (compact vertical size class): the terminal — and in
            // List mode the window tab bar under it — runs to the very bottom
            // edge (PRD §2.2). Portrait: the bottom safe area stays reserved
            // for the grid, and the tab bar keeps resting above it. The
            // keyboard is ignored on `body` either way: it slides OVER the bar
            // (hiding it) and never resizes the page (PRD §2.6).
            .ignoresSafeArea(.container, edges: verticalSizeClass == .compact
                ? .bottom
                : (showsWindowTabs ? [] : .bottom))
        }
        // Fullscreen: drop the nav bar (its buttons float as glass discs).
        // Hiding the bar shrinks safeAreaInsets.top to the status bar, so the
        // grid reclaims the bar's 44pt by itself — pageRect needs no change.
        .modifier(FullscreenNavBar(isFullscreen: isFullscreen))
        // Standard system navigation bar (Liquid Glass on iOS 26, no override):
        // back + session-switcher on the left, the mode switch centered, the ⋯
        // menu on the right. HostSessionsView stops hiding the nav bar for this.
        .navigationBarTitleDisplayMode(.inline)
        // Transparent nav bar: the terminal background flows through so the top
        // fuses with the terminal instead of wearing the opaque app-shell color.
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: backTapped) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("Sessions")
            }
            if isRegularWidth {
                ToolbarItem(placement: .topBarLeading) {
                    sessionTitle
                }
                // The centre already belongs to Parallel|Focus here, and the bar
                // is wide enough to carry the banner beside the session name.
                ToolbarItem(placement: .topBarLeading) {
                    if let mismatch = viewModel.sessionSizeMismatch {
                        sizeMismatchBanner(mismatch)
                    }
                }
                ToolbarItem(placement: .principal) {
                    if showsModeSwitch { modeToggle }
                }
            } else {
                // A phone's bar has one usable slot. While the canvas is
                // someone else's, that slot goes to the reason — the session
                // name is one tap away in the switcher and does not change.
                ToolbarItem(placement: .principal) {
                    if let mismatch = viewModel.sessionSizeMismatch {
                        sizeMismatchBanner(mismatch)
                    } else {
                        sessionTitle
                    }
                }
            }
            if showsFileBrowser {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { paneBridge.container?.presentFileBrowser() } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Files")
                }
            }
            // iPad only: the fullscreen toggle lives in the bar next to the
            // overflow menu (an iPhone follows its orientation instead).
            if isRegularWidth {
                ToolbarItem(placement: .topBarTrailing) {
                    fullscreenToggleButton
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                sessionMenu
            }
        }
        // Fullscreen floating chrome (glass discs over the pane background):
        // back top-left; Files + ⋯ top-right. One overlay to keep this modifier
        // chain type-checkable.
        .overlay { if isFullscreen { fullscreenOverlay } }
    }

    /// Fullscreen floating chrome as one overlay: top row (back left, Files +
    /// ⋯ right) above a spacer. The session name used to rest in the bottom
    /// strip — removed; the terminal owns the whole floor.
    private var fullscreenOverlay: some View {
        VStack {
            HStack {
                fullscreenBackButton
                Spacer()
                // Fullscreen has no bar to sit in, so the banner joins the
                // floating chrome row — the strip the discs already occupy —
                // rather than opening a new one over the terminal.
                if let mismatch = viewModel.sessionSizeMismatch {
                    sizeMismatchBanner(mismatch)
                    Spacer()
                }
                fullscreenTrailingButtons
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    /// The sidebar is MODE-driven, never user-toggled (same rule as the macOS
    /// window): it exists exactly when List mode has a wide enough screen.
    private var showsWindowSidebar: Bool {
        viewModel.isTmuxReady && viewModel.sessionMode == .list && isRegularWidth
    }

    private func syncSidebarVisibility() {
        let want: NavigationSplitViewVisibility = showsWindowSidebar ? .all : .detailOnly
        guard sidebarVisibility != want else { return }
        withAnimation { sidebarVisibility = want }
    }

    private var terminalSurface: some View {
        SinglePaneSurface(
            viewModel: viewModel,
            voiceController: voiceController,
            sizingMode: viewModel.sizingMode,
            sizingOwnerIsMe: viewModel.sizingOwnerIsMe,
            isFullscreen: isFullscreen,
            bridge: paneBridge
        )
    }

    // MARK: - Overlays

    /// Top pill shown while an auto-reconnect loop is in flight, so the session
    /// never looks silently frozen after a drop / lock-screen suspend.
    @ViewBuilder
    private var reconnectingBanner: some View {
        if viewModel.isReconnecting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Color.bentoEmerald)
                Text("Reconnecting…")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.bentoInkDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.bentoSurface))
            .overlay(Capsule().strokeBorder(Color.bentoBorder, lineWidth: 1))
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: viewModel.isReconnecting)
        }
    }

    /// "This canvas isn't yours" — shown when the grid the session is drawn at
    /// stops matching what this device fits, in every sizing policy (the
    /// default `latest` has no owner to name and is exactly where the surprise
    /// comes from). Tapping makes this device the one that sets the size.
    ///
    /// It lives in the NAVIGATION BAR, not above the terminal, and that is
    /// load-bearing twice over. A strip in the layout would steal rows from a
    /// canvas that is already too big for the phone — the case this banner
    /// exists to explain. And shrinking the viewport changes the very grid the
    /// banner compares: under `smallest` a banner that pushed the device grid
    /// down could drag the window down with it, clear its own condition, and
    /// blink forever. Chrome that was already there perturbs nothing.
    @ViewBuilder
    private func sizeMismatchBanner(_ mismatch: SessionSizeMismatch) -> some View {
        Button {
            if mismatch.needsConfirmation {
                pendingSizeTakeover = mismatch
            } else {
                viewModel.claimSessionSize()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: TerminalSizingMode.thisDevice.symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.bentoInkDim)
                VStack(alignment: .leading, spacing: 0) {
                    Text(mismatch.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.bentoInk)
                    Text("\(mismatch.actionTitle) · \(mismatch.compactDetail)")
                        .font(.caption2)
                        .foregroundStyle(Color.bentoInkDim)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.bentoSurface))
            .overlay(Capsule().strokeBorder(Color.bentoBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mismatch.summary) \(mismatch.actionTitle).")
    }

    // MARK: - Notice toast

    /// Transient top toast (the Focus default's one-time notice).
    @ViewBuilder
    private var tipToastView: some View {
        if let text = tipToast {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bentoEmerald)
                    .padding(.top, 1)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.bentoInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.bentoSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.bentoBorder, lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { withAnimation { tipToast = nil } }
        }
    }
}

/// Hides the navigation bar while fullscreen; untouched otherwise. iOS 26's
/// `.automatic` visibility changes the content safe area (shrinking the
/// container view — observed on a device), so non-fullscreen must not touch
/// the bar at all. iOS 18+ API with a deployment-target-17 fallback.
private struct FullscreenNavBar: ViewModifier {
    var isFullscreen: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isFullscreen {
            if #available(iOS 18.0, *) {
                content.toolbarVisibility(.hidden, for: .navigationBar)
            } else {
                content.toolbar(.hidden, for: .navigationBar)
            }
        } else {
            content
        }
    }
}
