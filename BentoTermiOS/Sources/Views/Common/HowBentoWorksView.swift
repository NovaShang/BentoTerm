import SwiftUI
import BentoTerminalCore

/// "How BentoTerm works" — the concept map (design doc §2), permanently
/// re-readable. Every coach mark the user may have dismissed lives here in
/// long form: host and clients, agents, persistent tmux sessions, pairing,
/// state colors, Parallel/Focus, and the voice gestures. Optional reading:
/// an opt-in link on the welcome screen and an entry in Settings → Help —
/// never a step the user must walk through.
///
/// Copy names the real tmux objects rather than a private vocabulary — the
/// user meets those same words in `tmux ls` and in tmux's own docs.
struct HowBentoWorksView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HowBentoWorksContent()
                .navigationTitle("How BentoTerm works")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// Pushed variant for Settings → Help (already inside a NavigationStack).
struct HowBentoWorksSettingsPage: View {
    var body: some View {
        HowBentoWorksContent()
            .navigationTitle("How BentoTerm works")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HowBentoWorksContent: View {
    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ArchitectureDiagramView(accent: .bentoEmerald)
                        .padding(.top, 8)

                    concept(
                        symbol: "desktopcomputer",
                        title: "Host",
                        body: "The computer that runs the tmux server — your Mac or a server. Every device you connect from, including this one, is just another tmux client: close it and the session keeps running."
                    )
                    concept(
                        symbol: "sparkles",
                        title: "Agents",
                        body: "CLI agents (like Claude Code) installed on the host. Each signs into its own account. Give one a folder and an instruction and it works on its own."
                    )
                    concept(
                        symbol: "clock.arrow.circlepath",
                        title: "Sessions persist",
                        body: "A BentoTerm session is a tmux session, living on the host. Disconnect, lock your phone, switch devices — it is exactly where you left it, and `tmux ls` on the host lists the same thing."
                    )
                    concept(
                        symbol: "qrcode",
                        title: "Pairing",
                        body: "A one-time introduction between phone and host. After pairing they reach each other from any network, end-to-end encrypted — the relay only forwards bytes it cannot read."
                    )

                    StateLegendCard()
                        .frame(maxWidth: .infinity)

                    concept(
                        symbol: "rectangle.split.2x2",
                        title: "Parallel and Focus",
                        body: "Parallel keeps every pane in one tmux window, tiled — all agents visible at once. Focus breaks each pane out into its own window so one fills the screen: you give up the split view and get a readable one, which is what you want on a phone or when panes have gotten too small. Switching runs tmux's break-pane / join-pane — panes move, nothing is closed."
                    )
                    concept(
                        symbol: "mic",
                        title: "Voice gestures",
                        body: "Hold anywhere and speak; release to send. While holding: slide up to send instantly, down to cancel, right to review the text before sending, left to turn plain words into a shell command. Double-tap for the keyboard."
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
        .background(Color.bentoShell)
    }

    private func concept(symbol: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.bentoEmerald)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.bentoInk)
                Text(body)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.bentoInkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.bentoSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.bentoBorder, lineWidth: 1)
        )
    }
}
