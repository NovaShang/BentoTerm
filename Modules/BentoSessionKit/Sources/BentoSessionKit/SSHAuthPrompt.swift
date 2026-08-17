import Foundation

/// A secret `ssh` is waiting for on the terminal it was given.
///
/// The Mac opens a remote host by running `ssh -t <host> "tmux -CC …"` in a pty:
/// ssh runs the command only after authentication, so the launch line can never
/// be typed into a prompt by mistake. What that shape does NOT do is answer the
/// prompt. A host with a password (or a key passphrase, or 2FA) writes its
/// question into the same stream the control-mode parser is reading, and since
/// the question has no trailing newline the parser's line splitter never even
/// sees it — the connection just sat there until the greeting timed out, and
/// then blamed tmux.
///
/// So the pre-greeting bytes get read for a question, and the answer comes from
/// the user (or the Keychain) instead of never arriving.
public struct SSHAuthPrompt: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Account password. The one worth offering to remember.
        case password
        /// Passphrase on a private key. Also worth remembering, and stored
        /// under the key's own name rather than the host's, since one key
        /// unlocks many hosts.
        case passphrase
        /// A code from a phone, token or push app. NEVER remembered — it is
        /// single-use by construction, and storing it would be storing nothing.
        case verificationCode
    }

    public let kind: Kind
    /// The prompt exactly as the remote wrote it, shown verbatim above the
    /// field. Paraphrasing it would hide which of several 2FA methods is being
    /// asked for, and that is the one thing the user needs to read.
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    /// True when answering this a second time means the first answer was wrong,
    /// rather than a second factor being asked for. Drives the "that didn't
    /// work" note, and stops a bad stored secret from being replayed forever.
    public var isRetryable: Bool { kind != .verificationCode }

    /// Whether a stored answer may be offered for this prompt.
    public var isStorable: Bool { kind != .verificationCode }
}

extension SSHAuthPrompt.Kind {
    /// How to name this in a sentence: "bento-review is asking for a password".
    public var noun: String {
        switch self {
        case .password: return "a password"
        case .passphrase: return "a key passphrase"
        case .verificationCode: return "a verification code"
        }
    }
}

/// Read the tail of everything the remote has said so far, and decide whether
/// it ends in a question.
///
/// Works on the tail rather than a line because the prompt is the last thing on
/// the stream and has no newline; requiring the text to END at the question is
/// also what keeps a login banner that merely mentions the word "password" from
/// being mistaken for one.
public func detectSSHAuthPrompt(inTailOf stream: String) -> SSHAuthPrompt? {
    // ssh writes a bare \r before some prompts; normalize so the last "line" is
    // the prompt itself rather than the whole carriage-returned blob.
    let normalized = stream.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    guard let raw = normalized.split(separator: "\n", omittingEmptySubsequences: true).last else {
        return nil
    }
    let line = String(raw).trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty, line.count <= 200 else { return nil }

    // A question, not a statement. `?` covers the yes/no host-key confirmation
    // shape too; that one is not handled here yet (it needs a confirm, not a
    // secret field) and falls through to the timeout as before.
    guard line.hasSuffix(":") else { return nil }
    let lower = line.lowercased()

    // Order matters: "one-time password:" contains "password:", and
    // "enter passphrase" would match a naive "pass" test. Most specific first.
    if lower.contains("passphrase") {
        return SSHAuthPrompt(kind: .passphrase, text: line)
    }
    for marker in ["verification code", "one-time password", "one time password",
                   "passcode", "otp", "two-factor", "2fa", "authenticator", "duo"] {
        if lower.contains(marker) {
            return SSHAuthPrompt(kind: .verificationCode, text: line)
        }
    }
    if lower.contains("password") {
        return SSHAuthPrompt(kind: .password, text: line)
    }
    return nil
}

/// True when the remote just said the last answer was wrong. Used to stop
/// replaying a stored secret that has gone stale — otherwise a changed password
/// would be retried on every reconnect, forever, and lock the account out.
public func sshRejectedLastAnswer(inTailOf stream: String) -> Bool {
    let lower = stream.lowercased()
    return lower.contains("permission denied, please try again")
        || lower.contains("permission denied (")
        || lower.contains("authentication failed")
}
