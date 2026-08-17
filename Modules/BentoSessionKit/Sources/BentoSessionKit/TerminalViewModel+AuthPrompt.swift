import Foundation
import BentoFoundationKit

extension TerminalViewModel {

    // MARK: - Answering ssh

    /// Watch the pre-greeting stream for a question ssh is waiting on.
    ///
    /// Only installed for transports that carry the `tmux -CC` invocation
    /// themselves (`ssh -t host "tmux -CC …"`), because that is the only shape
    /// where nobody is rendering the raw stream: a shell transport shows its own
    /// prompts on screen and the user can just answer them.
    func watchForAuthPrompts() {
        guard transport.startsInTmuxControlMode else { return }
        tmuxService.onPreGreetingText = { [weak self] tail in
            Task { @MainActor in self?.considerAuthPrompt(in: tail) }
        }
    }

    /// Decide what the accumulated pre-greeting tail means. Called on every
    /// pre-greeting chunk, so it must be idempotent — the same prompt arriving
    /// in three chunks is one question, not three.
    func considerAuthPrompt(in tail: String) {
        if sshRejectedLastAnswer(inTailOf: tail), !storedSecretRejected {
            // A stored secret that no longer works must not be replayed: on a
            // host that locks accounts, an app that retries a stale password on
            // every reconnect is worse than an app that asks.
            storedSecretRejected = true
            // The retry prompt reads identically to the first one, so the
            // dedupe has to forget it or the second ask would be swallowed.
            lastSeenAuthPrompt = nil
        }
        guard let prompt = detectSSHAuthPrompt(inTailOf: tail) else { return }
        // The same prompt text, still sitting there, is still one question —
        // it arrives in as many chunks as the network feels like.
        guard prompt != lastSeenAuthPrompt else { return }
        lastSeenAuthPrompt = prompt
        dlog("ssh is asking for \(prompt.kind): \(prompt.text)")

        // Try the keychain BEFORE putting a sheet on screen: a remembered
        // password should look like no prompt at all, not like a dialog that
        // flashes and dismisses itself.
        // A second ask after a rejection is a retry, not a second factor — say
        // so, rather than showing an identical empty field.
        let rejected = storedSecretRejected && prompt.isRetryable
        guard prompt.isStorable, !storedSecretRejected else {
            authPromptRejected = rejected
            authPrompt = prompt
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let stored = await self.environment.loadKeychainPassword(self.secretKey(for: prompt))
            await MainActor.run {
                guard self.lastSeenAuthPrompt == prompt, self.authPrompt == nil else { return }
                if let stored, !stored.isEmpty, !self.storedSecretRejected {
                    dlog("answering \(prompt.kind) from the keychain")
                    self.answer(prompt, with: stored, remember: false)
                    return
                }
                self.authPromptRejected = self.storedSecretRejected && prompt.isRetryable
                self.authPrompt = prompt
            }
        }
    }

    /// Send an answer typed by the user, optionally remembering it.
    public func submitAuthPrompt(_ secret: String, remember: Bool) {
        guard let prompt = authPrompt else { return }
        // A fresh answer earns a fresh chance at the keychain path.
        storedSecretRejected = false
        answer(prompt, with: secret, remember: remember && prompt.isStorable)
    }

    /// Give up on the connection rather than sit at a prompt nobody will answer.
    public func cancelAuthPrompt() {
        dlog("auth prompt cancelled — disconnecting")
        authPrompt = nil
        authPromptRejected = false
        disconnect()
    }

    private func answer(_ prompt: SSHAuthPrompt, with secret: String, remember: Bool) {
        authPrompt = nil
        authPromptRejected = false
        authPromptsAnswered += 1
        // ssh reads the secret from the tty and echoes nothing; the newline is
        // what submits it.
        transport.write(secret + "\n")
        guard remember else { return }
        let key = secretKey(for: prompt)
        Task { [environment] in await environment.saveKeychainPassword(key, secret) }
    }

    /// Where a secret lives in the keychain.
    ///
    /// A passphrase belongs to the key, not the host — one key opens many hosts,
    /// and storing it per host would ask for the same passphrase again on the
    /// next host and store a second copy of it.
    private func secretKey(for prompt: SSHAuthPrompt) -> String {
        switch prompt.kind {
        case .passphrase:
            // "Enter passphrase for key '/Users/me/.ssh/id_ed25519':"
            let path = prompt.text.split(separator: "'").dropFirst().first.map(String.init)
            return "sshPassphrase:\(path ?? prompt.text)"
        case .password, .verificationCode:
            return "sshPassword:\(host.name)"
        }
    }

    /// Wait for the tmux greeting, without counting the time a person spends
    /// typing a password against it.
    ///
    /// The flat 12s deadline is right for "tmux isn't coming"; it is far too
    /// short for "someone has to find their phone and read a 2FA code". Each
    /// answered prompt buys another window, and an unanswered prompt is not a
    /// failure to report — the sheet is on screen and the user is deciding.
    func awaitGreetingAllowingAuthPrompts(timeout: Duration) async -> Bool {
        var answeredSoFar = authPromptsAnswered
        while true {
            if await tmuxService.awaitControlMode(timeout: timeout) { return true }
            // Still nothing. If a question is on screen, or one was answered
            // while we waited, this deadline measured the wrong thing.
            let answeredSinceLastWait = authPromptsAnswered != answeredSoFar
            guard authPrompt != nil || answeredSinceLastWait else { return false }
            answeredSoFar = authPromptsAnswered
        }
    }
}
