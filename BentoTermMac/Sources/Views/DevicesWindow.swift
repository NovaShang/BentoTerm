import SwiftUI

/// DevicesWindow uses `Table` — the native macOS data view — so column sizing,
/// keyboard focus, and selection are all handled by AppKit underneath.
struct DevicesWindow: View {
    @EnvironmentObject var bento: BentoCLI
    @State private var devices: [PairedDevice] = []
    @State private var error: String?
    @State private var selection: PairedDevice.ID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Table(devices, selection: $selection) {
                TableColumn("Device") { d in
                    Text(d.label?.isEmpty == false ? d.label! : d.deviceID)
                }
                TableColumn("ID") { d in
                    Text(d.deviceID).font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 130)
            }
            .tableStyle(.inset)

            Divider()

            HStack(spacing: 12) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Button("Refresh") { Task { await reload() } }
                Spacer()
                Button("Revoke") {
                    guard let sel = selection else { return }
                    Task {
                        try? await bento.revoke(sel)
                        await reload()
                    }
                }
                .disabled(selection == nil)
                .keyboardShortcut(.delete)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 360)
        .task { await reload() }
    }

    private func reload() async {
        do {
            error = nil
            devices = try await bento.devices()
            // Clear selection if its row vanished.
            if let s = selection, !devices.contains(where: { $0.id == s }) {
                selection = nil
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
