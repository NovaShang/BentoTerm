import SwiftUI
import BentoAgentKit

// Restored verbatim from ArchitectureDiagramView.swift, which was deleted with
// the relay-era host/phone drawing it was named for. The legend itself is not
// part of that: it is the one-time tip anchored to the first pane that turns
// amber, which is still exactly when the color language is worth explaining.

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
                .foregroundStyle(Color(hex: hex))
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

