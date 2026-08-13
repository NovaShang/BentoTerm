import SwiftUI
import BentoAgentKit

/// ④ Agents — what's installed, and what the colors mean.
///
/// **No settings at all.** There is no "default agent" concept: the command
/// box on the new-session sheet is editable and remembers the last one, which
/// covers everything a default would, and adding a setting would just be
/// choosing for the user once instead of letting them choose each time.
///
/// **We don't install agents.** Finding none is not an error state and gets no
/// warning colour — the user types whatever command they like when they start
/// a session.
public struct AgentsPanel<Extra: View>: View {
    private let context: PanelContext
    private let extra: Extra

    @State private var agents: [DetectedAgent] = []
    @State private var scanning = true

    public init(context: PanelContext, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.context = context
        self.extra = extra()
    }

    public var body: some View {
        PanelBody(context) {
                PanelLead("Bento watches what each pane prints and tints the whole pane to match.")
                PaneStateLegend()
                PanelProse("Nothing is installed into your shell, and the agent doesn't have to cooperate.")
                PanelProse("That also means it is pattern matching — the color is a hint, not a guarantee.")
        } controls: {
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
            } header: { Text(Self.listTitle) }

            AdvancedBlock(context) {
                Button("Re-scan") { Task { await rescan() } }
                    .disabled(scanning)
            }

            extra
        }
        .task { await rescan() }
    }

    private static var listTitle: String {
        #if os(macOS)
        return "Found on this Mac"
        #else
        return "Agents"
        #endif
    }

    private static var emptyCopy: LocalizedStringKey {
        #if os(macOS)
        return "No known agents found. You can still type any command when you start a session."
        #else
        return "Agents live on the host you connect to. Whatever you can run there, you can start in a pane."
        #endif
    }

    private func rescan() async {
        scanning = true
        agents = await InstalledAgents.scan()
        scanning = false
    }
}
