import UIKit

/// Centralized haptic feedback for the app
@MainActor
final class HapticService {
    static let shared = HapticService()
    private init() {}

    private lazy var lightImpact = UIImpactFeedbackGenerator(style: .light)
    private lazy var mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private lazy var selection = UISelectionFeedbackGenerator()
    private lazy var notification = UINotificationFeedbackGenerator()

    /// Light tap — recording started
    func recordingStarted() {
        lightImpact.impactOccurred()
    }

    /// Selection tick — direction threshold crossed
    func directionChanged() {
        selection.selectionChanged()
    }

    /// Success — text sent
    func sent() {
        notification.notificationOccurred(.success)
    }

    /// Warning — cancelled
    func cancelled() {
        notification.notificationOccurred(.warning)
    }

    /// Pane just transitioned to "awaiting input" — let the user know.
    func awaitingTriggered() {
        notification.notificationOccurred(.warning)
    }

    /// Prepare generators for low-latency response
    func prepare() {
        lightImpact.prepare()
        selection.prepare()
        notification.prepare()
    }
}
