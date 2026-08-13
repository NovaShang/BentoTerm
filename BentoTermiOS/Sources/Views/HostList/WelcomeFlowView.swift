import SwiftUI
import BentoSessionKit
import BentoFoundationKit
import BentoUISharedKit

/// First-run home, and the one thing iOS genuinely cannot start without: a
/// machine it can ssh into.
///
/// It used to open with a phone-and-host architecture drawing. That picture
/// went with the relay it described, and it was answering a question this user
/// doesn't have — what a host is for is one sentence, and how tmux keeps the
/// work alive belongs on the setup flow's tmux page, said once.
///
/// There is exactly one way in: SSH to a machine you already reach. Bento
/// installs nothing on the host and runs no service of its own, so anything
/// with `sshd` and `tmux` works as-is. Getting the phone to that machine
/// (LAN, VPN, Tailscale, a jump host) is ordinary SSH plumbing the user
/// already owns.
struct WelcomeFlowView: View {
    /// Open the manual SSH host editor sheet (owned by HostListView).
    let onAddSSH: () -> Void

    var body: some View { home }

    // MARK: - Home (welcome + architecture + the way in)

    private var home: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    BentoMark(size: 72)
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

                VStack(alignment: .leading, spacing: 10) {
                    Text("Your agents need a computer that stays on. Point Bento at one you can already ssh into.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.bentoInkDim)
                        .padding(.horizontal, 4)

                    pathCard(
                        symbol: "terminal",
                        title: "Connect over SSH",
                        subtitle: "Any machine running sshd and tmux — Mac, Linux, or Windows (WSL).",
                        prominent: true
                    ) { onAddSSH() }

                    Text("Nothing to install on the host. Bento needs to reach it the same way `ssh` does, so if that means a VPN or a jump host, set that up first.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.bentoInkMute)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 24)

                // The concept page this used to open is gone. What it was
                // really explaining is tmux, and that explanation now lives in
                // one place — the setup flow's tmux page, with the long version
                // a link away — instead of being retold here in its own words.
                Link(destination: TmuxLearnMore.url) {
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
