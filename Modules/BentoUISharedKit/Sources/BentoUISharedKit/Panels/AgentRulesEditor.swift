import SwiftUI
import BentoAgentKit

/// The detection rules, opened up and made editable.
///
/// Pane color is pattern matching against what an agent draws on screen, and
/// agents redraw themselves without asking us — opencode changed "esc to
/// interrupt" to "esc interrupt" and every opencode pane went quiet. So the
/// rules are not a sealed table: every one of them can be read, switched off,
/// **edited**, deleted, or written from scratch, and tried against a screen you
/// paste in before you trust it.
///
/// **Reading still comes first.** Most people who open this are answering "why
/// is this pane green?", not authoring a rule engine. So the list stays a list
/// of sentences in the order the engine tries them, and all the editing lives
/// one tap deeper, in `RuleEditorView`.
///
/// Anything edited here stops taking shipped rule updates for that agent
/// (`agentRulesCustomized`) until it's reset — otherwise the next release would
/// quietly overwrite the fix you just made.
public struct AgentRulesListView: View {
    @ObservedObject private var store = ProfileStore.shared

    public init() {}

    private var agents: [StateProfile] {
        store.profiles.filter { $0.agentRules != nil }
    }

    public var body: some View {
        List {
            Section {
                ForEach(agents) { profile in
                    NavigationLink {
                        AgentRuleSetEditor(profileID: profile.id)
                    } label: {
                        row(profile)
                    }
                }
            } footer: {
                PanelNote("""
                    Bento reads each pane's screen every couple of seconds and matches it \
                    against these rules to decide the pane's color. Open one to see what it \
                    looks for — and to fix it when an agent changes its wording.
                    """)
            }
        }
        .navigationTitle("Detection Rules")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func row(_ profile: StateProfile) -> some View {
        let rules = profile.agentRules
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(profile.name)
                if profile.agentRulesCustomized { TagChip("Edited") }
                if !(rules?.isEnabled ?? true) { TagChip("Off") }
            }
            Text(subtitle(rules))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func subtitle(_ rules: AgentRuleSet?) -> String {
        guard let rules else { return "no rules" }
        let active = rules.rules.filter(\.isEnabled).count
        let states = Set(rules.rules.filter(\.isEnabled).compactMap(\.status))
        let covered = AgentStatus.allCases.filter { states.contains($0) }.map(\.label)
        let coverage = covered.isEmpty ? "no states" : covered.joined(separator: " · ")
        return "\(active) rule\(active == 1 ? "" : "s") — \(coverage)"
    }
}

// MARK: - One agent

public struct AgentRuleSetEditor: View {
    let profileID: String

    @ObservedObject private var store = ProfileStore.shared
    @State private var editingRuleID: String?
    @State private var showTrial = false

    public init(profileID: String) {
        self.profileID = profileID
    }

    private var profile: StateProfile? { store.profiles.first { $0.id == profileID } }
    private var rules: AgentRuleSet? { profile?.agentRules }

    /// Every write goes through here: one place that also marks the profile
    /// customized, so an edit can't be silently reverted by the next update.
    private func mutate(_ change: (inout AgentRuleSet) -> Void) {
        guard var set = rules else { return }
        change(&set)
        store.updateRules(set, for: profileID)
    }

