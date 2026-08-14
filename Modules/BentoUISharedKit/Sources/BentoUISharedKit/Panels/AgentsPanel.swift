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
    @State private var showRules = false

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

            // The colors are a guess, and this is where the guess is written
            // down. It sits on the panel that explains the color language,
            // because "why is that pane amber?" is asked from here.
            Section {
                #if os(macOS)
                Button("Detection Rules…") { showRules = true }
                #else
                NavigationLink("Detection Rules") { AgentRulesListView() }
                #endif
            } footer: {
                PanelNote("What Bento looks for on screen to decide a pane is working, waiting for you, or done — readable, switchable, and extendable if your agent shows something we don't know about.")
            }

            AdvancedBlock(context) {
                Button("Re-scan") { Task { await rescan() } }
                    .disabled(scanning)
            }

            extra
        }
        .task { await rescan() }
        #if os(macOS)
        // Settings on the Mac is a TabView, not a navigation stack, so the
        // rules open in their own stack rather than pushing over the panel.
        .sheet(isPresented: $showRules) {
            NavigationStack {
                AgentRulesListView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showRules = false }
                        }
                    }
            }
            .frame(width: 560, height: 560)
        }
        #endif
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
