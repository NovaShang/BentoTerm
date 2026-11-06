import SwiftUI
import BentoTmuxKit
import Combine
import BentoVoiceKit
import BentoAgentKit
import BentoSessionKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

// MARK: - Title-drag swap / dock
//
// VS Code-style drop zones, exactly like the macOS host: hovering a target
// pane previews the landing — its middle 50%×50% highlights the WHOLE pane
// (drop = swap the two panes), the four edge bands highlight that HALF
// (drop = re-split the target along that axis and dock the dragged pane on
// that side).

extension PaneContainerVC {
    /// Where a drop at a window-coordinate point would land, excluding the
    /// dragged pane. Pane frames live in `contentView`, so convert in first.
    private func landing(atWindowPoint p: CGPoint, excluding source: TmuxPaneID) -> PaneDrag.Landing? {
        PaneDrag.landing(at: contentView.convert(p, from: nil),
                         in: paneFrames, excluding: source)
    }

    func handleTitleSwap(source paneID: TmuxPaneID, phase: PaneDrag.Phase) {
        // Rearranging only makes sense between visible tiles. In focus /
        // single-pane layout there's nothing to land on, so ignore the drag.
        guard !isFocusLayout else { return }
        switch phase {
        case .began:
            paneControllers[paneID]?.view.alpha = 0.6
        case .moved(let p):
            updateDropOverlay(landing(atWindowPoint: p, excluding: paneID))
        case .ended(let p):
            let drop = landing(atWindowPoint: p, excluding: paneID)
            endTitleDrag(paneID)
            guard let drop else { return }
            viewModel?.perform(PaneDrag.action(source: paneID, landing: drop))
        case .cancelled:
            endTitleDrag(paneID)
        }
    }

    private func endTitleDrag(_ paneID: TmuxPaneID) {
        paneControllers[paneID]?.view.alpha = 1.0
        dropOverlay?.removeFromSuperview()
        dropOverlay = nil
    }

    /// Show/move/hide the landing preview. The frame animates between zones
    /// and across panes while visible; appearing (or reappearing after a gap)
    /// snaps into place so the preview never slides in from a stale spot.
    private func updateDropOverlay(_ drop: PaneDrag.Landing?) {
        guard let drop else {
            dropOverlay?.isHidden = true
            return
        }
        let overlay: PaneDropZoneOverlayView
        let appearing: Bool
        if let existing = dropOverlay {
            overlay = existing
            appearing = overlay.isHidden
        } else {
            overlay = PaneDropZoneOverlayView()
            contentView.addSubview(overlay)   // above every pane view
            dropOverlay = overlay
            appearing = true
        }
        overlay.isHidden = false
        overlay.zone = drop.zone
        if appearing {
            overlay.frame = drop.highlightRect
        } else {
            UIView.animate(withDuration: 0.12) { overlay.frame = drop.highlightRect }
        }
    }
}

/// The translucent landing preview shown while a pane drag hovers a target:
/// the whole pane for a center/swap drop (with a ⇄ badge — the one zone whose
/// meaning isn't its own shape), the docked half for an edge drop. Colored by
/// the inherited tint (the app accent, same as the focused-pane border).
/// Non-interactive; the title-bar pan owns the touch anyway.
final class PaneDropZoneOverlayView: UIView {
    private let icon = UIImageView(image: UIImage(
        systemName: "rectangle.2.swap",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)))

    var zone: PaneDropZone = .center {
        didSet { icon.isHidden = (zone != .center) }
    }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.borderWidth = 2
        layer.cornerRadius = 6
        addSubview(icon)
        applyTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The real tint arrives when the view joins the hierarchy.
    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyTint()
    }

    private func applyTint() {
        backgroundColor = tintColor.withAlphaComponent(0.22)
        layer.borderColor = tintColor.cgColor
        icon.tintColor = tintColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.sizeToFit()
        icon.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
