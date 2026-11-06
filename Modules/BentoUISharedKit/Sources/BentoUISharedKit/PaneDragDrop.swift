import CoreGraphics
import BentoTmuxKit
import BentoSessionKit

/// Dragging a pane by its title bar onto another pane — the VS Code-style
/// rearrange gesture. `PaneDropZone` says WHERE on the target the drop lands;
/// this says which pane is under the finger/cursor and what the drop MEANS.
///
/// Both hosts drive the same three-step gesture (pick up, hover, release) and
/// used to carry their own copy of it; what stays platform-side is the overlay
/// view and the animation, which is all either toolkit really contributes.
public enum PaneDrag {

    /// Where a drop would land: the pane under the point, the zone within it,
    /// and that pane's frame (so the host can position the landing preview
    /// without a second lookup).
    public struct Landing: Equatable, Sendable {
        public let pane: TmuxPaneID
        public let zone: PaneDropZone
        public let paneFrame: CGRect

        /// The region the preview should highlight — the whole pane for a swap,
        /// the docked half for an edge.
        public var highlightRect: CGRect { zone.highlightRect(in: paneFrame) }
    }

    /// The phases a title-bar drag reports to its host. Points are in WINDOW
    /// coordinates, so the host can hit-test across every pane; it converts
    /// into its own space before calling `landing(at:in:excluding:)`.
    public enum Phase: Equatable, Sendable {
        /// The drag left the slop radius — dim the source, take the cursor.
        case began
        case moved(CGPoint)
        /// Released at this point; the host resolves the landing and performs.
        case ended(CGPoint)
        /// The system took the gesture away — tidy up, change nothing.
        case cancelled
    }

    /// What releasing over a landing does to the session.
    public enum Action: Equatable, Sendable {
        /// The two panes trade places (`swap-pane`).
        case swap(source: TmuxPaneID, with: TmuxPaneID)
        /// The target re-splits along an axis and the dragged pane docks on that
        /// side (`move-pane`).
        case dock(source: TmuxPaneID, target: TmuxPaneID, horizontal: Bool, before: Bool)
    }

    /// The landing under `point` (in the same coordinate space as `frames`),
    /// ignoring the pane being dragged. nil = over nothing droppable.
    public static func landing(at point: CGPoint, in frames: [PaneFrame],
                               excluding source: TmuxPaneID) -> Landing? {
        guard let hit = frames.first(where: { $0.id != source && $0.frame.contains(point) })
        else { return nil }
        return Landing(pane: hit.id,
                       zone: PaneDropZone.zone(at: point, in: hit.frame),
                       paneFrame: hit.frame)
    }

    /// The session change a release over `landing` should make.
    public static func action(source: TmuxPaneID, landing: Landing) -> Action {
        if let dock = landing.zone.dock {
            return .dock(source: source, target: landing.pane,
                         horizontal: dock.horizontal, before: dock.before)
        }
        return .swap(source: source, with: landing.pane)
    }
}

public extension TerminalViewModel {
    /// Carry out a drop: re-split and dock (`move-pane`, which unlike
    /// `join-pane` accepts a pane already in the target's window), or swap.
    func perform(_ action: PaneDrag.Action) {
        switch action {
        case let .dock(source, target, horizontal, before):
            movePane(source, splitting: target, horizontal: horizontal, before: before)
        case let .swap(source, target):
            swapPanes(source, with: target)
        }
    }
}