    public var body: some View {
        Form {
            if let set = rules {
                detectionSection(set)
                identitySection(set)
                rulesSection(set)
                resetSection()
            } else {
                Text("This profile has no detection rules.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(profile?.name ?? "Rules")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        addRule()
                    } label: {
                        Label("New Rule", systemImage: "plus")
                    }
                    Button {
                        showTrial = true
                    } label: {
                        Label("Try It on a Screen…", systemImage: "text.viewfinder")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(rules == nil)
            }
        }
        .sheet(item: Binding(
            get: { editingRuleID.map(RuleReference.init(id:)) },
            set: { editingRuleID = $0?.id }
        )) { ref in
            if let set = rules, let rule = set.rules.first(where: { $0.id == ref.id }) {
                RuleEditorView(rule: rule) { edited in
                    mutate { set in
                        guard let i = set.rules.firstIndex(where: { $0.id == edited.id }) else { return }
                        set.rules[i] = edited
                    }
                } onDelete: {
                    mutate { set in set.rules.removeAll { $0.id == ref.id } }
                }
            }
        }
        .sheet(isPresented: $showTrial) {
            if let set = rules {
                RuleTrialView(ruleSet: set, agentName: profile?.name ?? "")
            }
        }
    }

    private func addRule() {
        let new = DetectRule(
            id: "custom-\(UUID().uuidString.prefix(8))",
            status: .blocked,
            priority: AgentRuleSet.customRulePriority,
            region: .wholeSnapshot,
            clause: .contains([""]),
            isCustom: true,
            label: "My rule")
        mutate { set in set.rules.append(new) }
        editingRuleID = new.id
    }

    // MARK: Sections

    @ViewBuilder
    private func detectionSection(_ set: AgentRuleSet) -> some View {
        Section {
            Toggle("Detect this agent", isOn: Binding(
                get: { set.isEnabled },
                set: { store.setDetectionEnabled($0, for: profileID) }
            ))
        } footer: {
            PanelNote("""
                Off means panes running this agent are colored by output activity alone — \
                busy or quiet, with no "needs you".
                """)
        }
    }

    @ViewBuilder
    private func identitySection(_ set: AgentRuleSet) -> some View {
        Section {
            PatternRows(title: "Command", patterns: set.commandPatterns) { updated in
                mutate { $0.commandPatterns = updated }
            }
            PatternRows(title: "Window title", patterns: set.titleIdentity) { updated in
                mutate { $0.titleIdentity = updated }
            }
            PatternRows(title: "On screen", patterns: set.screenIdentity) { updated in
                mutate { $0.screenIdentity = updated }
            }
        } header: {
            Text("How Bento recognizes it")
        } footer: {
            PanelNote("""
                Matched against the pane's running command, its window title, and — for \
                agents launched through node or python, whose command name is the runtime's \
                — the screen itself. Once a pane matches, it keeps this agent until the \
                command changes.
                """)
        }
    }

    @ViewBuilder
    private func rulesSection(_ set: AgentRuleSet) -> some View {
        Section {
            ForEach(set.rules.sorted { $0.priority > $1.priority }) { rule in
                // Not a Button wrapping the row: the row carries its own
                // switch, and a Button label eats taps meant for it. The text
                // is the tap target for editing, the switch is its own.
                RuleRow(rule: rule) { enabled in
                    mutate { set in
                        guard let i = set.rules.firstIndex(where: { $0.id == rule.id }) else { return }
                        set.rules[i].isEnabled = enabled
                    }
                } onEdit: {
                    editingRuleID = rule.id
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) {
                        mutate { set in set.rules.removeAll { $0.id == rule.id } }
                    }
                }
                .contextMenu {
                    Button("Edit") { editingRuleID = rule.id }
                    Button("Duplicate") { duplicate(rule) }
                    Button("Delete", role: .destructive) {
                        mutate { set in set.rules.removeAll { $0.id == rule.id } }
                    }
                }
            }
        } header: {
            Text("Rules, in the order they're tried")
        } footer: {
            PanelNote("""
                The first rule that matches decides the pane's state. Tap one to edit it — \
                what it looks for, where, and what it means.
                """)
        }
    }

    /// Duplicating is how you keep a built-in around while trying a variant of
    /// it: the copy is yours, with a new id so both can coexist.
    private func duplicate(_ rule: DetectRule) {
        let copy = DetectRule(id: "custom-\(UUID().uuidString.prefix(8))",
                              status: rule.status, priority: rule.priority,
                              region: rule.region, clause: rule.clause,
                              isEnabled: rule.isEnabled, isCustom: true,
                              label: "\(rule.displayName) copy")
        mutate { set in set.rules.append(copy) }
        editingRuleID = copy.id
    }

