import Foundation

/// tmux's five built-in window layouts, presented by what you will SEE with the
/// tmux name kept alongside.
///
/// This is the one place the "use tmux's own words" rule is relaxed on purpose.
/// tmux's names describe the axis it splits, not the result: `even-horizontal`
/// produces side-by-side COLUMNS, which reads backwards to nearly everyone —
/// the same trap that made "Split Horizontally" ambiguous. The label says what
/// happens; `slug` is what you'd type at a command line, and both are searchable
/// so "grid" and "tiled" find the same entry.
public struct TmuxNamedLayout: Identifiable, Sendable, Equatable {
    public let slug: String
    public let label: String
    public let symbol: String

    public var id: String { slug }
    /// For tooltips / subtitles — names the exact command this runs.
    public var command: String { "select-layout \(slug)" }

    public static let all: [TmuxNamedLayout] = [
        .init(slug: "even-horizontal", label: "Even Columns", symbol: "rectangle.split.3x1"),
        .init(slug: "even-vertical", label: "Even Rows", symbol: "rectangle.split.1x2"),
        .init(slug: "main-horizontal", label: "Main Pane on Top", symbol: "rectangle.tophalf.inset.filled"),
        .init(slug: "main-vertical", label: "Main Pane on Left", symbol: "rectangle.leadinghalf.inset.filled"),
        .init(slug: "tiled", label: "Grid", symbol: "square.grid.2x2"),
    ]
}
