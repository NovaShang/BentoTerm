import Foundation
import BentoVoiceKit
import BentoFoundationKit

public extension TerminalViewModel {
    /// Apply a voice result to the active pane, per the compass direction.
    /// Shared by iOS + macOS (both just hand off the `VoiceInputResult`).
    func handleVoiceResult(_ result: VoiceInputResult) {
        dlog("[voice-result] direction=\(result.direction) '\(result.text)' (\(result.text.count) chars)")
        switch result.direction {
        case .none:
            sendString(result.text)
        case .up:
            sendString(result.text)
            sendReturnDistinct()
        case .left, .right:
            // LLM-assisted: convert NL to a shell command using recent context.
            Task {
                let context = recentPaneContext()
                let command = await LLMService.shared.convertToShellCommand(
                    transcript: result.text,
                    context: context
                )
                if !command.isEmpty {
                    sendString(command)
                    if result.direction == .right { sendReturnDistinct() }
                }
            }
        case .down:
            break
        }
    }

    /// Send Enter as its OWN keystroke, shortly after the text, so it isn't
    /// coalesced into the same `send-keys` burst as the inserted text — a TUI
    /// input box (e.g. Claude Code) treats text+CR arriving together as pasted
    /// content and won't submit, but a standalone CR is a real Enter.
    func sendReturnDistinct() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            if let data = "\r".data(using: .utf8) { sendData(data) }
        }
    }

    /// What the Apple engines' contextual strings are built from, for the
    /// pane a recording targets (the active one: a voice press selects its
    /// pane first). Property reads only — this runs on the main actor at the
    /// start of a hold. `loadHostAliases` is the platform's disk-backed host
    /// list (`~/.ssh/config` on the Mac, saved hosts on iOS); it is run off
    /// the main thread by `ContextVocabulary.gather`.
    func voiceContextSnapshot(loadHostAliases: (@Sendable () -> [String])? = nil) -> VoiceContextSnapshot {
        let paneID = activePaneID
        let pane = paneID.flatMap { id in
            paneViewModels.first { $0.paneID == id }?.pane ?? sessionPanes.first { $0.id == id }
        }
        // Active window first: it is the one being looked at.
        let windowNames = windows.sorted { $0.isActive && !$1.isActive }.map(\.name)
        let hostNames = [host.name, host.hostname].filter { !$0.isEmpty }
        return VoiceContextSnapshot(
            command: pane?.currentCommand,
            cwd: paneID.flatMap { paneWorkingDirectories[$0] },
            paneTitle: pane?.title,
            sessionName: activeTmuxSessionName,
            windowNames: windowNames,
            hostNames: hostNames,
            loadHostAliases: loadHostAliases)
    }

    /// Recent terminal text used as LLM context for the active pane.
    func recentPaneContext() -> String {
        if let activePaneID {
            return recentOutput.recentText(for: activePaneID, lines: 30)
        }
        return ""
    }
}
