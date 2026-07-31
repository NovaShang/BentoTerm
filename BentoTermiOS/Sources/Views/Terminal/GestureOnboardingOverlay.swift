import SwiftUI

/// First-run overlay that teaches the two primary terminal gestures:
/// hold-to-speak and double-tap-to-keyboard. Persists "shown" in UserDefaults
/// so it never reappears after the user dismisses it.
///
/// Bumping the `Self.storageKey` suffix lets us re-trigger if we add a new
/// gesture in a future version.
struct GestureOnboardingOverlay: View {
    static let storageKey = "gestureOnboardingShown_v1"

    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Dimmed backdrop. Tap-through to dismiss matches iOS hint-card UX.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 28) {
                Text("Two gestures to rule it all")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 22) {
                    hintRow(
                        glyph: holdGlyph,
                        title: "Hold anywhere & speak",
                        subtitle: "Release to send · slide ↑ send now · slide ↓ cancel"
                    )
                    hintRow(
                        glyph: doubleTapGlyph,
                        title: "Double-tap anywhere",
                        subtitle: "Type with the keyboard instead"
                    )
                }

                Button(action: onDismiss) {
                    Text("Got it")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.accentColor)
                        )
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
            )
            .padding(.horizontal, 24)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func hintRow(glyph: some View, title: String, subtitle: String) -> some View {
        HStack(spacing: 16) {
            glyph
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
    }

    private var holdGlyph: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                .frame(width: 38, height: 38)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 16, height: 16)
        }
    }

    private var doubleTapGlyph: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 14, height: 14)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 14, height: 14)
        }
        .frame(width: 38, height: 38)
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
        )
    }

    /// Mark the overlay as seen so it never reappears on this install.
    static func markDismissed() {
        UserDefaults.standard.set(true, forKey: storageKey)
    }

    /// Whether the overlay still needs to be shown.
    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: storageKey)
    }
}
