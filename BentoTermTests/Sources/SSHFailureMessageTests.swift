import Testing
@testable import BentoTerm
import BentoFoundationKit
import Citadel
import NIO
import Foundation

/// What these assert is not the wording — it's that two different causes never
/// produce the same sentence. Every type on this path bridges to the identical
/// `NSError` string, so "the message is specific" is the only property worth
/// pinning down; the exact phrasing is free to change.
@Suite("SSH failure messages")
struct SSHFailureMessageTests {

    private func host(
        auth: AuthMethod = .password,
        hostname: String = "box.example.com",
        port: UInt16 = 22
    ) -> Host {
        Host(name: "Box", hostname: hostname, port: port, username: "nova", authMethod: auth)
    }

    private func message(
        _ error: Error,
        auth: AuthMethod = .password,
        during context: SSHFailureContext = .connecting
    ) -> String {
        sshFailureMessage(for: error, host: host(auth: auth), during: context)
    }

    // MARK: - The bug this file exists for

    @Test("No message falls back to the NSError sentence")
    func neverTheGenericNSErrorSentence() {
        let errors: [Error] = [
            SSHClientError.allAuthenticationOptionsFailed,
            SSHClientError.unsupportedPasswordAuthentication,
            SSHClientError.unsupportedPrivateKeyAuthentication,
            CitadelError.unauthorized,
            ChannelError.connectTimeout(.seconds(10)),
            ChannelError.connectTimeout(.seconds(30)),
            ChannelError.eof,
            IOError(errnoCode: ECONNREFUSED, reason: "connect"),
            POSIXError(.ETIMEDOUT),
            KeychainError.itemNotFound,
            SocketAddressError.failedToParseIPString("not an ip"),
        ]
        for error in errors {
            let m = message(error)
            #expect(!m.contains("The operation couldn"), "leaked NSError text for \(error)")
            #expect(!m.contains("error 1."), "leaked a case index for \(error)")
        }
    }

    @Test("Distinct causes get distinct sentences")
    func causesAreDistinguishable() {
        let messages = [
            message(SSHClientError.allAuthenticationOptionsFailed),
            message(SSHClientError.unsupportedPasswordAuthentication),
            message(ChannelError.connectTimeout(.seconds(10))),
            message(ChannelError.connectTimeout(.seconds(30))),
            message(IOError(errnoCode: ECONNREFUSED, reason: "connect")),
            message(IOError(errnoCode: EHOSTUNREACH, reason: "connect")),
            message(KeychainError.itemNotFound),
        ]
        #expect(Set(messages).count == messages.count)
    }

    // MARK: - Authentication

    /// A wrong username and a wrong password are one error on the wire — SSH
    /// won't say which, so the message must point at both. This is the exact
    /// case that reported as "Failed to connect".
    @Test("A rejected login names the username as well as the secret")
    func rejectionNamesBothHalves() {
        let pw = message(SSHClientError.allAuthenticationOptionsFailed, auth: .password)
        #expect(pw.contains("nova"))
        #expect(pw.contains("password"))
        #expect(!pw.contains("authorized_keys"))

        let key = message(SSHClientError.allAuthenticationOptionsFailed, auth: .privateKey(keyLabel: "bento"))
        #expect(key.contains("nova"))
        #expect(key.contains("authorized_keys"))

        // Citadel throws several unrelated shapes for the same event.
        // (`AuthenticationFailed` is the third; it is public but its memberwise
        // init is not, so it can only be covered by the mapper, not a test.)
        #expect(message(CitadelError.unauthorized) == pw)
    }

    @Test("A server that forbids passwords is not a wrong password")
    func passwordAuthDisabledIsItsOwnMessage() {
        let m = message(SSHClientError.unsupportedPasswordAuthentication)
        #expect(m.contains("doesn't accept password logins"))
        #expect(m != message(SSHClientError.allAuthenticationOptionsFailed))
    }

    // MARK: - Reachability

    @Test("Connection refused names the port that refused")
    func refusedNamesThePort() {
        let m = sshFailureMessage(
            for: IOError(errnoCode: ECONNREFUSED, reason: "connect"),
            host: host(port: 2222),
            during: .connecting
        )
        #expect(m.contains("box.example.com:2222"))
        #expect(m.contains("refused"))
    }

    @Test("errno reaches the message through POSIXError as well as IOError")
    func posixErrorIsMappedToo() {
        #expect(message(POSIXError(.ECONNREFUSED)).contains("refused"))
        #expect(message(POSIXError(.EHOSTUNREACH)).contains("No route"))
    }

    // MARK: - The two timeouts that share one case

    @Test("Citadel's 10s login timeout is not NIO's TCP timeout")
    func loginTimeoutIsDistinctFromConnectTimeout() {
        let login = message(ChannelError.connectTimeout(.seconds(10)))
        let tcp = message(ChannelError.connectTimeout(.seconds(30)))
        #expect(login.contains("login"))
        #expect(tcp.contains("30 seconds"))
        #expect(login != tcp)
    }

    // MARK: - Context

    @Test("A closed channel reads differently before and after login")
    func contextChangesTheSentence() {
        let connecting = message(ChannelError.eof, during: .connecting)
        let session = message(ChannelError.eof, during: .session)
        #expect(connecting.contains("before login completed"))
        #expect(session.contains("was closed"))
    }

    // MARK: - Fallback

    @Test("An unmapped error still names the host and carries the raw form")
    func unmappedErrorStaysReportable() {
        struct Weird: Error {}
        let m = message(Weird())
        #expect(m.contains("Box"))
        #expect(m.contains("Weird"))
    }

    /// Citadel's `Disconnected` is private to a function body, so the mapper
    /// matches it by type name — which is exactly the kind of hack that rots
    /// silently. A local stand-in with the same name pins the behaviour down.
    /// (Probed against a live HTTP port: this, not `NIOSSHError`, is what
    /// aiming at a non-SSH port actually produces.)
    @Test("A channel that dies without an error of its own points at the port")
    func disconnectedIsMatchedByName() {
        struct Disconnected: Error {}
        let m = sshFailureMessage(for: Disconnected(), host: host(port: 80), during: .connecting)
        #expect(m.contains("port 80"))
        #expect(!m.contains("Disconnected()"), "fell through to the raw fallback")
    }

    @Test("Our own LocalizedError types keep their own wording")
    func localizedErrorsArePreserved() {
        #expect(message(SSHError.invalidKeyFormat) == "Invalid SSH key format.")
    }
}
