import SwiftUI

/// The one picture that answers every future "why": the host runs the tmux
/// server, every device is just another client, and the wire between them is
/// ordinary SSH — nothing of ours sits in the middle. Shown on the first
/// screen of both platforms' first-run flows and in Help → "How Bento works"
/// (design doc §2). One implementation shared by iOS and macOS.
///
/// Names the real thing (tmux server / client, ssh) rather than a metaphor:
/// the user will meet those words in `tmux ls`, in tmux's own docs, and in any
/// other terminal, and a private vocabulary only breaks when it leaks.
public struct ArchitectureDiagramView: View {
    /// Accent used for the link + host highlight (apps pass their brand green).
    let accent: Color
    /// Compact drops the captions (for tight embeds like a menu-sized window).
    let compact: Bool

    @State private var pulse = false

    public init(accent: Color = .green, compact: Bool = false) {
        self.accent = accent
        self.compact = compact
    }

    public var body: some View {
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
                    .fill(highlighted ? accent.opacity(0.14) : Color.secondary.opacity(0.10))
                    .frame(width: 64, height: 64)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(highlighted ? accent.opacity(0.5) : Color.secondary.opacity(0.25), lineWidth: 1)
                    .frame(width: 64, height: 64)
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(highlighted ? accent : Color.secondary)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if !compact {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The SSH link: a dashed line with a traveling pulse dot, badged with a
    /// padlock and the literal word `ssh` — the wire is the user's own SSH
    /// connection, so the picture says so. Purely decorative — reduced-motion
    /// users just see the static dashes.
    private var link: some View {
        VStack(spacing: 4) {
            ZStack {
                Line()
                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .frame(height: 1.5)
                GeometryReader { geo in
                    let w = geo.size.width
                    Circle()
                        .fill(accent)
                        .frame(width: 6, height: 6)
                        .position(x: pulse ? w - 4 : 4, y: geo.size.height / 2)
                        .opacity(0.9)
                }
            }
            .frame(height: 12)
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary.opacity(0.6))
            if !compact {
                Text("ssh")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
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

/// The pane-state color legend — the key to the product's mental model
/// ("watch colors, not text"). Presented once, anchored to the first pane
/// that hits awaiting-input (design doc §6.2), and permanently available in
/// Help. Colors come straight from `PaneState`, the same single source the
/// pane chrome uses.
public struct StateLegendCard: View {
    let onDismiss: (() -> Void)?

    public init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Watch the colors")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            legendRow(hex: PaneState.workingHex, symbol: "play.circle.fill",
                      title: "Working", detail: "the agent is busy — you don't have to watch")
            legendRow(hex: PaneState.awaitingHex, symbol: "questionmark.circle.fill",
                      title: "Needs you", detail: "it's waiting for your answer — now")
            legendRow(hex: PaneState.doneUnseenHex, symbol: "checkmark.circle.fill",
                      title: "Done", detail: "finished while you looked away")
            legendRow(hex: PaneState.idleHex, symbol: "circle",
                      title: "Idle", detail: "waiting for an instruction")
            Text("Watch the colors — you don't have to read every pane.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func legendRow(hex: UInt32, symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Color(legendHex: hex))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 74, alignment: .leading)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension Color {
    init(legendHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
