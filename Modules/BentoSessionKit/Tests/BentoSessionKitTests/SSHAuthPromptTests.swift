import XCTest
@testable import BentoSessionKit

/// The rule that decides whether `ssh` is waiting on a person.
///
/// Getting this wrong in either direction is bad in a specific way: a missed
/// prompt is the twelve-second timeout that sent us here, and a false positive
/// puts a password field in front of someone whose host is merely printing a
/// banner about password policy.
final class SSHAuthPromptTests: XCTestCase {

    func testTheRealPasswordPromptCapturedFromSSH() {
        // Copied verbatim off the wire: `ssh -t host "tmux -CC …"` against a
        // password-only host writes exactly this, with a leading \r and no
        // newline — which is why the line-based parser never saw it.
        let tail = "\rreviewer@152.70.119.5's password: "
        let prompt = detectSSHAuthPrompt(inTailOf: tail)
        XCTAssertEqual(prompt?.kind, .password)
        XCTAssertEqual(prompt?.text, "reviewer@152.70.119.5's password:")
        XCTAssertTrue(prompt?.isStorable ?? false)
    }

    func testPassphraseBeatsPassword() {
        let prompt = detectSSHAuthPrompt(
            inTailOf: "Enter passphrase for key '/Users/nova/.ssh/id_ed25519': ")
        XCTAssertEqual(prompt?.kind, .passphrase, "a key passphrase is not the account password")
    }

    func testTwoFactorIsNeverTreatedAsAStorablePassword() {
        for line in ["Verification code: ",
                     "(user@host) Duo two-factor login\n\nPasscode or option (1-3): ",
                     "Your one-time password: "] {
            let prompt = detectSSHAuthPrompt(inTailOf: line)
            XCTAssertEqual(prompt?.kind, .verificationCode, "\(line)")
            XCTAssertFalse(prompt?.isStorable ?? true, "a single-use code must never be stored")
        }
    }

    func testOnlyTheTailCounts() {
        // A banner that talks about passwords, followed by the shell getting on
        // with its life, is not a question.
        let banner = """
            Your password will expire in 14 days.
            Last login: Fri Aug 15 04:12:19 2026
            """
        XCTAssertNil(detectSSHAuthPrompt(inTailOf: banner))
        XCTAssertNil(detectSSHAuthPrompt(inTailOf: "tmux: command not found"))
        XCTAssertNil(detectSSHAuthPrompt(inTailOf: ""))
    }

    func testPromptMustEndTheStream() {
        // The prompt arrived, was answered, and the session moved on: whatever
        // is at the end now is not a question we should re-ask.
        let answered = "reviewer@host's password: \nLast login: Fri Aug 15\n%begin 1 0"
        XCTAssertNil(detectSSHAuthPrompt(inTailOf: answered))
    }

    func testHostKeyConfirmationIsNotMistakenForASecret() {
        // It ends in `?`, not `:` — and it needs a yes/no, not a secure field.
        // Deliberately unhandled for now; this test pins that it is not
        // silently answered with a password box.
        let tail = "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
        XCTAssertNil(detectSSHAuthPrompt(inTailOf: tail))
    }

    func testRejectionDetection() {
        XCTAssertTrue(sshRejectedLastAnswer(inTailOf: "Permission denied, please try again."))
        XCTAssertTrue(sshRejectedLastAnswer(
            inTailOf: "reviewer@host: Permission denied (publickey,password)."))
        XCTAssertFalse(sshRejectedLastAnswer(inTailOf: "reviewer@host's password: "))
    }

    func testPromptTextIsShownVerbatim() {
        // The text goes straight into the sheet, so it must not be rewritten:
        // it is what tells a user WHICH factor is being asked for.
        let tail = "(reviewer@host) Duo passcode, or option (1-3): "
        XCTAssertEqual(detectSSHAuthPrompt(inTailOf: tail)?.text,
                       "(reviewer@host) Duo passcode, or option (1-3):")
    }
}
