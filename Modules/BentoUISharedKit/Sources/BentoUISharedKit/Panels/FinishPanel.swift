import SwiftUI
import BentoFoundationKit

/// ⑤ Finish — the way in, the phone, and the one privacy switch.
///
/// ⌘P leads because it is where everything else in the app is, and where
/// everything we add later will appear. The phone paragraph gives instructions
/// rather than a diagram: the old first screen drew a Mac and a phone with a
/// cloud between them, which stopped being true when the relay was deleted and
/// was never what this user needed anyway.
public struct FinishPanel<Extra: View>: View {
    private let context: PanelContext
    private let extra: Extra

    @ObservedObject private var telemetry = TelemetryService.shared

    public init(context: PanelContext, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.context = context
        self.extra = extra()
    }

    public var body: some View {
        PanelBody(context) {
                #if os(macOS)
                PanelLead("⌘P opens the command palette.")
                PanelProse("New session, jump to a pane, connect to an SSH host, open settings.")
                PanelProse("It's also where new features will show up.")
                #else
                PanelLead("The command palette is the way around.")
                PanelProse("""
                    New session, jump to a pane, connect to a host — it's all in there, and \
                    it's where new features will show up.
                    """)
                #endif

                // Constrained to the prose column — a full-bleed rule under a
                // 520pt paragraph reads as a section break in the window chrome
                // rather than a break between two paragraphs.
                Divider().frame(maxWidth: PanelMetrics.proseWidth)

                #if os(macOS)
                PanelLead("Take it with you.")
                PanelProse("Install BentoTerm on your phone and connect over **SSH**.")
                PanelProse("Same session, same agents, still running — this Mac only has to stay awake.")
                PanelProse("It needs Remote Login on, and your phone has to be able to reach it: same network, Tailscale, or a jump host.")
                #else
                PanelLead("Same session on every device.")
                PanelProse("""
                    A session lives on the host, not in this app. Connect from your Mac over \
                    **SSH** and you get the same panes, still running.
                    """)
                #endif
        } controls: {
            Section {
                Toggle("Share anonymous usage statistics", isOn: Binding(
                    get: { telemetry.enabled },
                    set: { telemetry.enabled = $0 }
                ))
            } header: { Text("Privacy") } footer: {
                PanelNote("""
                    No terminal content, commands, transcripts, paths, or hostnames — ever. \
                    Just event names, tied to a random ID that is deleted when you turn this \
                    off. Events go straight to Bento's own endpoint; no third-party SDKs.
                    """)
            }

            AdvancedBlock(context) {
                DisclosureGroup("What gets counted") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(TelemetryEvent.allCases, id: \.rawValue) { event in
                            Text(event.rawValue)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            extra
        }
    }
}
