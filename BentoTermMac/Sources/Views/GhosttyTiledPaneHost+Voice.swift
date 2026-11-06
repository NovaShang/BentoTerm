import BentoTmuxKit
import BentoVoiceKit   // VoiceCompassView.Metrics / .Placement for the overlay's anchor
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI

extension GhosttyTiledPaneHost {
    // MARK: - Voice (right-click-and-hold)

    /// Right-click-hold passed the threshold on `paneID`: select it, show the
    /// compass overlay at the press point, and start hold-to-talk recording.
    func startVoice(forPane paneID: TmuxPaneID, atScreen screenPt: NSPoint) {
        viewModel.selectPane(paneID)
        showVoiceOverlay(atScreen: screenPt)
        // Feed the recording pane's on-screen text to the Qwen engine for context
        // biasing (read lazily at session start, only if the engine wants it).
        voiceController.readScreenText = { [weak self] in self?.cells[paneID]?.surface.readScrollback() }
        voiceController.begin(originScreen: screenPt)
    }

    private func showVoiceOverlay(atScreen screenPt: NSPoint) {
        let overlay: MacVoiceOverlay
        if let existing = voiceOverlay {
            overlay = existing
        } else {
            overlay = MacVoiceOverlay(controller: voiceController,
                                      frame: NSRect(origin: .zero,
                                                    size: VoiceCompassView.Metrics.size))
            addSubview(overlay)   // on top of the panes + divider overlay
            voiceOverlay = overlay
        }

        // Center the overlay at the press point (screen → host coords).
        let size = VoiceCompassView.Metrics.size
        var local = NSPoint(x: bounds.midX, y: bounds.midY)
        if let window {
            local = convert(window.convertPoint(fromScreen: screenPt), from: nil)
        }
        // Clamp only by what the RING needs. This used to keep the whole
        // 360x580 frame inside the window, which meant the compass could only be
        // centered on the cursor in a narrow band through the middle — press
        // anywhere else and it jumped inward, away from the pointer. The bubble
        // handles the edges itself now (flips below near the top, slides
        // sideways near a side), so the anchor barely has to move.
        let area = CGRect(origin: .zero, size: bounds.size)
        let anchor = VoiceCompassView.Placement.clampedAnchor(local, in: area)
        // No y-flip here: this host is `isFlipped` (see above), so its coords are
        // already the y-down space `Placement` works in. Flipping anyway inverted
        // the rule — a press at the BOTTOM of the window put the bubble below it,
        // off screen.
        overlay.placement = .resolve(anchor: anchor, in: area)
        overlay.frame = NSRect(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2,
                               width: size.width, height: size.height)
        overlay.isHidden = false
        overlay.needsLayout = true
    }

    func hideVoiceOverlay() {
        voiceOverlay?.isHidden = true
    }

    /// Show the right-swipe preview as a centered, interactive overlay card over a
    /// dimmed backdrop. (A sheet would need a contentViewController; this window
    /// sets `contentView` directly, so we host the card ourselves — same approach
    /// as the recording compass.)
    func presentVoicePreview() {
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

    func dismissVoicePreview() {
        voicePreview?.removeFromSuperview()
        voicePreview = nil
    }
}
#endif
