import SwiftUI
import BentoAgentKit
import BentoFoundationKit
import BentoUISharedKit

/// iOS counterpart to BentoTermMac's AgentWizardWindow — hosts the shared
/// `AgentWizardForm` (see BentoUISharedKit) in a NavigationStack sheet with
/// toolbar buttons. The form itself — fields, validity rules, layout grid,
/// telemetry — is shared with Mac; this file is only the presentation chrome.
/// iOS has no directory picker, so `onChooseDirectory` is nil.
struct AgentSessionWizardView: View {
    let onLaunch: (AgentSpec) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AgentWizardModel()

    var body: some View {
        NavigationStack {
            AgentWizardForm(model: model)
                .navigationTitle("New Agent Session")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Launch") { launch() }
                            .disabled(!model.canLaunch)
                    }
                }
        }
    }

    private func launch() {
        let spec = model.spec
        model.recordWorkspaceCreated()
        dismiss()
        onLaunch(spec)
    }
}
