import SwiftUI

/// What the app resolved about tmux, for the panel to state as fact.
///
/// The panel doesn't resolve anything itself: which tmux gets used is decided
/// by the Mac app's `TmuxResolver` (and on iOS by whatever host you connected
/// to), and this is that decision flattened into something displayable.
public struct TmuxFacts: Equatable, Sendable {
    public enum Source: String, Sendable { case system, bundled, override }

    public var source: Source
    public var version: String
    public var path: String
    /// Set when a tmux server is already running from a DIFFERENT tmux than the
    /// one we use — the one case on this page that has to interrupt the user.
    public var conflictingSystemVersion: String?

    public init(source: Source, version: String, path: String,
                conflictingSystemVersion: String? = nil) {
        self.source = source
        self.version = version
        self.path = path
        self.conflictingSystemVersion = conflictingSystemVersion
    }
}

/// tmux's own documentation, for the reader who wants the model — sessions,
/// windows, panes, attaching, `~/.tmux.conf`.
///
/// It points at the tmux project, not at a page of ours: what is behind this
/// link is tmux itself, and sending someone to our retelling of it when the
/// real thing exists is the wrong kind of ownership.
public enum TmuxLearnMore {
    public static let url = URL(string: "https://github.com/tmux/tmux/wiki")!
}

/// General — which tmux, the default session name, agent hooks, and about.
///
/// Facts, not knobs. There is deliberately no "which tmux" picker: it would be
/// a knob over a decision with one right answer (`TmuxResolver`: a good enough
/// system tmux wins, otherwise the bundled copy) — anyone who wants a
/// different tmux changes their tmux.
public struct GeneralPanel<Extra: View>: View {
    private let facts: TmuxFacts?
    private let extra: Extra

    /// What the field shows while being edited. Stored only once it is made
    /// addressable (`commitDefaultName`), so a half-typed `foo.` never becomes
    /// the name a launch reaches for.
    @State private var defaultNameDraft = ""
    @FocusState private var defaultNameFocused: Bool

    /// - Parameters:
    ///   - facts: the tmux the Mac resolved. nil on iOS, where tmux belongs to
    ///     whichever host you connect to.
    ///   - extra: the platform's About block and what hangs under it.
    public init(facts: TmuxFacts? = nil, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.facts = facts
        self.extra = extra()
    }

    public var body: some View {
        Form {
            if let facts {
                Section {
                    if let old = facts.conflictingSystemVersion {
                        PanelWarning("""
                            Your tmux is \(old) — too old for control mode (3.2+ required), so Bento \
                            uses its own \(facts.version). Different versions are different servers, \
                            so Bento won't see sessions your tmux started.
                            """) {
                            Link("How to upgrade", destination: URL(string: "https://github.com/tmux/tmux/wiki/Installing")!)
                        }
                    }
                    LabeledContent("tmux") {
                        Text(factsLine(facts))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            Section {
                TextField("Default session name", text: $defaultNameDraft,
                          prompt: Text(TmuxSessionNaming.defaultName))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($defaultNameFocused)
                    .onSubmit(commitDefaultName)
                    .onChange(of: defaultNameFocused) { _, focused in
                        if !focused { commitDefaultName() }
                    }
            } header: { Text("Sessions") } footer: {
                PanelNote(Self.sessionsCopy)
            }

            Section {
                // The hooks are config on whichever machine runs the agent, so
                // the app can't install them; this is where to find them.
                Link("Hook Setup for Claude Code and Codex", destination: Self.hooksURL)
            } header: { Text("Agents") } footer: {
                PanelNote("A pane's color comes from the agent's hooks: a few lines in its own settings that set two tmux pane options and do nothing outside tmux.")
            }

            extra
        }
        .bentoPanelForm()
        .onAppear { defaultNameDraft = Self.storedDefaultName }
        .onDisappear(perform: commitDefaultName)
    }

    /// The stored name, as typed (empty = none set, so the prompt shows).
    private static var storedDefaultName: String {
        UserDefaults.standard.string(forKey: TmuxSessionNaming.defaultNameKey) ?? ""
    }

    /// Store what was typed, made addressable (`foo.bar` → `foo-bar`); blank
    /// clears it, which means `bento`. The field is rewritten with what was
    /// stored so it never shows a name tmux would not take.
    private func commitDefaultName() {
        let name = TmuxSessionNaming.typed(defaultNameDraft)
        if let name {
            UserDefaults.standard.set(name, forKey: TmuxSessionNaming.defaultNameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: TmuxSessionNaming.defaultNameKey)
        }
        defaultNameDraft = name ?? ""
    }

    private static var sessionsCopy: LocalizedStringKey {
        #if os(macOS)
        return "The tmux session Bento opens when you start it with nothing to go back to. New Window (⇧⌘N) adds -2, -3…"
        #else
        return "The name a new session on a host starts with."
        #endif
    }

    private static var hooksURL: URL { URL(string: "https://github.com/NovaShang/BentoTerm#agent-hooks")! }

    private func factsLine(_ facts: TmuxFacts) -> String {
        switch facts.source {
        case .system:
            return "\(facts.version) — yours, at \(facts.path)"
        case .bundled:
            return "\(facts.version) — the copy Bento ships"
        case .override:
            return "\(facts.version) — set by BENTO_TMUX"
        }
    }
}
