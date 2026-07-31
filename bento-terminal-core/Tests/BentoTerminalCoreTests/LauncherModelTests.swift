#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
@testable import BentoTerminalCore

/// The empty state's structure, without a window.
///
/// Everything the launcher decides — which sections appear, which column they
/// land in, in what order, what a row would do, how recents collapse, when
/// there is nothing left to open, and when the two columns fold into one — is
/// in `LauncherModel` and `LauncherLayout`, precisely so it can be checked here
/// rather than by looking at a screenshot. The view then only draws what these
/// tests assert.
@MainActor
private func model(sessions: [String] = [], hosts: [String] = [],
                   launches: [LaunchRecord] = [],
                   info: [String: LocalSessionInfo] = [:]) -> LauncherModel {
    LauncherModel(provider: OpenTargetProvider(
        sessions: { sessions }, sshHosts: { hosts }, launches: { launches },
        sessionInfo: { info }))
}

@Suite @MainActor struct LauncherModelTests {
    @Test func theLeftColumnIsTheVerbsAndTheRightIsWhatAlreadyExists() {
        // The column split is the decision, so it is asserted rather than
        // described: make-something on the left (with the brand above it),
        // go-back-to-something on the right.
        let m = model(sessions: ["bento", "session-2"],
                      hosts: ["dev"],
                      launches: [LaunchRecord(dir: "/Users/x/code/app", command: "claude")])
        #expect(m.actions.map(\.title) == ["New Terminal without tmux",
                                           "New Agent Session…",
                                           "New Empty Session"])
        #expect(m.leftRows.map(\.title) == ["New Terminal without tmux",
                                            "New Agent Session…",
                                            "New Empty Session",
                                            "SSH"])
        #expect(m.leftRows.allSatisfy { $0.column == .left })
        #expect(m.rightRows.map(\.title) == ["bento", "session-2", "claude  ·  /Users/x/code/app"])
        #expect(m.rightRows.allSatisfy { $0.column == .right })
    }

    @Test func theSSHRowStandsForTheWholeConfigAndSaysHowBigItIs() {
        let m = model(hosts: (1...16).map { "host\($0)" })
        #expect(m.sshMenuRow.subtitle == "16 hosts in ~/.ssh/config")
        #expect(m.sshMenuRow.action == .sshMenu)
        // Singular, because "1 hosts" is the kind of thing a reader notices.
        #expect(model(hosts: ["dev"]).sshMenuRow.subtitle == "1 host in ~/.ssh/config")
    }

    @Test func noSSHConfigMeansNoSSHRow() {
        let m = model(sessions: ["bento"])
        #expect(!m.hasHosts)
        #expect(m.leftRows.count == 3)
    }

    @Test func theSSHRowNamesTheSameTwoThingsTheToolbarMenuDoes() {
        // One concept, one name: the launcher's row opens the New ⌄ menu's own
        // items, so if either title moves this fails rather than drifting.
        let m = model(hosts: ["dev"])
        let dump = m.structureDump()
        #expect(dump.contains(SSHHostMenu.connectTitle))
        #expect(dump.contains(SSHHostMenu.remoteTmuxTitle))
    }

    @Test func recentsShowThreeAndExpandToTheRest() {
        let launches = (1...5).map { LaunchRecord(dir: "/Users/x/p\($0)", command: "claude") }
        let m = model(launches: launches)
        #expect(m.recents.count == LauncherModel.recentPreviewLimit)
        #expect(m.hasHiddenRecents)
        #expect(m.recentsExpanderRow.title == "2 more")
        #expect(m.rightRows.contains { $0.id == "recents:expand" })

        m.expandRecents()
        #expect(m.recents.count == 5)
        #expect(!m.hasHiddenRecents)
    }

    @Test func aSessionRowSaysHowManyWindowsAndHowStale() {
        let now = Date()
        let m = model(sessions: ["bento"],
                      info: ["bento": LocalSessionInfo(name: "bento", windowCount: 2,
                                                       lastActivity: now.addingTimeInterval(-300))])
        #expect(m.sessions.first?.subtitle == "2 windows  ·  5m ago")
    }

    @Test func aSessionThePollHasNotDescribedYetIsStillARow() {
        // The name list is the authority on what exists; the info map only
        // decorates. A session created a second ago must not vanish.
        let m = model(sessions: ["fresh"])
        #expect(m.sessions.map(\.title) == ["fresh"])
        #expect(m.sessions.first?.subtitle == nil)
    }

    @Test func hostsAloneDoNotEarnARightColumn() {
        // Half an empty block beside a centred left column reads as a layout
        // that failed to load, so that page is one column — the hosts are in
        // the left column's menu and there is genuinely nothing to put beside
        // it.
        let m = model(hosts: ["dev", "orb"])
        #expect(!m.isEmpty)
        #expect(!m.hasRightColumn)
        #expect(m.rightRows.isEmpty)
        #expect(m.structureDump().contains("[right] <not drawn>"))
    }

    @Test func anythingRunningOrRecentEarnsARightColumn() {
        #expect(model(sessions: ["bento"]).hasRightColumn)
        #expect(model(launches: [LaunchRecord(dir: "/Users/x/p", command: "vim")]).hasRightColumn)
    }

    @Test func nothingToOpenStillOffersTheThreeWaysToMakeSomething() {
        // The bare-machine case is not a different screen: the verbs are
        // unconditional, so what "empty" costs is one explanatory line where
        // section headers would otherwise stand over nothing.
        let m = model()
        #expect(m.isEmpty)
        #expect(m.leftRows.map(\.id) == LaunchAction.displayOrder.map(\.id))
        #expect(!m.hasRightColumn)
        #expect(m.structureDump().contains("nothing to open"))
    }

    @Test func everyRowSaysWhatItWouldDo() {
        let m = model(sessions: ["bento"], hosts: ["dev"],
                      launches: [LaunchRecord(dir: "/Users/x/code/app", command: "claude")])
        let dump = m.structureDump()
        #expect(dump.contains("attach local session bento in place"))
        #expect(dump.contains("running claude, in place"))
        #expect(dump.contains("plain local shell, no tmux, in place"))
        #expect(dump.contains("open the agent wizard (launcher stays)"))
        #expect(dump.contains("logo + BentoTerm"))
    }
}

