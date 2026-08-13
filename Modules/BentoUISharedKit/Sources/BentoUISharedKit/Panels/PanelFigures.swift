import SwiftUI
import BentoAgentKit
import BentoFoundationKit

/// The panels' illustrations.
///
/// Drawn in SwiftUI rather than shipped as image assets: every one of them is
/// boxes and arrows, they have to work in light and dark without a second
/// export, and the state colors have to come from the same source the real
/// pane title bars use — an exported PNG would be a second copy of the color
/// language, free to drift.

// MARK: - Parallel ⇄ Focus

/// The only thing on the tmux panel that words can't carry: what the two
/// arrangements actually look like.
public struct ParallelFocusFigure: View {
    public init() {}

    private enum Metrics {
        static let boardWidth: CGFloat = 148
        static let boardHeight: CGFloat = 92
        static let gap: CGFloat = 4
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 18) {
            board(title: "Parallel", caption: "every agent at once") {
                VStack(spacing: Metrics.gap) {
                    HStack(spacing: Metrics.gap) {
                        pane("agent 1", tinted: true)
                        pane("agent 2")
                    }
                    pane("agent 3")
                }
            }
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, Metrics.boardHeight / 2 - 8)
            board(title: "Focus", caption: "one at a time") {
                // A column down the left, not tabs across the top: that is what
                // Focus mode actually looks like in the app (`WindowSidebar`),
                // and a picture of the wrong control is worse than none.
                HStack(spacing: Metrics.gap) {
                    VStack(spacing: 3) {
                        sidebarRow("agent 1", selected: true)
                        sidebarRow("agent 2")
                        sidebarRow("agent 3")
                        Spacer(minLength: 0)
                    }
                    .frame(width: 46)
                    pane("agent 1", tinted: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func board(title: String, caption: String,
                       @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            content()
                .frame(width: Metrics.boardWidth, height: Metrics.boardHeight)
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quinary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    /// One pane. The tinted one is the pane you're talking to — the same blue
    /// the real title bars use for "working", so the picture and the app agree.
    private func pane(_ label: String, tinted: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(tinted ? AnyShapeStyle(Color(hex: PaneState.workingHex).opacity(0.16))
                         : AnyShapeStyle(.quaternary))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(tinted ? Color(hex: PaneState.workingHex).opacity(0.35) : .clear,
                                  lineWidth: 1)
            )
            .overlay(
                Text(label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sidebarRow(_ label: String, selected: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(selected ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary))
            .overlay(
                Text(label)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(selected ? .primary : .secondary)
            )
            .frame(height: 15)
    }
}

// MARK: - Voice gesture

/// Hold → slide → release, in three frames. Static: the gesture is three
/// discrete states, and an animation here would be a thing to watch instead of
/// a thing to read.
public struct VoiceGestureFigure: View {
    public init() {}

    public var body: some View {
        HStack(alignment: .top, spacing: 6) {
            step(symbol: "hand.point.up.left.fill", title: Self.holdTitle, detail: "start recording")
            chevron
            step(symbol: "arrow.up.and.down", title: "slide", detail: "up: send now\ndown: cancel")
            chevron
            step(symbol: "paperplane.fill", title: "let go", detail: "sends it")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chevron: some View {
        Image(systemName: "chevron.compact.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.tertiary)
            // Centred on the tile, not on the whole column: the captions below
            // are two lines on one step and one on another, and centring on the
            // column made the chevrons wander.
            .frame(height: 46)
    }

    private static var holdTitle: String {
        #if os(macOS)
        return "hold right-click"
        #else
        return "press and hold"
        #endif
    }

    private func step(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 58, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quinary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
            VStack(spacing: 1) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 96)
    }
}

// MARK: - Pane state legend

/// The four colors, from the one source the real title bars read
/// (`PaneState.chromeColor`) — so the legend cannot end up teaching a color
/// the app no longer uses.
public struct PaneStateLegend: View {
    public init() {}

    private struct Entry: Identifiable {
        let id: String
        let color: Color
        let label: String
        let meaning: String
    }

    private var entries: [Entry] {
        [
            Entry(id: "working", color: Color(hex: PaneState.workingHex),
                  label: "Working", meaning: "it's busy"),
            Entry(id: "awaiting", color: Color(hex: PaneState.awaitingHex),
                  label: "Waiting for you", meaning: "it asked a question"),
            Entry(id: "done", color: Color(hex: PaneState.doneUnseenHex),
                  label: "Done, unread", meaning: "finished while you were away"),
            Entry(id: "idle", color: Color(hex: PaneState.idleHex),
                  label: "Idle", meaning: "nothing running"),
        ]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(entries) { entry in
                HStack(spacing: 8) {
                    Circle().fill(entry.color).frame(width: 9, height: 9)
                    Text(entry.label).font(.system(size: 13, weight: .medium))
                    Text("— \(entry.meaning)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
