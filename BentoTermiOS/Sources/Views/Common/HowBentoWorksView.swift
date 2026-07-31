import SwiftUI
import BentoTerminalCore

/// "How BentoTerm works" — the concept map (design doc §2), permanently
/// re-readable. Every coach mark the user may have dismissed lives here in
/// long form: host and clients, agents, persistent tmux sessions, the SSH
/// wire, state colors, Parallel/Focus, and the voice gestures. Optional reading:
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
                    SSHArchitectureDiagram()
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
                        symbol: "lock.shield",
                        title: "Plain SSH",
                        body: "BentoTerm is an SSH client. Nothing is installed on the host and no service of ours sits in between — anything you can `ssh` into, with tmux on it, works as-is. Reaching it from outside your network is ordinary SSH plumbing: a VPN, Tailscale, or a jump host."
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

// MARK: - Architecture diagram

/// The one picture that answers every future "why": the host runs the tmux
/// server, every device is just another client, and the wire between them is
/// ordinary SSH.
///
/// Names the real thing (tmux server / client, ssh) rather than a metaphor:
/// the user will meet those words in `tmux ls`, in tmux's own docs, and in
/// every other terminal, and a private vocabulary only breaks when it leaks.
///
/// BentoTerminalCore ships an `ArchitectureDiagramView` that draws the same
/// picture with a cloud badge and an "encrypted relay" caption. That is no
/// longer what iOS does — there is no service between the phone and the host —
/// so iOS draws its own until core's copy is corrected.
struct SSHArchitectureDiagram: View {
    /// Compact drops the captions (for tight embeds).
    var compact: Bool = false

    @State private var pulse = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            endpoint(
                symbol: "iphone",
                title: "Your phone",
                caption: "A tmux client.\nClose it — the session keeps running."
            )
            link
            endpoint(
                symbol: "desktopcomputer",
                title: "Your computer",
                caption: "Runs sshd and the tmux server.\nMac, Linux, or Windows (WSL).",
                highlighted: true
            )
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your phone is a tmux client connected over SSH to your computer, which runs the tmux server. Sessions keep running there even when the phone is closed.")
    }

    private func endpoint(symbol: String, title: String, caption: String, highlighted: Bool = false) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(highlighted ? Color.bentoEmerald.opacity(0.14) : Color.bentoSurfaceHi)
                    .frame(width: 64, height: 64)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(highlighted ? Color.bentoEmerald.opacity(0.5) : Color.bentoBorder, lineWidth: 1)
                    .frame(width: 64, height: 64)
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(highlighted ? Color.bentoEmerald : Color.bentoInkDim)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.bentoInk)
            if !compact {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.bentoInkDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The SSH link: a dashed line with a traveling pulse dot. Purely
    /// decorative — reduced-motion users just see the static dashes.
    private var link: some View {
        VStack(spacing: 4) {
            ZStack {
                Line()
                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .foregroundStyle(Color.bentoInkMute)
                    .frame(height: 1.5)
                GeometryReader { geo in
                    let w = geo.size.width
                    Circle()
                        .fill(Color.bentoEmerald)
                        .frame(width: 6, height: 6)
                        .position(x: pulse ? w - 4 : 4, y: geo.size.height / 2)
                        .opacity(0.9)
                }
            }
            .frame(height: 12)
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.bentoInkDim)
            if !compact {
                Text("ssh")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.bentoInkMute)
            }
        }
        .frame(maxWidth: 90)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.width, y: rect.midY))
            return p
        }
    }
}
