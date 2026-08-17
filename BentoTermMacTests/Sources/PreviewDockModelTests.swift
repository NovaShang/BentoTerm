import Foundation
import Testing
import BentoFilePreviewKit
@testable import BentoTerm

/// The dock's tab bookkeeping — in particular what happens when there are too
/// many tabs to see, which is how people arrive at "close the others".
@Suite @MainActor struct PreviewDockModelTests {

    /// `isLocal: false` on purpose: a local context starts a file watcher per
    /// tab, and this suite is about the list, not the filesystem.
    private func context() -> PathPreviewContext {
        PathPreviewContext(source: LocalFileSource(), cwd: { nil },
                           hostLabel: "test", isLocal: false)
    }

    private func model(files: [String]) -> PreviewDockModel {
        let m = PreviewDockModel()
        for path in files { m.open(path: path, line: nil, context: context()) }
        return m
    }

    @Test func openingSelectsTheNewTab() {
        let m = model(files: ["/a.txt", "/b.txt"])
        #expect(m.tabs.count == 2)
        #expect(m.selectedID == "/b.txt")
    }

    @Test func reopeningAFileFocusesItRatherThanDuplicating() {
        let m = model(files: ["/a.txt", "/b.txt", "/a.txt"])
        #expect(m.tabs.count == 2)
        #expect(m.selectedID == "/a.txt")
    }

    @Test func closeOthersKeepsOneAndSelectsIt() {
        let m = model(files: ["/a.txt", "/b.txt", "/c.txt"])
        m.closeAll(except: "/b.txt")
        #expect(m.tabs.map(\.id) == ["/b.txt"])
        #expect(m.selectedID == "/b.txt")
    }

    @Test func closeAllFallsBackToTheTreeTab() {
        let m = model(files: ["/a.txt", "/b.txt"])
        m.closeAll(except: nil)
        #expect(m.tabs.isEmpty)
        // The tree tab is permanent, so "no files open" still has a selection —
        // a nil here would render an empty panel with nothing selected.
        #expect(m.selectedID == PreviewDockModel.treeTabID)
    }

    @Test func closingTheSelectedTabLandsOnItsNeighbour() {
        let m = model(files: ["/a.txt", "/b.txt", "/c.txt"])
        m.selectedID = "/b.txt"
        m.close("/b.txt")
        #expect(m.tabs.map(\.id) == ["/a.txt", "/c.txt"])
        #expect(m.selectedID == "/c.txt", "the tab that slid into the closed one's place")
    }

    @Test func closingAnUnselectedTabLeavesTheSelectionAlone() {
        let m = model(files: ["/a.txt", "/b.txt", "/c.txt"])
        m.selectedID = "/c.txt"
        m.close("/a.txt")
        #expect(m.selectedID == "/c.txt")
    }

    @Test func closeOthersOnATabThatIsNotSelectedStillSelectsTheSurvivor() {
        // Right-clicking a tab and choosing "Close Others" acts on THAT tab,
        // so the survivor becomes the selection wherever it started.
        let m = model(files: ["/a.txt", "/b.txt", "/c.txt"])
        m.selectedID = "/c.txt"
        m.closeAll(except: "/a.txt")
        #expect(m.tabs.map(\.id) == ["/a.txt"])
        #expect(m.selectedID == "/a.txt")
    }
}
