import XCTest
@testable import BentoAgentKit

/// What Settings' rule editor promises, held to.
///
/// Two of these guard a silent-loss bug rather than a wrong color: an edit that
/// gets overwritten on the next launch, or an off switch that quietly freezes
/// an agent on the rules it had the day it was switched off.
final class RuleCustomizationTests: XCTestCase {

    /// A user rule outranks every built-in for that agent — the whole point of
    /// "add what your agent shows", since the built-ins already didn't cover it.
    func testCustomRulePriorityIsAboveEveryBuiltIn() {
        for set in AgentRuleSet.builtIns {
            for rule in set.rules {
                XCTAssertLessThan(rule.priority, AgentRuleSet.customRulePriority,
                                  "\(set.id)/\(rule.id) sits at or above the priority reserved for user rules")
            }
        }
    }

    func testCustomRuleWinsOverBuiltInVerdict() {
        var set = AgentRuleSet.opencode
        // opencode's own footer would read this screen as idle.
        let screen = "  ⬝⬝  building     14.2K (1%)  ctrl+p commands"
        let before = AgentDetector(ruleSets: [set]).classify(set, title: "", snapshot: screen)
        XCTAssertEqual(before?.status, .idle)

        set.rules.append(DetectRule(id: "custom-1", status: .blocked,
                                    priority: AgentRuleSet.customRulePriority,
                                    region: .wholeSnapshot,
                                    clause: .contains(["building"]),
                                    isCustom: true))
        let after = AgentDetector(ruleSets: [set]).classify(set, title: "", snapshot: screen)
        XCTAssertEqual(after?.status, .blocked)
        XCTAssertEqual(after?.ruleID, "custom-1")
    }

    func testDisabledRuleIsSkipped() {
        var set = AgentRuleSet.opencode
        let screen = "△ Permission required\n$ rm -rf build"
        XCTAssertEqual(AgentDetector(ruleSets: [set]).classify(set, title: "", snapshot: screen)?.status,
                       .blocked)

        for i in set.rules.indices where set.rules[i].id == "permission_required" {
            set.rules[i].isEnabled = false
        }
        XCTAssertNotEqual(AgentDetector(ruleSets: [set]).classify(set, title: "", snapshot: screen)?.status,
                          .blocked, "a switched-off rule must not decide anything")
    }

    func testDisabledAgentIsNotIdentifiedAtAll() {
        var set = AgentRuleSet.opencode
        XCTAssertNotNil(AgentDetector(ruleSets: [set]).ruleSet(command: "opencode", title: ""))
        set.isEnabled = false
        XCTAssertNil(AgentDetector(ruleSets: [set]).ruleSet(command: "opencode", title: ""),
                     "detection off means the pane falls through to activity detection")
    }

    // MARK: - Editing an existing rule
    //
    // The point of the editor: when an agent changes its wording, the fix is a
    // text field, not an app release. These exercise the operations the clause
    // editor is built out of.

    /// The exact failure that shipped: opencode renamed its footer from
    /// "esc to interrupt" to "esc interrupt" and working detection died. A user
    /// with the old build must be able to repair that rule by hand.
    func testUserCanRepairAStaleWordingWithoutAnAppUpdate() {
        // The rule as it was before the fix — matching only the old wording.
        var stale = AgentRuleSet.opencode
        let i = stale.rules.firstIndex { $0.id == "interrupt_hint_working" }!
        stale.rules[i].clause = .containsAny(["esc to interrupt"])
        stale.rules.removeAll { $0.id == "progress_bar_working" }

        let footer = "  ⬝⬝  building the thing     esc interrupt      ctrl+p commands"
        XCTAssertNotEqual(stale.evaluate(command: "opencode", title: "", screen: footer).status,
                          .working, "precondition: the stale rule misses the new wording")

        // What the editor does when you add a term to that rule's condition.
        let repaired = stale.rules[i].clause.with(terms: stale.rules[i].clause.terms + ["esc interrupt"])
        stale.rules[i].clause = repaired

        let trial = stale.evaluate(command: "opencode", title: "", screen: footer)
        XCTAssertEqual(trial.status, .working)
        XCTAssertEqual(trial.ruleID, "interrupt_hint_working")
    }

    func testEditingATermKeepsEverythingElseAboutTheRule() {
        var rule = AgentRuleSet.opencode.rules.first { $0.id == "permission_required" }!
        let before = (rule.status, rule.priority, rule.region)
        rule.clause = rule.clause.replacingChild(at: 0, with: .contains(["△ 需要授权"]))
        XCTAssertEqual(rule.status, before.0)
        XCTAssertEqual(rule.priority, before.1)
        XCTAssertEqual(rule.region, before.2)
        XCTAssertTrue(rule.clause.summary.contains("需要授权"))
    }

