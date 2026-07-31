import SwiftUI
import BentoTerminalCore

/// First-run home (replaces the old two-button EmptyHomeView). The job is
/// environment preparation, not feature marketing (design doc §5): teach the
/// one load-bearing concept (phone = remote, host = where agents live), then
/// walk the user to a working host via one of three paths:
///   A. "I have a Mac"  → install the Mac app, come back, scan its QR
///   B. "Linux / WSL"   → one-line installer + `bento pair`, scan its QR
///   C. SSH direct      → a first-class transport, unchanged HostEditView
struct WelcomeFlowView: View {
    /// Open the QR-scanning pair sheet (owned by HostListView).
    let onScanPair: () -> Void
    /// Open the manual SSH host editor sheet (owned by HostListView).
    let onAddSSH: () -> Void

    private enum Page { case home, macPath, linuxPath }
    @State private var page: Page = .home
    @State private var showHowItWorks = false

    var body: some View {
        Group {
            switch page {
            case .home: home
            case .macPath: HostPathView(kind: .mac, onScanPair: onScanPair, onBack: { page = .home })
            case .linuxPath: HostPathView(kind: .linux, onScanPair: onScanPair, onBack: { page = .home })
            }
        }
        .animation(.easeInOut(duration: 0.2), value: pageKey)
        .sheet(isPresented: $showHowItWorks) {
            HowBentoWorksView()
        }
    }

    private var pageKey: Int {
        switch page {
        case .home: return 0
        case .macPath: return 1
        case .linuxPath: return 2
        }
    }

    // MARK: - Home (welcome + architecture + the three paths)

    private var home: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    BentoMarkHero(size: 72)
                        .shadow(color: Color.black.opacity(0.4), radius: 18, y: 8)
                    Text("BentoTerm")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.bentoInk)
                    Text("Run a team of AI agents. Speak to them.\nCommand them from anywhere.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.bentoInkDim)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 28)

                ArchitectureDiagramView(accent: .bentoEmerald)
                    .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Your agents need a computer that stays on. Which one is yours?")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.bentoInkDim)
                        .padding(.horizontal, 4)

                    pathCard(
                        symbol: "macbook",
                        title: "I have a Mac",
                        subtitle: "Recommended — the BentoTerm Mac app sets everything up.",
                        prominent: true
                    ) { page = .macPath }

                    pathCard(
                        symbol: "server.rack",
                        title: "I have a Linux server / Windows (WSL)",
                        subtitle: "One command installs the BentoTerm host."
                    ) { page = .linuxPath }

                    // Not labelled "advanced" and not last-resort: plain SSH is a
                    // fully supported transport by architectural rule (the app's
                    // terminal intelligence is client-side, so nothing is lost
                    // without the Bento host). If you already have a host you can
                    // ssh into, this is the shortest path, not the hard one.
                    pathCard(
                        symbol: "terminal",
                        title: "Connect over SSH",
                        subtitle: "Already have a host you ssh into? Use it as-is — reads your ~/.ssh/config."
                    ) { onAddSSH() }
                }
                .padding(.horizontal, 24)

                Button {
                    showHowItWorks = true
                } label: {
                    Label("How does BentoTerm work?", systemImage: "questionmark.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.bentoInkDim)
                }
                .padding(.bottom, 24)
            }
        }
        .background(Color.bentoShell)
    }

    private func pathCard(symbol: String, title: String, subtitle: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(prominent ? Color.black : Color.bentoInkDim)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(prominent ? Color.black : Color.bentoInk)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(prominent ? Color.black.opacity(0.65) : Color.bentoInkDim)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(prominent ? Color.black.opacity(0.6) : Color.bentoInkMute)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(prominent ? Color.bentoEmerald : Color.bentoSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(prominent ? Color.clear : Color.bentoBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Host path pages (Mac / Linux+WSL)

/// The step-by-step "prepare your host" page for paths A and B. Every step is
/// a numbered card; the page ends in a scan-ready CTA so the user's phone is
/// already waiting when the host shows its QR (design doc §5.2).
struct HostPathView: View {
    enum Kind { case mac, linux }

    let kind: Kind
    let onScanPair: () -> Void
    let onBack: () -> Void

    @State private var copiedText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.bentoEmerald)
                }
                .padding(.top, 12)

                Text(kind == .mac ? "Set up your Mac" : "Set up your server")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.bentoInk)

                switch kind {
                case .mac: macSteps
                case .linux: linuxSteps
                }

                Button(action: onScanPair) {
                    HStack(spacing: 10) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Scan the pairing code")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.bentoEmerald)
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 6)

                Text("Pairing introduces this phone to your computer — you only do it once. After that they find each other on any network.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bentoInkMute)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .background(Color.bentoShell)
    }

    // MARK: Path A — Mac

    private var macSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepCard(number: 1, title: "On your Mac, open") {
                copyRow("bento.novashang.com/mac", mono: true)
                Text("Download and open the BentoTerm app.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bentoInkDim)
            }
            stepCard(number: 2, title: "Follow the Mac setup") {
                Text("It installs a CLI agent (like Claude Code) and starts your first tmux session — about 3 minutes.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bentoInkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            stepCard(number: 3, title: "Scan the QR it shows you") {
                Text("The last setup step on the Mac displays a pairing code. Come back here and scan it.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bentoInkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Already running BentoTerm on your Mac? You still need a pairing code from that Mac to continue.")
                .font(.system(size: 12))
                .foregroundStyle(Color.bentoInkMute)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    // MARK: Path B — Linux / WSL

    private var linuxSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepCard(number: 1, title: "Install the BentoTerm host") {
                copyRow("curl -fsSL https://bento.novashang.com/install.sh | sh", mono: true)
                Text("Run this on your server. Windows: run it inside WSL — Windows' built-in Linux environment.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bentoInkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            stepCard(number: 2, title: "Start pairing") {
                copyRow("bento pair", mono: true)
                Text("It prints a QR code and a 6-digit code in the terminal.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bentoInkDim)
            }
            stepCard(number: 3, title: "Give it an agent") {
                copyRow("curl -fsSL https://claude.ai/install.sh | bash", mono: true)
                Text("Agents are CLI agents that run on your host. Claude Code is the recommended one — no other software needed, and it signs into its own Anthropic account on first run. BentoTerm also understands Codex, Gemini CLI, OpenCode and more if you prefer those.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bentoInkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Building blocks

    private func stepCard(number: Int, title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.bentoEmerald))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.bentoInk)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.bentoSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.bentoBorder, lineWidth: 1)
        )
    }

    private func copyRow(_ text: String, mono: Bool) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(mono ? .system(size: 13, design: .monospaced) : .system(size: 14))
                .foregroundStyle(Color.bentoInk)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = text
                copiedText = text
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if copiedText == text { copiedText = nil }
                }
            } label: {
                Image(systemName: copiedText == text ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14))
                    .foregroundStyle(copiedText == text ? Color.bentoEmerald : Color.bentoInkDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.bentoSurfaceHi)
        )
    }
}
