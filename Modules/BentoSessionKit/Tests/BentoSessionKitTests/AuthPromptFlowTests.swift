import XCTest
import BentoFoundationKit
@testable import BentoSessionKit

/// End-to-end over the plumbing that was actually broken: bytes off the wire →
/// the control-mode parser → the view model → an answer typed back at ssh.
///
/// The unit tests next door cover the rule; this covers the wiring, because the
/// bug was never in the rule. The prompt reached the app perfectly well and then
/// fell down the gap between "bytes" and "lines".
@MainActor
final class AuthPromptFlowTests: XCTestCase {

    /// Minimal transport that records what gets typed into it.
    private final class FakeTransport: TerminalTransport, @unchecked Sendable {
        var state: TerminalConnectionState = .connected
        var onDataReceived: (@Sendable (Data) -> Void)?
        var onStateChanged: (@Sendable (TerminalConnectionState) -> Void)?
        var isLocalLink: Bool { false }
        /// The shape this whole feature exists for: `ssh -t host "tmux -CC …"`.
        var startsInTmuxControlMode: Bool { true }
        private(set) var written: [String] = []
        private(set) var disconnected = false

        func connect(host: BentoFoundationKit.Host) async {}
        func startShell(cols: Int, rows: Int) {}
        func write(_ data: Data) { written.append(String(decoding: data, as: UTF8.self)) }
        func write(_ string: String) { written.append(string) }
        func resize(cols: Int, rows: Int) {}
        func disconnect() { disconnected = true }
    }

    private func makeVM(
        stored: String? = nil,
        onSave: @escaping @Sendable (String, String) -> Void = { _, _ in }
    ) -> (TerminalViewModel, FakeTransport) {
        let transport = FakeTransport()
        let env = TerminalEnvironment(
            loadKeychainPassword: { _ in stored },
            saveKeychainPassword: { key, value in onSave(key, value) })
        let vm = TerminalViewModel(
            host: BentoFoundationKit.Host(name: "bento-review"), transport: transport, environment: env)
        return (vm, transport)
    }

    /// Feed bytes the way the transport does, and let the parse queue drain.
    private func feed(_ vm: TerminalViewModel, _ text: String) async {
        vm.tmuxService.feedData(Data(text.utf8))
        // The callback hops to the main actor; give it a turn to land.
        try? await Task.sleep(for: .milliseconds(50))
    }

    func testAPasswordPromptBecomesAQuestionInsteadOfATimeout() async {
        let (vm, _) = makeVM()
        await feed(vm, "\rreviewer@152.70.119.5's password: ")
        XCTAssertEqual(vm.authPrompt?.kind, .password)
        XCTAssertFalse(vm.authPromptRejected)
    }

    func testAnsweringTypesTheSecretAndANewline() async {
        let (vm, transport) = makeVM()
        await feed(vm, "\rreviewer@host's password: ")
        vm.submitAuthPrompt("hunter2", remember: false)
        XCTAssertEqual(transport.written, ["hunter2\n"])
        XCTAssertNil(vm.authPrompt, "the sheet goes away once it is answered")
    }

    func testRememberingStoresUnderTheHostAndAnsweringDoesNot() async {
        let saved = LockedBox()
        let (vm, _) = makeVM(onSave: { key, value in saved.set(key, value) })
        await feed(vm, "\rreviewer@host's password: ")
        vm.submitAuthPrompt("hunter2", remember: true)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(saved.key, "sshPassword:bento-review")
        XCTAssertEqual(saved.value, "hunter2")
    }

    func testAStoredPasswordAnswersWithoutAskingAnyone() async {
        let (vm, transport) = makeVM(stored: "from-keychain")
        await feed(vm, "\rreviewer@host's password: ")
        XCTAssertNil(vm.authPrompt, "a remembered password should look like no prompt at all")
        XCTAssertEqual(transport.written, ["from-keychain\n"])
    }

    func testARejectedStoredPasswordIsAskedAboutRatherThanReplayed() async {
        let (vm, transport) = makeVM(stored: "stale")
        await feed(vm, "\rreviewer@host's password: ")
        XCTAssertEqual(transport.written, ["stale\n"])

        // ssh refuses it and asks again — the same text as the first ask.
        await feed(vm, "\nPermission denied, please try again.\nreviewer@host's password: ")
        XCTAssertEqual(vm.authPrompt?.kind, .password, "the second ask must reach the user")
        XCTAssertTrue(vm.authPromptRejected, "and must say the last answer was refused")
        XCTAssertEqual(transport.written, ["stale\n"], "the stale secret is not replayed")
    }

    func testTheSameChunkedPromptIsOneQuestion() async {
        let (vm, _) = makeVM()
        await feed(vm, "\rreviewer@host's ")
        await feed(vm, "password: ")
        XCTAssertEqual(vm.authPrompt?.kind, .password)
        let first = vm.authPrompt
        await feed(vm, "")           // a keepalive chunk changes nothing
        XCTAssertEqual(vm.authPrompt, first)
    }

    func testCancellingHangsUpRatherThanWaitingForever() async {
        let (vm, transport) = makeVM()
        await feed(vm, "\rreviewer@host's password: ")
        vm.cancelAuthPrompt()
        XCTAssertNil(vm.authPrompt)
        XCTAssertTrue(transport.disconnected)
    }

    func testAVerificationCodeIsNeverStored() async {
        let saved = LockedBox()
        let (vm, _) = makeVM(stored: "should-not-be-used",
                             onSave: { key, value in saved.set(key, value) })
        await feed(vm, "\r(reviewer@host) Duo passcode, or option (1-3): ")
        XCTAssertEqual(vm.authPrompt?.kind, .verificationCode)
        // Even asking to remember it must not: the code is spent on use.
        vm.submitAuthPrompt("123456", remember: true)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(saved.key)
    }
}

/// Tiny thread-safe box — the save hook is `@Sendable` and fires off-actor.
private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _key: String?
    private var _value: String?
    var key: String? { lock.withLock { _key } }
    var value: String? { lock.withLock { _value } }
    func set(_ key: String, _ value: String) { lock.withLock { _key = key; _value = value } }
}