    /// A rule that specifies nothing must match nothing. The editor can leave a
    /// rule half-written (you add a condition, then go look up the wording),
    /// and user rules sit ABOVE every built-in — a vacuously-true clause there
    /// would paint every pane of that agent.
    func testAnEmptyConditionMatchesNothing() {
        let screen = "anything at all\nsecond line"
        for clause: MatchClause in [.contains([]), .contains([""]), .containsAny([]),
                                    .all([]), .regex(""), .lineRegex("")] {
            var set = AgentRuleSet.opencode
            set.rules = [DetectRule(id: "blank", status: .blocked,
                                    priority: AgentRuleSet.customRulePriority,
                                    region: .wholeSnapshot, clause: clause, isCustom: true)]
            XCTAssertNil(set.evaluate(command: "opencode", title: "", screen: screen).ruleID,
                         "clause \(clause.summary) matched a screen it says nothing about")
        }
    }

    func testNegationRoundTrips() {
        let leaf = MatchClause.contains(["esc to cancel"])
        XCTAssertFalse(leaf.isNegated)
        let negated = leaf.negated(true)
        XCTAssertTrue(negated.isNegated)
        XCTAssertEqual(negated.kind, .contains, "a negated clause still reports what it negates")
        XCTAssertFalse(negated.negated(false).isNegated)

        // Editing terms through a negation must not drop it.
        let edited = negated.with(terms: ["esc to quit"])
        XCTAssertTrue(edited.isNegated)
        XCTAssertEqual(edited.terms, ["esc to quit"])
    }

    func testChangingKindCarriesWhatItCan() {
        let text = MatchClause.contains(["allow once", "reject"])
        XCTAssertEqual(text.converted(to: .containsAny).terms, ["allow once", "reject"])
        XCTAssertEqual(text.converted(to: .regex).terms, ["allow once"],
                       "a pattern holds one term — keep the first rather than losing everything")

        // A leaf promoted to a group keeps itself as the first branch, so
        // nothing the user typed disappears when they add an "or".
        let group = text.converted(to: .any)
        XCTAssertEqual(group.kind, .any)
        XCTAssertEqual(group.children.count, 1)
        XCTAssertEqual(group.children[0].terms, ["allow once", "reject"])
    }

    func testRemovingTheSecondToLastBranchCollapsesTheGroup() {
        let group = MatchClause.any([.contains(["a"]), .contains(["b"]), .contains(["c"])])
        let two = group.removingChild(at: 2)
        XCTAssertEqual(two.children.count, 2)
        let one = two.removingChild(at: 1)
        XCTAssertEqual(one.kind, .contains, "a one-branch group is just that branch")
        XCTAssertEqual(one.terms, ["a"])
    }

    func testAddingAndReplacingBranchesInANestedTree() {
        // A shape taken from claude's real permission rule: all(any(...), ...).
        var clause = MatchClause.all([
            .containsAny(["do you want to proceed?"]),
            .any([.lineRegex("^1\\. yes"), .lineRegex("^2\\. no")]),
        ])
        clause = clause.replacingChild(at: 1, with: clause.children[1].addingChild(.lineRegex("^3\\. no")))
        XCTAssertEqual(clause.children[1].children.count, 3)
        XCTAssertEqual(clause.kind, .all, "editing a branch must not reshape its parent")
    }

    /// The tester in Settings answers with the real engine, including the part
    /// people actually get stuck on: whether the pane is recognized at all.
    func testTrialReportsHowThePaneWasRecognized() {
        let codex = AgentRuleSet.codex
        XCTAssertEqual(codex.evaluate(command: "codex", title: "", screen: nil).identity, .command)
        XCTAssertEqual(codex.evaluate(command: "node", title: "⠴ work", screen: nil).identity, .title)
        XCTAssertEqual(codex.evaluate(command: "node", title: "work",
                                      screen: "Welcome to Codex").identity, .screen)
        XCTAssertEqual(codex.evaluate(command: "node", title: "work",
                                      screen: "npm run dev").identity, .unrecognized)
    }

