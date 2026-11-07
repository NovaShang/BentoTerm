import SwiftUI
import BentoSessionKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

/// The plain shell's screen (no tmux): one terminal and the little a plain
/// shell offers — typing, voice, copy/paste, find, close.
///
/// Its own screen rather than `TerminalWrapperView` with pieces switched off:
/// the plain/tmux decision is made once, where the session is pushed
/// (`BentoApp`), so none of the session screen's features — Parallel/Focus,
/// window tabs, the file browser, the size banner, Kill Session, reconnecting
/// — has to ask "am I plain?". Find and paste come with the pane itself (its
/// long-press menu); everything else is simply not built here.
struct PlainShellView: View {
    @ObservedObject var viewModel: TerminalViewModel
    /// The SessionManager entry this screen closes.
    let sessionKey: SessionKey

    @StateObject private var voiceController = VoiceInputController()
    @StateObject private var paneBridge = PaneContainerBridge()
    @EnvironmentObject private var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false

    var body: some View {
        ZStack {
            // Full-screen pane backdrop, so the nav-bar and home-indicator
            // strips fuse with whatever the terminal actually renders.
            Color(uiColor: paneBridge.terminalBgColor ?? ThemeStore.shared.current.bgColor)
                .ignoresSafeArea()
            SinglePaneSurface(
                viewModel: viewModel,
                voiceController: voiceController,
                sizingMode: viewModel.sizingMode,
                sizingOwnerIsMe: false,
                isFullscreen: false,
                bridge: paneBridge)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("Sessions")
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Shell").font(.headline).lineLimit(1)
                    Text(viewModel.host.displayName).lineLimit(1)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showSettings = true } label: {
                        Label("Settings", systemImage: "gear")
                    }
                    Button(role: .destructive, action: close) {
                        Label("Close Shell", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                }
            }
        }
        .ignoresSafeArea(.keyboard)
        .modifier(TerminalInputOverlays(voiceController: voiceController, paneBridge: paneBridge))
        .sheet(isPresented: $showSettings) { SettingsView() }
        // A plain shell is never reconnected — the process died with the
        // connection — so the only way on is out.
        .alert("Connection Closed", isPresented: $viewModel.showError) {
            Button("Close", role: .cancel, action: close)
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onAppear {
            // On appear, not in init: a @StateObject's instance isn't final
            // until the view is mounted (see TerminalWrapperView).
            voiceController.onResult = { [weak viewModel] result in
                viewModel?.handleVoiceResult(result)
            }
        }
    }

    private func close() {
        sessionManager.disconnect(key: sessionKey)
        dismiss()
    }
}
