#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
@testable import BentoTerminalCore

/// The empty state's structure, without a window.
///
/// Everything the launcher decides — which sections appear, in what order, what
/// a row would do, how hosts and recents collapse, what a query does to the
/// pinned create rows, when there is nothing left to open — is in
/// `LauncherModel`, precisely so it can be checked here rather than by looking
/// at a screenshot. The view then only draws what these tests assert.
@MainActor
private func model(sessions: [String] = [], hosts: [String] = [],
                   launches: [LaunchRecord] = [],
                   info: [String: LocalSessionInfo] = [:]) -> LauncherModel {
    LauncherModel(provider: OpenTargetProvider(
        sessions: { sessions }, sshHosts: { hosts }, launches: { launches },
        sessionInfo: { info }))
}

@Suite @MainActor struct LauncherModelTests {
    @Test func theThreeCreateRowsComeFirstAndTheQuickShellLeadsThem() {
        // Order is the decision, so it is asserted rather than described:
        // throwaway shell, agent session, empty session, and only then the
        // things that already exist. The Dock menu renders the same list from
        // the same `LaunchAction.displayOrder`.
        let m = model(sessions: ["bento", "session-2"],
                      hosts: ["dev"],
                      launches: [LaunchRecord(dir: "/Users/x/code/app", command: "claude")])
        #expect(m.actions.map(\.title) == ["New Terminal without tmux",
                                           "New Agent Session…",
                                           "New Empty Session"])
        #expect(m.sessions.map(\.title) == ["bento", "session-2"])
        #expect(m.recents.map(\.title) == ["claude  ·  /Users/x/code/app"])
        #expect(m.hosts.map(\.title) == ["dev"])
        #expect(m.focusableRows.map(\.section).first == .actions)
        // ⌘N ⏎ is a throwaway shell.
        #expect(m.selectedID == LaunchAction.plainTerminal.id)
    }

    @Test func aQueryPinsTheActionsButNeverSelectsOneOverAMatch() {
        // Typing must not turn a search into a creation: the create rows stay
        // put (they are the page's verbs, not a list to hunt through) while ⏎
        // follows the match.
        let m = model(sessions: ["bento"], hosts: ["dev"])
        m.query = "bento"
        #expect(m.actions.count == 3)
        #expect(m.selectedID == "session:bento")
        #expect(m.focusableRows.first?.id == LaunchAction.plainTerminal.id)
    }

    @Test func aQueryThatMatchesNothingOpenableFallsBackToTheNamedAction() {
        let m = model(sessions: ["bento"])
        m.query = "agent"
        #expect(m.sessions.isEmpty)
        #expect(m.selectedID == LaunchAction.agentSession.id)
    }

    @Test func recentsShowThreeAndExpandToTheRest() {
        let launches = (1...5).map { LaunchRecord(dir: "/Users/x/p\($0)", command: "claude") }
        let m = model(launches: launches)
        #expect(m.recents.count == LauncherModel.recentPreviewLimit)
        #expect(m.hasHiddenRecents)
        #expect(m.recentsExpanderRow.title == "2 more")
        #expect(m.focusableRows.contains { $0.id == "recents:expand" })

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

    @Test func hostsCollapseToChipsUntilExpandedOrFiltered() {
        let aliases = (1...16).map { "host\($0)" }
        let m = model(sessions: ["bento"], hosts: aliases)
        #expect(m.hostsCollapsed)
        #expect(m.hostChips.count == LauncherModel.hostChipLimit)
        #expect(m.hasHiddenHostChips)
        #expect(m.hostsExpanderRow.title == "16 hosts")
        // Collapsed, the whole section contributes ONE keyboard stop — after
        // the three create rows, which are always there.
        #expect(m.focusableRows.map(\.id)
                == LaunchAction.displayOrder.map(\.id) + ["session:bento", "hosts:expand"])

        m.expandHosts()
        #expect(!m.hostsCollapsed)
        #expect(m.focusableRows.count == 3 + 1 + 16)
    }

    @Test func typingExpandsHostsWithoutAsking() {
        let m = model(sessions: ["bento"], hosts: ["dev", "orb"])
        m.query = "orb"
        #expect(!m.hostsCollapsed)
        #expect(m.sessions.isEmpty)
        #expect(m.hosts.map(\.title) == ["orb"])
        #expect(m.selectedID == "ssh:orb")
    }

    @Test func filteringUsesThePalettesOwnScorer() {
        // Not "some fuzzy matcher" — THE one ⌘P uses, so a query narrows to the
        // same rows in the same order on both surfaces. Asserted against the
        // scorer itself rather than a hand-picked winner, because the ranking's
        // quirks (a word-boundary hit beats a long consecutive run) belong to
        // `PaletteFuzzy` and are its tests' business, not this one's.
        let names = ["bento-term", "bentobox", "b-e-n-t-o", "unrelated"]
        let m = model(sessions: names)
        m.query = "bento"
        let expected = names
            .compactMap { name -> (Int, String)? in
                PaletteFuzzy.score(query: "bento", target: "session \(name)").map { ($0, name) }
            }
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            .map(\.1)
        #expect(m.sessions.map(\.title) == expected)
        #expect(!m.sessions.contains { $0.title == "unrelated" })
    }

    @Test func clearingTheQueryRestoresTheProviderOrder() {
        let m = model(sessions: ["alpha", "beta"], hosts: ["dev"])
        m.query = "b"
        m.query = ""
        #expect(m.sessions.map(\.title) == ["alpha", "beta"])
        #expect(m.hostsCollapsed)
    }

    @Test func selectionSurvivesARefreshAndWrapsAtTheEnds() {
        let m = model(sessions: ["a", "b"], hosts: [])
        #expect(m.selectedID == LaunchAction.plainTerminal.id)
        m.moveSelection(-1)   // wrap up from the first row to the last
        #expect(m.selectedID == "session:b")
        m.moveSelection(1)
        #expect(m.selectedID == LaunchAction.plainTerminal.id)
        m.moveSelection(3)
        #expect(m.selectedID == "session:a")
        m.refresh()
        #expect(m.selectedID == "session:a")
    }

    @Test func selectionMovesOffARowThatDisappeared() {
        let m = model(sessions: ["alpha", "beta"])
        m.moveSelection(4)
        #expect(m.selectedID == "session:beta")
        m.query = "alpha"
        #expect(m.selectedID == "session:alpha")
    }

    @Test func nothingToOpenStillOffersTheThreeWaysToMakeSomething() {
        // The bare-machine case is no longer a different screen: the verbs are
        // unconditional, so what "empty" costs is one explanatory line where
        // three section headers would otherwise stand over nothing.
        let m = model()
        #expect(m.isEmpty)
        #expect(m.focusableRows.map(\.id) == LaunchAction.displayOrder.map(\.id))
        #expect(m.structureDump().contains("nothing to open"))
    }

    @Test func noMatchesIsNotTheSameAsNothingToOpen() {
        // A filter that matches nothing must not claim the machine is empty —
        // the one-line treatment is reserved for a genuinely bare install.
        let m = model(sessions: ["bento"])
        m.query = "zzzz"
        #expect(!m.isEmpty)
        #expect(m.sessions.isEmpty)
        #expect(m.focusableRows.map(\.id) == LaunchAction.displayOrder.map(\.id))
    }

    @Test func everyRowSaysWhatItWouldDo() {
        let m = model(sessions: ["bento"], hosts: ["dev"],
                      launches: [LaunchRecord(dir: "/Users/x/code/app", command: "claude")])
        m.expandHosts()
        let dump = m.structureDump()
        #expect(dump.contains("attach local session bento in place"))
        #expect(dump.contains("ssh dev in place"))
        #expect(dump.contains("running claude, in place"))
        #expect(dump.contains("actions: [ssh] [tmux]"))
        #expect(dump.contains("plain local shell, no tmux, in place"))
        #expect(dump.contains("open the agent wizard (launcher stays)"))
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