    /// Rules edited in Settings survive a decode/encode round trip, including
    /// the fields that were added after profiles were already stored on disk.
    func testEditedRulesRoundTripThroughStorage() throws {
        var set = AgentRuleSet.codex
        set.rules.append(DetectRule(id: "custom-2", status: .working,
                                    priority: AgentRuleSet.customRulePriority,
                                    region: .oscTitle, clause: .regex("busy"),
                                    isCustom: true))
        set.screenIdentity.append("my own banner")
        set.isEnabled = false

        let profile = StateProfile(id: "codex", name: "Codex", outputPatterns: [],
                                   commandPattern: "codex", quickKeys: [], isBuiltIn: true,
                                   agentRules: set, agentRulesCustomized: true)
        let data = try JSONEncoder().encode([profile])
        let back = try JSONDecoder().decode([StateProfile].self, from: data)

        let rules = try XCTUnwrap(back.first?.agentRules)
        XCTAssertTrue(back[0].agentRulesCustomized)
        XCTAssertFalse(rules.isEnabled)
        XCTAssertEqual(rules.screenIdentity.last, "my own banner")
        let custom = try XCTUnwrap(rules.rules.first { $0.id == "custom-2" })
        XCTAssertTrue(custom.isCustom)
        XCTAssertTrue(custom.isEnabled)
    }

    /// Profiles written by an older build have no `isEnabled`/`isCustom`/
    /// `screenIdentity` keys at all. Decoding must fill them in rather than
    /// throw — a throw here fails the WHOLE profile array, and ProfileStore
    /// responds to that by reseeding, which would drop the user's own profiles.
    func testProfileStoredBeforeTheseFieldsStillDecodes() throws {
        let legacy = """
        [{
          "id": "codex", "name": "Codex", "outputPatterns": [], "titlePatterns": [],
          "commandPattern": "codex", "quickKeys": [], "isBuiltIn": true,
          "promptBoundary": [],
          "agentRules": {
            "id": "codex", "commandPatterns": ["codex"], "titleIdentity": [],
            "rules": [{
              "id": "title_blocked", "priority": 1100,
              "status": "blocked",
              "region": { "oscTitle": {} },
              "clause": { "contains": { "_0": ["Action Required"] } }
            }]
          }
        }]
        """
        let decoded = try JSONDecoder().decode([StateProfile].self, from: Data(legacy.utf8))
        let rules = try XCTUnwrap(decoded.first?.agentRules)
        XCTAssertTrue(rules.isEnabled)
        XCTAssertEqual(rules.screenIdentity, [])
        XCTAssertTrue(rules.rules[0].isEnabled)
        XCTAssertFalse(rules.rules[0].isCustom)
        XCTAssertFalse(decoded[0].agentRulesCustomized)
    }

    /// The refresh that delivers new built-in rules must not undo an edit…
    @MainActor
    func testCustomizedProfileKeepsItsRulesAcrossRefresh() {
        let store = ProfileStore.shared
        let original = store.profiles

        defer { store.profiles = original; store.save() }

        var edited = AgentRuleSet.opencode
        edited.rules.append(DetectRule(id: "custom-3", status: .blocked,
                                       priority: AgentRuleSet.customRulePriority,
                                       region: .wholeSnapshot,
                                       clause: .contains(["my marker"]), isCustom: true))
        store.updateRules(edited, for: "opencode")
        XCTAssertTrue(store.profiles.first { $0.id == "opencode" }?.agentRulesCustomized ?? false)

        store.applyBuiltInRefreshForTesting()
        let after = store.profiles.first { $0.id == "opencode" }?.agentRules
        XCTAssertNotNil(after?.rules.first { $0.id == "custom-3" },
                        "a refresh must not overwrite rules the user edited")

        store.resetRules(for: "opencode")
        let reset = store.profiles.first { $0.id == "opencode" }
        XCTAssertNil(reset?.agentRules?.rules.first { $0.id == "custom-3" })
        XCTAssertFalse(reset?.agentRulesCustomized ?? true)
    }

    /// …but switching an agent OFF is a preference, not an edit: it survives
    /// the refresh while the rules themselves stay current.
    @MainActor
    func testDetectionSwitchSurvivesRefreshWithoutFreezingRules() {
        let store = ProfileStore.shared
        let original = store.profiles
        defer { store.profiles = original; store.save() }

        store.setDetectionEnabled(false, for: "opencode")
        XCTAssertFalse(store.profiles.first { $0.id == "opencode" }?.agentRulesCustomized ?? true,
                       "turning detection off is not an edit to the rules")

        store.applyBuiltInRefreshForTesting()
        let after = store.profiles.first { $0.id == "opencode" }?.agentRules
        XCTAssertEqual(after?.isEnabled, false, "the off switch must survive a rule refresh")
        XCTAssertEqual(after?.rules.count, AgentRuleSet.opencode.rules.count,
                       "…while the rules themselves stay current")
    }
}
