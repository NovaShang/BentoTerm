import BentoTmuxKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoUISharedKit

extension GhosttyTiledPaneHost {
    // MARK: - Drag-to-dock (drag a pane's title bar onto another pane)
    //
    // VS Code-style drop zones: hovering a target pane previews the landing —
    // its middle 50%×50% highlights the WHOLE pane (drop = swap the two
    // panes), the four edge bands highlight that HALF (drop = re-split the
    // target along that axis and dock the dragged pane on that side).

    /// The pane + drop zone under a window-coordinate point, excluding the
    /// dragged pane. nil = not over any other pane (dropping does nothing).
    private func landing(at windowPoint: NSPoint, excluding source: TmuxPaneID) -> PaneDrag.Landing? {
        PaneDrag.landing(at: convert(windowPoint, from: nil),
                         in: cellFrames, excluding: source)
    }

    func handlePaneDrag(source paneID: TmuxPaneID, phase: PaneDrag.Phase) {
        switch phase {
        case .began:
            guard dragSourceID == nil else { return }
            dragSourceID = paneID
            cells[paneID]?.container.alphaValue = 0.6
            NSCursor.closedHand.push()

        case .moved(let windowPoint):
            updateDropOverlay(landing(at: windowPoint, excluding: paneID))

        case .ended(let windowPoint):
            let drop = landing(at: windowPoint, excluding: paneID)
            endPaneDrag(paneID)
            guard let drop else { return }
            viewModel.perform(PaneDrag.action(source: paneID, landing: drop))

        case .cancelled:
            endPaneDrag(paneID)
        }
    }

    private func endPaneDrag(_ paneID: TmuxPaneID) {
        dropOverlay?.removeFromSuperview()
        dropOverlay = nil
        cells[paneID]?.container.alphaValue = 1.0
        if dragSourceID != nil {
            dragSourceID = nil
            NSCursor.pop()
        }
    }

    /// Show/move/hide the landing preview. The frame animates between zones
    /// and across panes while visible; appearing from hidden snaps into place
    /// so the preview never slides in from a stale spot.
    private func updateDropOverlay(_ drop: PaneDrag.Landing?) {
        guard let drop else {
            dropOverlay?.isHidden = true
            return
        }
        let overlay: PaneDropZoneOverlay
        let appearing: Bool
        if let existing = dropOverlay {
            overlay = existing
            appearing = overlay.isHidden
        } else {
            overlay = PaneDropZoneOverlay()
            addSubview(overlay)   // above the cells and the divider overlay
            dropOverlay = overlay
            appearing = true      // a fresh overlay's frame is .zero — snap, don't slide in from the corner
        }
        overlay.isHidden = false
        overlay.zone = drop.zone
        if appearing {
            overlay.frame = drop.highlightRect
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                overlay.animator().frame = drop.highlightRect
            }
        }
    }
}

/// The translucent landing preview shown while a pane drag hovers a target:
/// the whole pane for a center/swap drop (with a ⇄ badge — the one zone whose
/// meaning isn't its own shape), the docked half for an edge drop. Hit-test
/// transparent; the title-bar drag owns the mouse anyway.
@MainActor
final class PaneDropZoneOverlay: NSView {
    private let icon = NSImageView()

    var zone: PaneDropZone = .center {
        didSet {
            guard oldValue != zone else { return }
            icon.isHidden = (zone != .center)
        }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let accent = GhosttyPaneColors.focusAccent()
        layer?.backgroundColor = accent.withAlphaComponent(0.22).cgColor
        layer?.borderColor = accent.cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 6
        icon.image = NSImage(systemSymbolName: "rectangle.2.swap",
                             accessibilityDescription: "Swap panes")?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .medium))
        icon.contentTintColor = accent
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        icon.sizeToFit()
        icon.frame.origin = NSPoint(x: (bounds.width - icon.frame.width) / 2,
                                    y: (bounds.height - icon.frame.height) / 2)
    }
}
#endif
