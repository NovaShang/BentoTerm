import SwiftUI

/// The first screen of setup: what this product is FOR.
///
/// The five pages after it configure things. This one doesn't configure
/// anything, and that is its job — someone who has just installed a terminal
/// deserves to know what claim it is making before being asked to pick a font.
///
/// **It is one argument in three parts, not three features.** The argument:
/// agents stopped being the slow part of the work some time ago — the terminal
/// they run in is. Three claims remove the three places the human still stalls
/// (switching, typing, leaving), each written as the AFTER-state the reader
/// wants, not the mechanism that gets them there. The aspiration has to come
/// from concreteness — "while one writes, you're reviewing another" — because
/// this audience discounts invented multipliers on sight; the one line that
/// gestures at scale is the closer, and it says "compounds", which an engineer
/// can check against the three claims above it.
public struct WelcomeManifestoView: View {
    private let icon: Image?

    /// - Parameter icon: the app icon, supplied by the app (NSImage on macOS,
    ///   UIImage on iOS — neither belongs in this package).
    public init(icon: Image?) {
        self.icon = icon
    }

    private static let iconSize: CGFloat = 72

    /// iOS ships the app icon as a full square and masks it at draw time, so an
    /// icon loaded from the bundle and drawn as-is turns up with hard corners.
    /// macOS icons carry their own rounding (and transparent margin) in the
    /// image, so masking there would clip the artwork — hence 0 on that side.
    private static var iconCornerRadius: CGFloat {
        #if os(macOS)
        return 0
        #else
        return iconSize * 0.2237
        #endif
    }

    private struct Claim: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
    }

    private static let claims: [Claim] = [
        Claim(id: "parallel", symbol: "rectangle.split.2x2.fill",
              title: "A whole team, one screen",
              detail: "While one agent writes code, you're reviewing another's. All of your attention goes to planning and judging — none of it to switching windows."),
        Claim(id: "voice", symbol: "mic.fill",
              title: "Say it, don't type it",
              detail: "Hold to talk to any pane — you speak about three times faster than you type. Bento reads the screen, so names and jargon come out right."),
        Claim(id: "anywhere", symbol: "ipad.and.iphone",
              title: "Leave the desk, not the work",
              detail: "The work lives on the machine, not in a window. From the sofa or the train, your phone shows the same panes — still running."),
    ]

    public var body: some View {
        // One block, centred as a whole. Spacers only on the outside: with a
        // Spacer between the claims and the closing line, that line drifted to
        // the bottom edge and read as a footnote instead of the punchline.
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 12) {
                if let icon {
                    icon
                        .resizable()
                        .frame(width: Self.iconSize, height: Self.iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: Self.iconCornerRadius,
                                                    style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                }
                Text("BentoTerm")
                    .font(.system(size: 28, weight: .bold))
                // Category first, then the two things this app is for, as two
                // verbs. Drafts that didn't survive, and why:
                //  * "Agents are fast. Your terminal isn't" — literally false to
                //    anyone who has used a fast terminal, and a checkable
                //    exaggeration in the first sentence is the worst possible
                //    trade with this audience.
                //  * "…a team of agents, all at once, by voice, from anywhere" —
                //    bragging about the count is what makes "multi-agent" copy
                //    read like everyone else's. `your agents` is a noun; `many
                //    agents` is a boast.
                // The same sentence is the site's H1, so arriving here from the
                // web is a confirmation rather than a second pitch.
                Text("A terminal for watching and talking to your agents.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 30)

            VStack(alignment: .leading, spacing: 20) {
                ForEach(Self.claims) { claim in
                    row(claim)
                }
            }
            .frame(maxWidth: 430, alignment: .leading)

            Text("Not three features — one way of working. And it compounds.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 30)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }

    private func row(_ claim: Claim) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: claim.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.tint.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(claim.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(claim.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
