import SwiftUI
import BentoTmuxKit
import Combine
import BentoVoiceKit
import BentoSessionKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

// MARK: - Single-pane / tiled surface bridge

/// SwiftUI bridge for the UIKit container that hosts the live terminal panes
/// (tiled, or one focused) plus the floating quick-keys toolbar.
/// Lets the SwiftUI chrome reach the live pane container. Only the container
/// knows which pane is focused and how to resolve its file context, so the
/// Files button has to ask it rather than rebuild that itself.
@MainActor final class PaneContainerBridge: NSObject, ObservableObject {
    weak var container: PaneContainerVC?

    /// The terminal's live reported background, so the SwiftUI backdrop
    /// (status-bar / nav-bar / home-indicator strips) fuses with the terminal
    /// instead of a static legacy hex. `nil` until the first surface report and
    /// after a theme change (surfaces re-report once the config reloads), at
    /// which point `paneBgColor` falls back to the theme bg.
    @Published var terminalBgColor: UIColor?

    /// The find bar is up (its field holds the keyboard) — the floating
    /// quick-keys bar must hide so the two don't both sit on the keyboard top.
    @Published var findBarActive = false

    /// The pane menu asked for "Split — Path & Command…"; the SwiftUI chrome
    /// owns the sheet.
    @Published var showsSplitPathCommand = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(surfaceBackgroundChanged),
            name: .ghosttySurfaceBackgroundChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: .terminalThemeChanged, object: nil)
    }

    @objc private func surfaceBackgroundChanged(_ note: Notification) {
        guard let surface = note.object as? GhosttyTerminalSurface,
              container?.owns(surface: surface) == true,
              let color = surface.reportedBackgroundColor else { return }
        terminalBgColor = color
    }

    @objc private func themeChanged() {
        terminalBgColor = nil   // surfaces re-report after the config reload
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

struct SinglePaneSurface: UIViewControllerRepresentable {
    @ObservedObject var viewModel: TerminalViewModel
    /// Deliberately NOT @ObservedObject: only read in makeUIViewController.
    /// Observing it re-ran updateUIViewController (→ refreshPanes → a full
    /// layout pass) on every keystroke/touch the controller published.
    let voiceController: VoiceInputController
    var sizingMode: TerminalSizingMode
    /// Under `.thisDevice` only the owner may push a size, and only the owner's
    /// viewport matches the window — everyone else letterboxes.
    var sizingOwnerIsMe: Bool
    /// Fullscreen lets the grid reclaim the hidden nav bar's strip (pageRect
    /// reaches up into it). Not @ObservedObject-observed state: it only
    /// re-lays out the container, which updateUIViewController drives anyway.
    var isFullscreen: Bool
    /// Handed back to the SwiftUI chrome so the Files button can reach the
    /// focused pane's file context.
    let bridge: PaneContainerBridge

    func makeUIViewController(context: Context) -> PaneContainerVC {
        let vc = PaneContainerVC()
        bridge.container = vc
        vc.bridge = bridge
        vc.viewModel = viewModel
        vc.voiceController = voiceController
        vc.sizingMode = sizingMode
        vc.sizingOwnerIsMe = sizingOwnerIsMe
        vc.isFullscreen = isFullscreen

        if viewModel.isTmuxReady {
            vc.setupTmuxPanes()
        } else {
            vc.setupSinglePane()
            Task { @MainActor in
                if case .disconnected = viewModel.connectionState {
                    await viewModel.connect()
                }
            }
        }
        return vc
    }

    static func dismantleUIViewController(_ vc: PaneContainerVC, coordinator: ()) {
        // SwiftUI removed this representable (screen dismissed) — free the
        // ghostty surfaces NOW, before UIKit tears down the layer hierarchy.
        vc.teardownAll()
    }

    func updateUIViewController(_ vc: PaneContainerVC, context: Context) {
        bridge.container = vc
        vc.sizingMode = sizingMode
        vc.sizingOwnerIsMe = sizingOwnerIsMe
        vc.isFullscreen = isFullscreen
        if viewModel.isTmuxReady {
            if vc.singlePaneVC != nil {
                vc.setupTmuxPanes()
            } else {
                vc.refreshPanes()
            }
        }
    }
}
