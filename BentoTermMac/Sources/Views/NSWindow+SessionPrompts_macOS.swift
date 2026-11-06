import BentoUISharedKit
import BentoSessionKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

// MARK: - Session prompts as sheets

extension NSWindow {
    /// The landing question for a move into an unsettled session, as a sheet
    /// on this window; nil = cancelled. Pass it as a move's `chooseLanding`.
    func askMoveLanding(session: String) async -> MoveLanding? {
        let copy = SessionPromptCopy.landing(session)
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.message
        alert.addButton(withTitle: copy.joinCurrentWindow)
        alert.addButton(withTitle: copy.newWindow)
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: self) { response in
                switch response {
                case .alertFirstButtonReturn:  continuation.resume(returning: .joinCurrentWindow)
                case .alertSecondButtonReturn: continuation.resume(returning: .newWindow)
                default:                       continuation.resume(returning: nil)
                }
            }
        }
    }

    /// A one-field name prompt as a sheet on this window: the typed text, or
    /// nil if cancelled.
    func askName(_ prompt: SessionPromptCopy.Prompt, initial: String = "") async -> String? {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message ?? ""
        alert.addButton(withTitle: prompt.confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = prompt.placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: self) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn
                                    ? field.stringValue : nil)
            }
        }
    }
}
#endif
