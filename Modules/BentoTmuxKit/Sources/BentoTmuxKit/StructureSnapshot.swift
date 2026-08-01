import Foundation

/// A record of a session's window/pane shape, taken before Bento rearranges it
/// so the arrangement can be put back.
///
/// This replaces a pair of options that could only describe ONE window (a lone
/// layout string plus a flat pane order). Anything else — the mixed
/// `N windows × M panes` shape a tmux user actually builds — was not saved at
/// all, so "switch to Focus and back" quietly collapsed the whole session into
/// a single window. The model was a subset of tmux's; the *memory* was the part
/// that had to grow.
public struct TmuxStructureSnapshot: Codable, Equatable, Sendable {

    public struct Window: Codable, Equatable, Sendable {
        /// `#{window_index}` at capture time. Advisory: indices are reassigned
        /// as windows come and go, so restore uses it for ordering only.
        public var index: Int?
        public var name: String
        /// `#{window_layout}`, braces and all.
        public var layout: String?
        /// Pane ids in window order. Pane ids (`%N`) are stable for a pane's
        /// lifetime and survive break-pane/join-pane, which is what makes them
        /// usable as the anchor for putting panes back where they were.
        public var panes: [TmuxPaneID]

        public init(index: Int? = nil, name: String, layout: String? = nil, panes: [TmuxPaneID]) {
            self.index = index
            self.name = name
            self.layout = layout
            self.panes = panes
        }
    }

    public var windows: [Window]

    public init(windows: [Window]) {
        self.windows = windows
    }

    /// Every pane the snapshot knows about, in window-then-pane order.
    public var allPanes: [TmuxPaneID] { windows.flatMap(\.panes) }

    // MARK: - Storage

    /// Base64 of the JSON, for stashing in a tmux session option.
    ///
    /// Base64 rather than raw JSON on purpose: a tmux option value is parsed by
    /// tmux's own command lexer, where `{`, `}`, `;` and `#` are syntax. A
    /// layout string already carries braces, and that exact hazard silently
    /// broke the Parallel⇄Focus round-trip once (114ef43 — the whole
    /// `set-option` failed with a syntax error nobody saw). `escapeArg` quotes
    /// those today, but an alphabet of `[A-Za-z0-9+/=]` cannot be mis-lexed by
    /// any future change to either side.
    public func encoded() -> String? {
        guard let json = try? JSONEncoder().encode(self) else { return nil }
        return json.base64EncodedString()
    }

    public static func decode(_ stored: String?) -> TmuxStructureSnapshot? {
        guard let stored,
              !stored.isEmpty,
              let data = Data(base64Encoded: stored),
              let snapshot = try? JSONDecoder().decode(TmuxStructureSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    /// JSON for logs — the stored form is unreadable by design, so diagnostics
    /// print this instead.
    public var debugJSON: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "<unencodable>"
    }

    // MARK: - Restore planning

    /// What to do to one window when putting the shape back.
    public struct RestoreStep: Equatable, Sendable {
        /// The pane that stays put; every other pane joins into its window.
        public let base: TmuxPaneID
        /// Panes to join, in the order they must land for `select-layout` to
        /// map them onto the saved geometry.
        public let join: [TmuxPaneID]
        public let layout: String?
        public let name: String
    }

    /// Reconcile the snapshot against the panes that are actually still alive
    /// and produce one step per window worth rebuilding.
    ///
    /// Panes closed while the session was rearranged simply drop out; panes
    /// created in the meantime are unknown to the snapshot and are left alone
    /// in their own windows rather than being forced somewhere arbitrary. A
    /// window whose panes are all gone produces no step. A window reduced to a
    /// single surviving pane still produces a step (with no joins) so its name
    /// can be restored.
    ///
    /// `select-layout` assigns panes to geometry slots by their order in the
    /// window and ignores the pane ids embedded in the layout string, so the
    /// join order here IS the geometry mapping — get it wrong and every pane
    /// lands in the wrong cell.
    public func restorePlan(livePanes: Set<TmuxPaneID>) -> [RestoreStep] {
        windows.compactMap { window in
            let survivors = window.panes.filter { livePanes.contains($0) }
            guard let base = survivors.first else { return nil }
            // A layout string describes the pane count at capture time; if any
            // pane is gone it no longer fits and tmux would reject or misapply
            // it. Dropping to nil lets the caller fall back to an even layout.
            let usableLayout = survivors.count == window.panes.count ? window.layout : nil
            return RestoreStep(
                base: base,
                join: Array(survivors.dropFirst()),
                layout: usableLayout,
                name: window.name
            )
        }
    }
}