@Suite struct LauncherLayoutTests {
    @Test func theBlockIsCentredAndCapped() {
        // A 2544pt window must not stretch the block across it; the columns
        // would read as two unrelated lists.
        let wide = LauncherLayout.blockWidth(contentWidth: 2544, twoColumn: true)
        #expect(wide == LauncherLayout.twoColumnMaxWidth)
        #expect(LauncherLayout.blockOriginX(contentWidth: 2544, blockWidth: wide)
                == (2544 - wide) / 2)
    }

    @Test func twoColumnsFoldToOneBelowTheBreakpoint() {
        #expect(LauncherLayout.foldWidth == 764)
        #expect(LauncherLayout.isTwoColumn(contentWidth: 764, hasRightColumn: true))
        #expect(!LauncherLayout.isTwoColumn(contentWidth: 763, hasRightColumn: true))
        // Nothing to put on the right → one column at any width.
        #expect(!LauncherLayout.isTwoColumn(contentWidth: 2000, hasRightColumn: false))
    }

    @Test func theBlockNeverExceedsTheWindowItIsIn() {
        // The window can be dragged to anything; the block has to survive the
        // narrow end without clipping or negative widths.
        for width in stride(from: 200.0, through: 3000.0, by: 37.0) {
            let two = LauncherLayout.isTwoColumn(contentWidth: width, hasRightColumn: true)
            let block = LauncherLayout.blockWidth(contentWidth: width, twoColumn: two)
            #expect(block >= 0)
            #expect(block <= max(0, width - 2 * LauncherLayout.outerPadding))
            // At the fold and above, both columns still have their minimum.
            if two { #expect(block >= LauncherLayout.twoColumnMinWidth) }
        }
    }
}

@Suite struct LocalSessionInfoTests {
    @Test func relativeTimeIsBucketed() {
        let now = Date()
        #expect(LocalSessionInfo.relative(now.addingTimeInterval(-5), now: now) == "just now")
        #expect(LocalSessionInfo.relative(now.addingTimeInterval(-90), now: now) == "1m ago")
        #expect(LocalSessionInfo.relative(now.addingTimeInterval(-7200), now: now) == "2h ago")
        #expect(LocalSessionInfo.relative(now.addingTimeInterval(-3 * 86400), now: now) == "3d ago")
    }

    @Test func oneWindowIsSingular() {
        let now = Date()
        let one = LocalSessionInfo(name: "x", windowCount: 1, lastActivity: now)
        #expect(one.subtitle(now: now) == "1 window  ·  just now")
    }

    @Test func nothingKnownMeansNoSubtitleRatherThanAnEmptyOne() {
        #expect(LocalSessionInfo(name: "x", windowCount: 0, lastActivity: nil).subtitle() == nil)
        // tmux occasionally reports no activity time at all.
        #expect(LocalSessionInfo(name: "x", windowCount: 0,
                                 lastActivity: .distantPast).subtitle() == nil)
    }
}
#endif
