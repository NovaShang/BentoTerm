import CoreGraphics
import Testing
import BentoFoundationKit
@testable import BentoGhosttyKit

struct GhosttyCellGeometryTests {
    /// 16×32 px cells on a 2× display: 8×16 points.
    private let size = TerminalSurfaceSize(columns: 80, rows: 24, cellWidthPx: 16, cellHeightPx: 32)

    @Test func cellSizeDividesPixelsByScale() {
        #expect(GhosttyCellGeometry.cellSize(size, scale: 2) == CGSize(width: 8, height: 16))
    }

    @Test func noCellSizeBeforeTheEngineReportsOne() {
        #expect(GhosttyCellGeometry.cellSize(nil, scale: 2) == nil)
        let empty = TerminalSurfaceSize(columns: 0, rows: 0, cellWidthPx: 0, cellHeightPx: 0)
        #expect(GhosttyCellGeometry.cellSize(empty, scale: 2) == nil)
        #expect(GhosttyCellGeometry.cellSize(size, scale: 0) == nil)
    }

    @Test func cellUnderPointIsOneBased() {
        let origin = GhosttyCellGeometry.cell(at: .zero, size: size, scale: 2)
        #expect(origin.col == 1 && origin.row == 1)
        // x 17pt = third cell (8pt wide), y 16pt = exactly the second row's top.
        let c = GhosttyCellGeometry.cell(at: CGPoint(x: 17, y: 16), size: size, scale: 2)
        #expect(c.col == 3 && c.row == 2)
    }

    @Test func cellFallsBackToTopLeftWithoutASize() {
        let c = GhosttyCellGeometry.cell(at: CGPoint(x: 500, y: 500), size: nil, scale: 2)
        #expect(c.col == 1 && c.row == 1)
    }

    @Test func accumulatorKeepsTheRemainder() {
        var acc = ScrollRowAccumulator()
        #expect(acc.rows(adding: 10, rowHeight: 16) == 0)
        #expect(acc.rows(adding: 10, rowHeight: 16) == 1)   // 20 → 1 row, 4 left
        #expect(acc.rows(adding: 28, rowHeight: 16) == 2)   // 32 → 2 rows
        #expect(acc.rows(adding: -16, rowHeight: 16) == -1)
    }

    @Test func accumulatorResetDropsLeftoverTravel() {
        var acc = ScrollRowAccumulator()
        _ = acc.rows(adding: 15, rowHeight: 16)
        acc.reset()
        #expect(acc.rows(adding: 2, rowHeight: 16) == 0)
    }

    @Test func linkResolverPrefersTheEngine() {
        var scraped = false
        let url = SurfaceLinkResolver.url(engine: "https://a.example") {
            scraped = true
            return ("see https://b.example", 6)
        }
        #expect(url == "https://a.example")
        #expect(!scraped)
    }

    @Test func linkResolverFallsBackToTheScreen() {
        let url = SurfaceLinkResolver.url(engine: nil) { ("see https://b.example now", 8) }
        #expect(url == "https://b.example")
        #expect(SurfaceLinkResolver.url(engine: nil) { nil } == nil)
    }
}
