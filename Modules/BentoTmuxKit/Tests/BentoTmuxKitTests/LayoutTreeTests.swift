import Testing
@testable import BentoTmuxKit

@Suite("Layout tree round-trip (BUG-005 mobile)")
struct LayoutTreeRoundTripTests {
    // Real layouts captured from tmux at various sizes (see the shell repro).
    static let layouts = [
        // 4-pane tiled @44x90 (iPhone-ish portrait)
        "4648,44x90,0,0[44x44,0,0{21x44,0,0,0,22x44,22,0,1},44x45,0,45{21x45,0,45,2,22x45,22,45,3}]",
        // 3-pane @50x20 (small)
        "fe33,50x20,0,0{25x20,0,0,0,24x20,26,0[24x10,26,0,1,24x9,26,11,2]}",
        // 2-pane horizontal @200x50 (desktop) — real capture
        "cf3a,200x50,0,0{100x50,0,0,0,99x50,101,0,1}",
    ]

    @Test func serializeRoundTripsIdentically() {
        for original in Self.layouts {
            guard let tree = TmuxLayoutTree.parse(original) else {
                Issue.record("parse returned nil for \(original)")
                continue
            }
            let round = TmuxLayoutTree.serialize(tree)
            #expect(round == original, "round-trip mismatch:\n  in:  \(original)\n  out: \(round)")
        }
    }
}
