import Foundation
import Combine
import BentoAgentKit
import BentoFoundationKit

/// Shared state for the agent-session wizard — one instance per presentation.
///
/// Both platforms present the same five-field form (name / working directory /
/// agent / layout) with the same validity rules; what differs is only the
/// chrome around it — Mac wraps it in a titled NSWindow with a bottom action
/// bar, iOS in a NavigationStack sheet. Mac semantics are the reference: the
/// default working directory is `~/code`, inputs are NOT trimmed, and launch
/// failures surface in the shared error section.
@MainActor
public final class AgentWizardModel: ObservableObject {
    @Published public var sessionName: String
    @Published public var workingDir: String
    @Published public var agentPreset: AgentPreset
    @Published public var customCommand: String
    @Published public var layout: TmuxLayout
    @Published public var error: String?

    public init(
        sessionName: String = "agent-\(UUID().uuidString.prefix(8))",
        // NSHomeDirectory() (not FileManager's homeDirectoryForCurrentUser,
        // which is macOS-only): on Mac it's the user's home — same value the
        // Mac wizard always used — and on iOS it's the sandbox home, which is
        // fine for a path the user types over anyway.
        workingDir: String = NSHomeDirectory() + "/code",
        agentPreset: AgentPreset = .claudeCode,
        customCommand: String = "",
        layout: TmuxLayout = .sideBySide
    ) {
        self.sessionName = sessionName
        self.workingDir = workingDir
        self.agentPreset = agentPreset
        self.customCommand = customCommand
        self.layout = layout
    }

    public var canLaunch: Bool {
        !sessionName.isEmpty
            && !workingDir.isEmpty
            && resolvedAgentCommand != nil
    }

    /// nil = invalid (custom selected but field empty). "" = explicit shell.
    public var resolvedAgentCommand: String? {
        switch agentPreset {
        case .custom:
            let trimmed = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return agentPreset.command
        }
    }

    public var spec: AgentSpec {
        AgentSpec(
            sessionName: sessionName,
            workingDir: workingDir,
            agentCommand: resolvedAgentCommand ?? "",
            layout: layout
        )
    }

    // Telemetry — recorded at the same moments on both platforms.

    /// The wizard appeared. Mac records this on appearance, not on launch.
    public func recordAgentWizardLaunched() {
        TelemetryService.shared.record(.agentWizardLaunched)
    }

    /// A session was actually created. Shells call this AFTER their creation
    /// succeeds, never before — a cancelled wizard records nothing.
    public func recordWorkspaceCreated() {
        TelemetryService.shared.record(.workspaceCreated)
    }
}
