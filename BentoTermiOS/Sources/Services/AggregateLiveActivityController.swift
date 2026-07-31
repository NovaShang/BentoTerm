import ActivityKit
import Foundation

/// Single aggregated Live Activity that summarizes all active sessions.
/// Lifecycle: start on first session, update on every state fan-in, end
/// when all sessions disconnect.
///
/// Accessed only from MainActor (callers are SessionManager). The
/// `@unchecked Sendable` annotation matches the pattern used by the previous
/// LiveActivityService and lets us spawn Tasks that close over the non-
/// Sendable `Activity` reference for fire-and-forget update/end calls.
final class AggregateLiveActivityController: @unchecked Sendable {
    private var activity: Activity<BentoActivityAttributes>?

    @MainActor
    func sync(
        sessions: [SessionManager.SessionEntry],
        spotlightKey: SessionKey? = nil,
        spotlightPrompt: String = ""
    ) {
        // No widget extension ships yet, so areActivitiesEnabled is false and
        // start() can never request — skip building summaries on every state
        // poll unless an activity is live (needs update/end) or could start.
        guard activity != nil || ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let summaries = sessions.prefix(4).map { entry -> BentoActivityAttributes.ContentState.SessionSummary in
            let status: BentoActivityAttributes.ContentState.Status
            switch entry.viewModel.phase {
            case .tmuxReady, .shellReady: status = .active
            case .sshConnecting, .choosingSession, .starting: status = .connecting
            case .suspended: status = .suspended
            case .ended: status = .disconnected
            }
            let awaiting = entry.viewModel.paneViewModels.reduce(0) { acc, p in
                if case .awaitingInput = p.paneState { return acc + 1 }
                return acc
            }
            let label = entry.key.tmuxSessionName.isEmpty
                ? entry.host.displayName
                : "\(entry.host.displayName) · \(entry.key.tmuxSessionName)"
            return .init(
                hostID: entry.key.hostID.uuidString,
                hostName: label,
                status: status,
                awaitingPanes: awaiting
            )
        }

        let totalAwaiting = summaries.reduce(0) { $0 + $1.awaitingPanes }

        let state = BentoActivityAttributes.ContentState(
            sessions: Array(summaries),
            totalAwaiting: totalAwaiting,
            totalSessions: sessions.count,
            latestPrompt: spotlightPrompt,
            lastUpdate: Date()
        )

        if sessions.isEmpty {
            end()
        } else if activity == nil {
            start(state: state)
        } else {
            update(state: state)
        }
    }

    private func start(state: BentoActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let attributes = BentoActivityAttributes()
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(60))
            activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            dlog("Aggregate Live Activity started: \(state.totalSessions) sessions")
        } catch {
            dlog("Failed to start aggregate Live Activity: \(error)")
        }
    }

    private func update(state: BentoActivityAttributes.ContentState) {
        guard let activity else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(60))
        Task { await activity.update(content) }
    }

    private func end() {
        guard let current = activity else { return }
        activity = nil
        let finalState = BentoActivityAttributes.ContentState(
            sessions: [],
            totalAwaiting: 0,
            totalSessions: 0,
            latestPrompt: "",
            lastUpdate: Date()
        )
        let content = ActivityContent(state: finalState, staleDate: nil)
        Task { await current.end(content, dismissalPolicy: .immediate) }
    }
}
