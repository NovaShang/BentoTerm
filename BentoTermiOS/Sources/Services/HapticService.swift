import UIKit

/// Centralized haptic feedback for the app
@MainActor
final class HapticService {
    static let shared = HapticService()
    private init() {
        UserDefaults.standard.register(defaults: ["haptics_enabled": true])
    }

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "haptics_enabled")
    }

    private lazy var lightImpact = UIImpactFeedbackGenerator(style: .light)
    private lazy var mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private lazy var selection = UISelectionFeedbackGenerator()
    private lazy var notification = UINotificationFeedbackGenerator()

    /// Light tap — recording started
    func recordingStarted() {
        guard isEnabled else { return }
        lightImpact.impactOccurred()
    }

    /// Selection tick — direction threshold crossed
    func directionChanged() {
        guard isEnabled else { return }
        selection.selectionChanged()
    }

    /// Success — text sent
    func sent() {
        guard isEnabled else { return }
        notification.notificationOccurred(.success)
    }

    /// Warning — cancelled
    func cancelled() {
        guard isEnabled else { return }
        notification.notificationOccurred(.warning)
    }

    /// Pane just transitioned to "awaiting input" — let the user know.
    func awaitingTriggered() {
        guard isEnabled else { return }
        notification.notificationOccurred(.warning)
    }

    /// Prepare generators for low-latency response
    func prepare() {
        lightImpact.prepare()
        selection.prepare()
        notification.prepare()
    }
}
