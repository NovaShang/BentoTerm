import SwiftUI
import BentoSessionKit

/// The words of every session/window confirmation and name prompt, once.
///
/// Each dialog used to be spelled out at every place that raised it — Mac
/// NSAlerts, iOS UIAlertControllers, SwiftUI alerts in the sidebar and the
/// iPhone tabs — and the copies drifted ("The processes running in it will be
/// terminated." here, "Everything running in its panes stops." there; "outside
/// Bento" vs "outside BentoTerm"). The hosts still own HOW a prompt is shown;
/// what it says comes from here.
public enum SessionPromptCopy {

    /// A confirm or name prompt. `placeholder` is set for prompts that take a
    /// name; `message` is nil where the title says it all.
    public struct Prompt: Equatable, Sendable {
        public let title: String
        public let message: String?
        public let confirm: String
        public let placeholder: String?
    }

    public static func closeWindow(_ name: String) -> Prompt {
        Prompt(title: "Close “\(name)”?",
               message: "Everything running in its panes stops.",
               confirm: "Close Window", placeholder: nil)
    }

    public static let renameWindow = Prompt(
        title: "Rename Window",
        message: "tmux stops auto-naming this window from what's running in it.",
        confirm: "Rename", placeholder: "Window name")

    public static let renameSession = Prompt(
        title: "Rename Session", message: nil,
        confirm: "Rename", placeholder: "Session name")

    public static let moveWindowToNewSession = Prompt(
        title: "Move to New Session",
        message: "The window keeps running — it moves to the new session.",
        confirm: "Move", placeholder: "Session name")

    public static let movePaneToNewSession = Prompt(
        title: "Move to New Session",
        message: "The pane keeps running — it becomes a window of the new session.",
        confirm: "Move", placeholder: "Session name")

    /// Flattening a mixed external structure into Focus — the one mode switch
    /// that asks, because it can't be undone exactly.
    public static let flatten = Prompt(
        title: "Switch to Focus mode?",
        message: "This session contains a complex layout created outside BentoTerm. "
            + "Switching will flatten every pane into its own window.",
        confirm: "Flatten", placeholder: nil)

    /// nil name = the session on screen, when the host has no name to hand.
    public static func killSession(_ name: String?) -> Prompt {
        Prompt(title: name.map { "Kill session “\($0)”?" } ?? "Kill this session?",
               message: "Every window and pane in this session is closed and its processes "
                   + "are terminated. This can't be undone.",
               confirm: "Kill Session", placeholder: nil)
    }

    /// The question a move into an unsettled session asks (see
    /// `MoveResult.needsLandingChoice`).
    public struct Landing: Equatable, Sendable {
        public let title: String
        public let message: String
        public let joinCurrentWindow: String
        public let newWindow: String
    }

    public static func landing(_ session: String) -> Landing {
        Landing(title: "Move to “\(session)”",
                message: "That session isn't settled into Parallel or Focus yet. "
                    + "Where should this land?",
                joinCurrentWindow: "Into Current Window (Parallel)",
                newWindow: "As New Window (Focus)")
    }
}

/// The landing question as an `await` for SwiftUI hosts, whose dialogs are
/// state rather than calls: `ask` raises `.moveLandingDialog(_:)` and resumes
/// with the user's pick, or nil if they cancelled. Pass `ask` as a move's
/// `chooseLanding`.
@MainActor
public final class MoveLandingPrompt: ObservableObject {
    /// The session being asked about while the dialog is up.
    @Published public private(set) var session: String?
    private var continuation: CheckedContinuation<MoveLanding?, Never>?
    private var question = 0

    public init() {}

    public func ask(_ session: String) async -> MoveLanding? {
        answer(nil)   // a new question retires one nobody answered
        question += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.session = session
        }
    }

    public func answer(_ landing: MoveLanding?) {
        let pending = continuation
        continuation = nil
        session = nil
        pending?.resume(returning: landing)
    }

    /// The dialog went away without a pick. Deferred a turn: SwiftUI may
    /// report the dismissal before the tapped button's action runs, and that
    /// answer must win. Only cancels the question it was raised for.
    fileprivate func dismissed() {
        let asked = question
        Task { @MainActor [weak self] in
            guard let self, self.question == asked, self.continuation != nil else { return }
            self.answer(nil)
        }
    }
}

public extension View {
    /// Present `prompt`'s landing question as a confirmation dialog.
    func moveLandingDialog(_ prompt: MoveLandingPrompt) -> some View {
        modifier(MoveLandingDialog(prompt: prompt))
    }
}

private struct MoveLandingDialog: ViewModifier {
    @ObservedObject var prompt: MoveLandingPrompt

    func body(content: Content) -> some View {
        let copy = SessionPromptCopy.landing(prompt.session ?? "")
        content.confirmationDialog(
            copy.title,
            isPresented: Binding(
                get: { prompt.session != nil },
                set: { if !$0 { prompt.dismissed() } }
            ),
            titleVisibility: .visible
        ) {
            Button(copy.joinCurrentWindow) { prompt.answer(.joinCurrentWindow) }
            Button(copy.newWindow) { prompt.answer(.newWindow) }
            Button("Cancel", role: .cancel) { prompt.answer(nil) }
        } message: {
            Text(copy.message)
        }
    }
}
