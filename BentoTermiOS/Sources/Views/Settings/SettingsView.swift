import SwiftUI
import BentoFoundationKit
import BentoUISharedKit

/// iOS settings = the setup pages, as a list you drill into.
///
/// Same five panels the setup flow shows, same names, same order — explanation
/// arrives folded here and open there, and that is the only difference
/// (`PanelContext`). See `IOSSetupPanel` for where the iOS-only rows hang.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(PanelPage.allCases) { page in
                    NavigationLink {
                        IOSSetupPanel(page: page, context: .settings)
                            .bentoForm()
                            .navigationTitle(page.settingsTitle)
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label(page.settingsTitle, systemImage: page.symbol)
                    }
                }

            }
            .tint(Color.bentoEmerald)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The open-source notices, read from the `Acknowledgements.txt` generated
/// against the resolved package graph.
///
/// Kept as a bundled text file rather than a Swift literal so regenerating it
/// after a dependency bump is a file write, not a source edit — and so the
/// notices are verbatim upstream text, which is what MIT, Apache-2.0 and the
/// SIL OFL actually require to accompany a redistributed binary.
struct AcknowledgementsView: View {
    @State private var text: String?

    var body: some View {
        ScrollView {
            Text(text ?? "Acknowledgements are unavailable in this build.")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard text == nil,
                  let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt")
            else { return }
            // ~110 KB off the main thread — the view is pushed before it lands.
            text = await Task.detached { try? String(contentsOf: url, encoding: .utf8) }.value
        }
    }
}
