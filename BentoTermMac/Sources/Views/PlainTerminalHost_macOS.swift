import BentoFoundationKit
import BentoGhosttyKit
import BentoSessionKit
import BentoVoiceKit   // VoiceCompassView.Metrics / .Placement for the overlay's anchor
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftUI

/// A plain (no-tmux) tab's content: one surface and the little a plain shell
/// offers — typing, voice, copy/paste, ⌘F, close. Nothing else is wired, so
/// nothing else is offered: no splits, no file panel, no path preview, no pane
/// status. That is decided once, when the tab is built (`SessionTab`), instead
/// of every tmux feature asking "am I plain?" on its own.
///
/// The responder-chain actions below carry the SAME selectors as
/// `GhosttyTiledPaneHost`'s, so the Shell menu's Find and Close Pane reach a
/// plain tab too; everything else in that menu finds no target here and greys
/// out on its own.
@MainActor
final class PlainTerminalHost: NSView {
    let surface: GhosttyTerminalSurface
    private let viewModel: TerminalViewModel
    /// Hold-to-talk voice (right-click-and-hold), same controller and overlay
    /// as a tiled window.
    private let voiceController = MacVoiceController()
    private var voiceOverlay: MacVoiceOverlay?
    private var voicePreview: NSView?
    private var cancellables = Set<AnyCancellable>()

    /// Flipped (y-down) so the compass anchor math is the same as the tiled
    /// host's — `VoiceCompassView.Placement` works in y-down space.
    override var isFlipped: Bool { true }

    init(viewModel: TerminalViewModel, theme: TerminalTheme) {
        self.viewModel = viewModel
        self.surface = GhosttyTerminalSurface(theme: theme)
        super.init(frame: .zero)
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)

        // The VM streams bytes straight to/from the one surface.
        surface.onInput = { [weak viewModel] data in viewModel?.sendData(data) }
        surface.onSizeChanged = { [weak viewModel] size in
            viewModel?.resizeTerminal(cols: size.columns, rows: size.rows)
        }
        viewModel.onRawDataReceived = { [weak surface] data in
            Task { @MainActor [weak surface] in surface?.feed(data) }
        }

        surface.onVoicePrewarm = { [weak self] in self?.voiceController.prewarm() }
        surface.onVoiceStart = { [weak self] screenPt in self?.startVoice(atScreen: screenPt) }
        surface.onVoiceDrag = { [weak self] screenPt in self?.voiceController.update(toScreen: screenPt) }
        surface.onVoiceEnd = { [weak self] in self?.voiceController.end() }
        voiceController.onResult = { [weak viewModel] result in
            viewModel?.handleVoiceResult(result)
        }
        voiceController.$showOverlay
            .receive(on: RunLoop.main)
            .sink { [weak self] show in self?.voiceOverlay?.isHidden = !show }
            .store(in: &cancellables)
        voiceController.$showPreview
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                if show { self?.presentVoicePreview() } else { self?.dismissVoicePreview() }
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Free the surface on the main thread before the window goes — see
    /// `GhosttyTerminalSurface.teardown()`.
    func teardown() {
        cancellables.removeAll()
        surface.teardown()
    }

    // MARK: - Shell menu actions (same selectors as GhosttyTiledPaneHost)

    @objc func findInPane(_ sender: Any?) { surface.beginSearch() }
    @objc func findNextMatch(_ sender: Any?) { surface.findNext() }
    @objc func findPreviousMatch(_ sender: Any?) { surface.findPrevious() }
    @objc func useSelectionForFind(_ sender: Any?) { surface.useSelectionForFind() }
    /// ⌘W: a plain tab IS its one pane, so closing the pane closes the tab.
    @objc func closeCurrentPane(_ sender: Any?) { window?.performClose(sender) }

    // MARK: - Voice

    private func startVoice(atScreen screenPt: NSPoint) {
        showVoiceOverlay(atScreen: screenPt)
        voiceController.readScreenText = { [weak self] in self?.surface.readScrollback() }
        voiceController.begin(originScreen: screenPt)
    }

    private func showVoiceOverlay(atScreen screenPt: NSPoint) {
        let size = VoiceCompassView.Metrics.size
        let overlay = voiceOverlay ?? {
            let made = MacVoiceOverlay(controller: voiceController,
                                       frame: NSRect(origin: .zero, size: size))
            addSubview(made)
            voiceOverlay = made
            return made
        }()
        var local = NSPoint(x: bounds.midX, y: bounds.midY)
        if let window {
            local = convert(window.convertPoint(fromScreen: screenPt), from: nil)
        }
        let area = CGRect(origin: .zero, size: bounds.size)
        let anchor = VoiceCompassView.Placement.clampedAnchor(local, in: area)
        overlay.placement = .resolve(anchor: anchor, in: area)
        overlay.frame = NSRect(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2,
                               width: size.width, height: size.height)
        overlay.isHidden = false
        overlay.needsLayout = true
    }

    /// The right-swipe preview card, centred over a dimmed backdrop (same as a
    /// tiled window: the window has no sheet-capable content controller here).
    private func presentVoicePreview() {
        guard voicePreview == nil else { return }
        let backdrop = NSView(frame: bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        let card = NSHostingView(rootView: MacVoicePreviewView(controller: voiceController))
        let size = NSSize(width: 480, height: 260)
        card.frame = NSRect(x: (bounds.width - size.width) / 2,
                            y: (bounds.height - size.height) / 2,
                            width: size.width, height: size.height)
        card.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        backdrop.addSubview(card)
        addSubview(backdrop)
        voicePreview = backdrop
        window?.makeFirstResponder(card)
    }

    private func dismissVoicePreview() {
        voicePreview?.removeFromSuperview()
        voicePreview = nil
        window?.makeFirstResponder(surface)
    }
}
#endif
