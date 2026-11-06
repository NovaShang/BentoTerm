import SwiftUI
import BentoAgentKit

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

/// General — which tmux, which agents, and about.
///
/// Facts, not knobs. There is deliberately no "which tmux" picker: it would be
/// a knob over a decision with one right answer (`TmuxResolver`: a good enough
/// system tmux wins, otherwise the bundled copy) — anyone who wants a
/// different tmux changes their tmux. Nor a default agent: the command box on
/// the new-session sheet remembers the last one, which covers everything a
/// default would.
///
/// **We don't install agents.** Finding none is not an error state and gets no
/// warning colour — the user types whatever command they like when they start
/// a session.
public struct GeneralPanel<Extra: View>: View {
    private let facts: TmuxFacts?
    private let extra: Extra

    @State private var agents: [DetectedAgent] = []
    @State private var scanning = true

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
                if scanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking…").foregroundStyle(.secondary)
                    }
                } else if agents.isEmpty {
                    PanelNote(Self.emptyCopy)
                } else {
                    ForEach(agents) { agent in
                        HStack {
                            Text(agent.preset.rawValue)
                            Spacer()
                            Text(agent.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                // The hooks are config on whichever machine runs the agent, so
                // the app can't install them; this is where to find them.
                Link("Hook Setup for Claude Code and Codex", destination: Self.hooksURL)
            } header: { Text("Agents") } footer: {
                PanelNote("A pane's color comes from the agent's hooks: a few lines in its own settings that set two tmux pane options and do nothing outside tmux.")
            }

            extra
        }
        .bentoPanelForm()
        // Scanned each time the page opens, which is what a Re-scan button
        // used to be for.
        .task {
            agents = await InstalledAgents.scan()
            scanning = false
        }
    }

    private static var hooksURL: URL { URL(string: "https://github.com/NovaShang/BentoTerm#agent-hooks")! }

    private static var emptyCopy: LocalizedStringKey {
        #if os(macOS)
        return "No known agents found on this Mac. You can still type any command when you start a session."
        #else
        return "Agents live on the host you connect to. Whatever you can run there, you can start in a pane."
        #endif
    }

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