    @ViewBuilder
    private func resetSection() -> some View {
        Section {
            Button("Reset to Built-in Rules", role: .destructive) {
                store.resetRules(for: profileID)
            }
            .disabled(!(profile?.agentRulesCustomized ?? false))
        } footer: {
            if profile?.agentRulesCustomized == true {
                PanelNote("Edited — this agent no longer picks up rule updates from new versions of Bento. Resetting restores that, and discards your changes.")
            }
        }
    }
}

/// `sheet(item:)` needs an Identifiable; the rule id alone is the state we keep.
private struct RuleReference: Identifiable { let id: String }

// MARK: - The rule editor

/// One rule, entirely editable: what it means, where it looks, how important it
/// is, and the condition tree itself.
struct RuleEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: DetectRule
    @State private var confirmingDelete = false
    private let onSave: (DetectRule) -> Void
    private let onDelete: () -> Void

    init(rule: DetectRule, onSave: @escaping (DetectRule) -> Void, onDelete: @escaping () -> Void) {
        _draft = State(initialValue: rule)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private enum RegionKind: String, CaseIterable, Identifiable {
        case title, whole, bottom, top, belowDivider, inputBox, belowPrompt
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title:        return "Window title"
            case .whole:        return "Anywhere on screen"
            case .bottom:       return "Bottom lines"
            case .top:          return "Top lines"
            case .belowDivider: return "Below the last divider"
            case .inputBox:     return "Inside the input box"
            case .belowPrompt:  return "Below the last prompt line"
            }
        }
        var takesCount: Bool { self == .bottom || self == .top }

        init(_ region: DetectRegion) {
            switch region {
            case .oscTitle:                self = .title
            case .wholeSnapshot:           self = .whole
            case .bottomNonEmptyLines:     self = .bottom
            case .topNonEmptyLines:        self = .top
            case .afterLastHorizontalRule: self = .belowDivider
            case .promptBoxBody:           self = .inputBox
            case .afterLastPromptMarker:   self = .belowPrompt
            }
        }

        func region(count: Int) -> DetectRegion {
            switch self {
            case .title:        return .oscTitle
            case .whole:        return .wholeSnapshot
            case .bottom:       return .bottomNonEmptyLines(count)
            case .top:          return .topNonEmptyLines(count)
            case .belowDivider: return .afterLastHorizontalRule
            case .inputBox:     return .promptBoxBody
            case .belowPrompt:  return .afterLastPromptMarker
            }
        }
    }

    /// nil status is a real option: "ignore" rules exist so a transcript
    /// overlay or a model picker can't flip a pane's state.
    private enum Meaning: String, CaseIterable, Identifiable {
        case working, blocked, idle, ignore
        var id: String { rawValue }
        var label: String {
            switch self {
            case .working: return AgentStatus.working.label
            case .blocked: return AgentStatus.blocked.label
            case .idle:    return AgentStatus.idle.label
            case .ignore:  return "Leave state alone"
            }
        }
        var status: AgentStatus? {
            switch self {
            case .working: return .working
            case .blocked: return .blocked
            case .idle:    return .idle
            case .ignore:  return nil
            }
        }
        init(_ status: AgentStatus?) {
            switch status {
            case .working?: self = .working
            case .blocked?: self = .blocked
            case .idle?:    self = .idle
            case nil:       self = .ignore
            }
        }
    }

    @State private var regionKind: RegionKind = .whole
    @State private var regionCount = 8

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: Binding(
                        get: { draft.label ?? draft.displayName },
                        set: { draft.label = $0 }
                    ))
                    Picker("Means", selection: Binding(
                        get: { Meaning(draft.status) },
                        set: { draft.status = $0.status }
                    )) {
                        ForEach(Meaning.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    Toggle("Rule is on", isOn: $draft.isEnabled)
                } header: {
                    Text("What it means")
                }

                Section {
                    Picker("Look in", selection: $regionKind) {
                        ForEach(RegionKind.allCases) { r in Text(r.label).tag(r) }
                    }
                    if regionKind.takesCount {
                        Stepper("How many lines: \(regionCount)", value: $regionCount, in: 1...60)
                    }
                } header: {
                    Text("Where it looks")
                } footer: {
                    PanelNote("Narrow beats wide: a footer hint scoped to the bottom of the screen can't be triggered by the same words scrolling past in the conversation.")
                }

                Section {
                    ClauseEditor(clause: $draft.clause, depth: 0)
                } header: {
                    Text("What has to be true")
                } footer: {
                    PanelNote("Matching ignores case. \(draft.clause.summary.prefix(1).capitalized + draft.clause.summary.dropFirst()).")
                }

                Section {
                    Stepper("Checked at \(draft.priority)", value: $draft.priority, in: 0...3000, step: 10)
                } header: {
                    Text("Order")
                } footer: {
                    PanelNote("Higher numbers are tried first, and the first match wins. Rules you add start at \(AgentRuleSet.customRulePriority), above every built-in one.")
                }

                Section {
                    Button("Delete Rule", role: .destructive) { confirmingDelete = true }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.displayName)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.region = regionKind.region(count: regionCount)
                        onSave(draft)
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Delete this rule?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { onDelete(); dismiss() }
            } message: {
                Text("Built-in rules come back with “Reset to Built-in Rules”.")
            }
            .onAppear {
                regionKind = RegionKind(draft.region)
                if case .bottomNonEmptyLines(let n) = draft.region { regionCount = n }
                if case .topNonEmptyLines(let n) = draft.region { regionCount = n }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 620)
        #endif
    }
}

// MARK: - The condition tree

/// The clause editor. A rule's condition is a tree of and/or/not over text and
/// patterns, and this edits it as one — kind picker per node, one text field
/// per term, add and remove anywhere, negate in place.
///
/// It is recursive by construction, which is also the only way it can present
/// the built-in rules honestly: several of them are genuinely three levels
/// deep, and flattening them for the editor would mean the thing you edit is
/// not the thing that runs.
struct ClauseEditor: View {
    @Binding var clause: MatchClause
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if clause.kind.isGroup {
                ForEach(Array(clause.children.enumerated()), id: \.offset) { index, _ in
                    HStack(alignment: .top, spacing: 6) {
                        Rectangle()
                            .fill(.quaternary)
                            .frame(width: 2)
                        ClauseEditor(clause: childBinding(index), depth: depth + 1)
                    }
                }
                Button {
                    clause = clause.addingChild(.newTextTerm)
                } label: {
                    Label("Add condition", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            } else {
                terms
            }
        }
        .padding(.leading, depth > 0 ? 4 : 0)
        .padding(.vertical, 2)
    }

    // MARK: Node header

    private var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { clause.kind },
                set: { clause = clause.converted(to: $0) }
            )) {
                ForEach(MatchClause.Kind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .labelsHidden()
            #if os(macOS)
            .frame(maxWidth: 190)
            #endif

            Toggle("Not", isOn: Binding(
                get: { clause.isNegated },
                set: { clause = clause.negated($0) }
            ))
            .font(.caption)
            #if os(macOS)
            .toggleStyle(.checkbox)
            #else
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            #endif

            Spacer(minLength: 0)
        }
    }

    // MARK: Leaf terms

    @ViewBuilder
    private var terms: some View {
        let values = clause.terms
        let multi = clause.kind == .contains || clause.kind == .containsAny
        ForEach(Array(values.enumerated()), id: \.offset) { index, _ in
            HStack(spacing: 6) {
                TextField(multi ? "Text on screen" : "Pattern", text: termBinding(index))
                    .font(.system(.caption, design: .monospaced))
                    #if !os(macOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
                if multi && values.count > 1 {
                    Button {
                        var next = values
                        next.remove(at: index)
                        clause = clause.with(terms: next)
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if multi {
            Button {
                clause = clause.with(terms: values + [""])
            } label: {
                Label("Add text", systemImage: "plus.circle").font(.caption)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Bindings into the tree

    private func childBinding(_ index: Int) -> Binding<MatchClause> {
        Binding(
            get: { clause.children.indices.contains(index) ? clause.children[index] : .newTextTerm },
            set: { clause = clause.replacingChild(at: index, with: $0) }
        )
    }

    private func termBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { clause.terms.indices.contains(index) ? clause.terms[index] : "" },
            set: {
                var next = clause.terms
                guard next.indices.contains(index) else { return }
                next[index] = $0
                clause = clause.with(terms: next)
            }
        )
    }
}

// MARK: - Try it on a screen

/// Paste a screen, see the verdict. Editing rules without this is guesswork:
/// the answer comes from `AgentRuleSet.evaluate`, the same engine the poller
/// runs, so what you see here is what the pane will do.
struct RuleTrialView: View {
    @Environment(\.dismiss) private var dismiss
    let ruleSet: AgentRuleSet
    let agentName: String

    @State private var screen = ""
    @State private var title = ""
    @State private var command = ""

    private var trial: RuleTrial {
        ruleSet.evaluate(command: command.isEmpty ? nil : command,
                     title: title,
                     screen: screen.isEmpty ? nil : screen)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Window title", text: $title)
                        .font(.system(.caption, design: .monospaced))
                    TextField("Running command", text: $command)
                        .font(.system(.caption, design: .monospaced))
                    TextEditor(text: $screen)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 160)
                } header: {
                    Text("A screen")
                } footer: {
                    PanelNote("Copy a pane's text — `tmux capture-pane -p -J` gives exactly what Bento sees — and paste it here.")
                }

                Section {
                    LabeledContent("Recognized by", value: identityText)
                    LabeledContent("Verdict") {
                        HStack(spacing: 6) {
                            StatusDot(status: trial.status)
                            Text(verdictText)
                        }
                    }
                    LabeledContent("Matched rule", value: matchedText)
                } header: {
                    Text("Result")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Try \(agentName)")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 640)
        #endif
    }

    private var identityText: String {
        switch trial.identity {
        case .command:      return "the command name"
        case .title:        return "the window title"
        case .screen:       return "the screen"
        case .unrecognized: return "not recognized — this pane would use activity only"
        }
    }

    private var verdictText: String {
        guard trial.ruleID != nil else { return "nothing matched" }
        guard let status = trial.status else { return "leave state alone" }
        return status.label
    }

    private var matchedText: String {
        guard let id = trial.ruleID else { return "—" }
        return ruleSet.rules.first { $0.id == id }?.displayName ?? id
    }
}

// MARK: - Rows

private struct RuleRow: View {
    let rule: DetectRule
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    StatusDot(status: rule.status)
                    Text(rule.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if rule.isCustom { TagChip("Yours") }
                }
                HStack(spacing: 6) {
                    Text(rule.status?.label ?? "Ignore")
                    Text("·")
                    Text(rule.region.label)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Text(rule.clause.summary)
                    .font(.caption)
                    .foregroundStyle(rule.isEnabled ? .secondary : .tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)

            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: onToggle))
                .labelsHidden()
                #if os(macOS)
                .toggleStyle(.switch)
                .controlSize(.mini)
                #endif
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
                .onTapGesture(perform: onEdit)
        }
        .padding(.vertical, 2)
    }
}

/// An editable list of identity patterns — the one text-entry affordance that
/// appears three times, so it exists once.
private struct PatternRows: View {
    let title: String
    let patterns: [String]
    let onChange: ([String]) -> Void

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(patterns.enumerated()), id: \.offset) { i, pattern in
                HStack {
                    Text(pattern)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        var next = patterns
                        next.remove(at: i)
                        onChange(next)
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("Add…", text: $draft)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.plain)
                    #if !os(macOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
                Button {
                    let value = draft.trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty else { return }
                    onChange(patterns + [value])
                    draft = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Bits

private struct StatusDot: View {
    let status: AgentStatus?

    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }

    private var color: Color {
        switch status {
        case .working?: return Color(hex: PaneState.workingHex)
        case .blocked?: return Color(hex: PaneState.awaitingHex)
        case .idle?:    return Color(hex: PaneState.idleHex)
        case nil:       return Color.secondary.opacity(0.4)
        }
    }
}

private struct TagChip: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
