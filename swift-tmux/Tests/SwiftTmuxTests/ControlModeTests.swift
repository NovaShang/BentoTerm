import Foundation
import Testing
@testable import SwiftTmux

/// Thread-safe collector for parsed notifications.
final class NotificationCollector: @unchecked Sendable {
    private var _notifications: [TmuxNotification] = []
    private let lock = NSLock()

    var notifications: [TmuxNotification] {
        lock.lock(); defer { lock.unlock() }
        return _notifications
    }

    var lastOutput: Data? {
        lock.lock(); defer { lock.unlock() }
        for n in _notifications.reversed() {
            if case .output(_, let data) = n { return data }
        }
        return nil
    }

    var outputPaneIDs: [TmuxPaneID] {
        lock.lock(); defer { lock.unlock() }
        return _notifications.compactMap { if case .output(let p, _) = $0 { return p } else { return nil } }
    }

    var last: TmuxNotification? {
        lock.lock(); defer { lock.unlock() }
        return _notifications.last
    }

    func collect(_ n: TmuxNotification) {
        lock.lock(); defer { lock.unlock() }
        _notifications.append(n)
    }

    var outputTexts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _notifications.compactMap {
            if case .output(_, let data) = $0 { return String(data: data, encoding: .utf8) }
            return nil
        }
    }
}

func makeService() -> (TmuxControlMode, NotificationCollector) {
    let service = TmuxControlMode()
    let collector = NotificationCollector()
    service.onNotification = { collector.collect($0) }
    return (service, collector)
}

@Suite("%output unescaping")
struct OutputUnescapeTests {
    @Test func plainASCII() {
        let (s, c) = makeService()
        s.feedData(Data("%output %0 hello world\n".utf8))
        #expect(c.lastOutput == "hello world".data(using: .utf8))
    }

    @Test func octalNewline() {
        let (s, c) = makeService()
        s.feedData(Data(#"%output %0 line1\012line2"#.appending("\n").utf8))
        #expect(c.lastOutput == "line1\nline2".data(using: .utf8))
    }

    @Test func octalTab() {
        let (s, c) = makeService()
        s.feedData(Data(#"%output %0 col1\011col2"#.appending("\n").utf8))
        #expect(c.lastOutput == "col1\tcol2".data(using: .utf8))
    }

    @Test func octalCarriageReturn() {
        let (s, c) = makeService()
        s.feedData(Data(#"%output %0 text\015"#.appending("\n").utf8))
        #expect(c.lastOutput == "text\r".data(using: .utf8))
    }

    @Test func octalBackslash() {
        let (s, c) = makeService()
        s.feedData(Data(#"%output %0 path\134file"#.appending("\n").utf8))
        #expect(c.lastOutput == "path\\file".data(using: .utf8))
    }

    @Test func octalEscape() {
        let (s, c) = makeService()
        s.feedData(Data(#"%output %0 \033[31mred\033[0m"#.appending("\n").utf8))
        #expect(c.lastOutput == "\u{1b}[31mred\u{1b}[0m".data(using: .utf8))
    }

    @Test func multipleOctalsInRow() {
        let (s, c) = makeService()
        s.feedData(Data(#"%output %0 \033[2J\033[H"#.appending("\n").utf8))
        #expect(c.lastOutput == "\u{1b}[2J\u{1b}[H".data(using: .utf8))
    }

    @Test func utf8BoxDrawingPreserved() {
        let (s, c) = makeService()
        var rawLine = Data("%output %0 ".utf8)
        rawLine.append(contentsOf: [0xE2, 0x95, 0xAD]) // ╭
        rawLine.append(contentsOf: [0xE2, 0x94, 0x80]) // ─
        rawLine.append(contentsOf: [0xE2, 0x95, 0xAE]) // ╮
        rawLine.append(0x0A)
        s.feedData(rawLine)
        #expect(c.lastOutput == Data([0xE2, 0x95, 0xAD, 0xE2, 0x94, 0x80, 0xE2, 0x95, 0xAE]))
    }

    @Test func utf8ChinesePreserved() {
        let (s, c) = makeService()
        var rawLine = Data("%output %0 ".utf8)
        rawLine.append(contentsOf: [0xE4, 0xBD, 0xA0, 0xE5, 0xA5, 0xBD]) // 你好
        rawLine.append(0x0A)
        s.feedData(rawLine)
        #expect(c.lastOutput == "你好".data(using: .utf8))
    }

    @Test func emptyOutput() {
        let (s, c) = makeService()
        s.feedData(Data("%output %0 \n".utf8))
        #expect(c.lastOutput == Data())
    }

    @Test func paneIDRouting() {
        let (s, c) = makeService()
        s.feedData(Data("%output %0 a\n%output %5 b\n%output %12 c\n".utf8))
        #expect(c.outputPaneIDs == [TmuxPaneID(0), TmuxPaneID(5), TmuxPaneID(12)])
    }
}

@Suite("Notification parsing")
struct NotificationTests {
    @Test func sessionChanged() {
        let (s, c) = makeService()
        s.feedData(Data("%session-changed $0 mysession\n".utf8))
        if case .sessionChanged(let id, let name) = c.last {
            #expect(id == TmuxSessionID(0))
            #expect(name == "mysession")
        } else { Issue.record("Expected sessionChanged") }
    }

    @Test func layoutChange() {
        let (s, c) = makeService()
        s.feedData(Data("%layout-change @0 b25d,80x24,0,0,0\n".utf8))
        if case .layoutChange(let id, let layout) = c.last {
            #expect(id == TmuxWindowID(0))
            #expect(layout == "b25d,80x24,0,0,0")
        } else { Issue.record("Expected layoutChange") }
    }

    @Test func layoutChangeExtraFields() {
        let (s, c) = makeService()
        s.feedData(Data("%layout-change @0 b99d,54x54,0,0,0 b99d,54x54,0,0,0 *\n".utf8))
        if case .layoutChange(let id, let layout) = c.last {
            #expect(id == TmuxWindowID(0))
            #expect(layout == "b99d,54x54,0,0,0")
        } else { Issue.record("Expected layoutChange") }
    }

    @Test func windowAdd() {
        let (s, c) = makeService()
        s.feedData(Data("%window-add @5\n".utf8))
        if case .windowAdd(let id) = c.last {
            #expect(id == TmuxWindowID(5))
        } else { Issue.record("Expected windowAdd") }
    }

    @Test func windowClose() {
        let (s, c) = makeService()
        s.feedData(Data("%window-close @3\n".utf8))
        if case .windowClose(let id) = c.last {
            #expect(id == TmuxWindowID(3))
        } else { Issue.record("Expected windowClose") }
    }

    @Test func exitNoReason() {
        let (s, c) = makeService()
        s.feedData(Data("%exit\n".utf8))
        if case .exit(let reason) = c.last {
            #expect(reason == nil)
        } else { Issue.record("Expected exit") }
    }

    @Test func exitWithReason() {
        let (s, c) = makeService()
        s.feedData(Data("%exit client detached\n".utf8))
        if case .exit(let reason) = c.last {
            #expect(reason == "client detached")
        } else { Issue.record("Expected exit with reason") }
    }

    @Test func ignoredNotificationsNoCrash() {
        let (s, _) = makeService()
        s.feedData(Data("%sessions-changed\n".utf8))
        s.feedData(Data("%unlinked-window-add @1\n".utf8))
        s.feedData(Data("%unlinked-window-close @1\n".utf8))
        s.feedData(Data("%window-pane-changed @0 %1\n".utf8))
        s.feedData(Data("%client-session-changed $1 main\n".utf8))
        // Reached here = no crash.
    }

    @Test func dcsStrippedBeforeNotification() {
        let (s, c) = makeService()
        s.feedData(Data("\u{1b}P1000p%session-changed $0 test\n".utf8))
        if case .sessionChanged(_, let name) = c.last {
            #expect(name == "test")
        } else { Issue.record("Expected sessionChanged after DCS") }
    }
}


/// A service whose connection greeting (the unsolicited first %begin/%end
/// block of a -CC attach) has already been consumed — i.e. a live session.
func makeAttachedService() -> (TmuxControlMode, NotificationCollector) {
    let (s, c) = makeService()
    s.feedData(Data("%begin 0 0 0\n%end 0 0 0\n".utf8))
    return (s, c)
}

@Suite("Response queue")
struct ResponseQueueTests {
    @Test func fireAndForgetDoesNotStealContinuation() async {
        let (service, _) = makeAttachedService()
        let sent = SendableBox<[String]>([])
        service.sendToSSH = { cmd in sent.update { $0.append(cmd) } }

        service.sendFireAndForget(.selectPane(id: TmuxPaneID(0)))

        let task = Task { await service.send(.listPanes()) }
        try? await Task.sleep(for: .milliseconds(50))

        // Two responses arrive. The first is consumed by the fire-and-forget's
        // own queue slot; the second matches the awaited continuation.
        service.feedData(Data("%begin 1 100 1\n%end 1 100 1\n".utf8))
        service.feedData(Data("%begin 1 101 1\npane data\n%end 1 101 1\n".utf8))

        let response = await task.value
        #expect(response.output == "pane data")
        #expect(!response.isError)
    }

    /// The same pair in the other order — which is the order that actually
    /// happens. The 2 s state poll is usually mid-`list-panes` when the user
    /// taps split / zoom / rename / kill, and every one of those is a
    /// fire-and-forget. While fire-and-forgets were a counter checked *before*
    /// the queue, this handed the poll's block to nobody and the poll the next
    /// block along. On a LAN the window is a few milliseconds; at 900 ms RTT it
    /// is a large fraction of the poll period.
    @Test func fireAndForgetIssuedMidFlightKeepsTheOrder() async {
        let (service, _) = makeAttachedService()
        service.sendToSSH = { _ in }

        let task = Task { await service.send(.listPanes()) }
        try? await Task.sleep(for: .milliseconds(50))
        service.sendFireAndForget(.selectPane(id: TmuxPaneID(0)))

        // tmux answers in the order it received them.
        service.feedData(Data("%begin 1 100 1\npane data\n%end 1 100 1\n".utf8))
        service.feedData(Data("%begin 1 101 1\n%end 1 101 1\n".utf8))

        let response = await task.value
        #expect(response.output == "pane data")
        #expect(!response.isError)
    }

    /// A timed-out command leaves a placeholder rather than vacating its slot,
    /// so a merely-slow response is absorbed where it belongs instead of
    /// shifting every later match by one.
    @Test func lateResponseLandsOnItsOwnSlotAfterTimeout() async {
        let (service, _) = makeAttachedService()
        service.sendToSSH = { _ in }

        let slow = Task { await service.send(.listPanes(), timeout: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(50))
        let second = Task { await service.send(.listWindows(), timeout: .seconds(5)) }
        try? await Task.sleep(for: .milliseconds(200))

        #expect(await slow.value.isError)

        // Both responses now arrive, in order. The late one belongs to the
        // abandoned slot, not to the caller queued behind it.
        service.feedData(Data("%begin 1 100 1\nlate panes\n%end 1 100 1\n".utf8))
        service.feedData(Data("%begin 1 101 1\nwindows\n%end 1 101 1\n".utf8))

        #expect(await second.value.output == "windows")
    }

    /// Placeholders are bounded: a response that never arrives would otherwise
    /// keep its slot forever and start eating the next command's block —
    /// the same shift, just deferred.
    @Test func abandonedPlaceholdersAreCapped() async {
        let (service, _) = makeAttachedService()
        service.sendToSSH = { _ in }

        // Nine commands time out with nothing ever arriving; the cap is eight,
        // so exactly one placeholder is dropped.
        for _ in 0..<9 {
            #expect(await service.send(.listPanes(), timeout: .milliseconds(20)).isError)
        }

        let live = Task { await service.send(.listWindows(), timeout: .seconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))

        // Eight stale blocks are swallowed by the surviving placeholders and
        // the ninth reaches the live caller. Uncapped it would take ten.
        for i in 0..<8 {
            service.feedData(Data("%begin 1 \(100 + i) 1\nstale\n%end 1 \(100 + i) 1\n".utf8))
        }
        service.feedData(Data("%begin 1 200 1\nwindows\n%end 1 200 1\n".utf8))

        #expect(await live.value.output == "windows")
    }

    @Test func errorResponseDetected() async {
        let (service, _) = makeAttachedService()
        service.sendToSSH = { _ in }

        let task = Task { await service.send(.listPanes()) }
        try? await Task.sleep(for: .milliseconds(50))

        service.feedData(Data("%begin 1 100 1\nbad command\n%error 1 100 1\n".utf8))

        let response = await task.value
        #expect(response.isError)
        #expect(response.output == "bad command")
    }

    @Test func multiLineResponse() async {
        let (service, _) = makeAttachedService()
        service.sendToSSH = { _ in }

        let task = Task { await service.send(.listPanes()) }
        try? await Task.sleep(for: .milliseconds(50))

        service.feedData(Data("%begin 1 100 1\nline1\nline2\nline3\n%end 1 100 1\n".utf8))

        let response = await task.value
        #expect(response.output == "line1\nline2\nline3")
    }

    /// The window-switch corruption: tmux interleaves an out-of-band
    /// notification (e.g. the `%layout-change` from `select-window`'s repaint)
    /// BETWEEN a command's `%begin` and `%end`. It must be dispatched, not
    /// folded into the command output — otherwise `capture-pane` seeds the
    /// pane's ghostty surface with raw protocol text ("tmux -CC chatter in the
    /// pane") and list-panes/list-windows drop rows.
    @Test func interleavedNotificationDoesNotCorruptBlock() async {
        let (service, collector) = makeAttachedService()
        service.sendToSSH = { _ in }

        let task = Task { await service.send(.listPanes()) }
        try? await Task.sleep(for: .milliseconds(50))

        service.feedData(Data(
            "%begin 1 100 1\nline1\n%layout-change @0 b25d,80x24,0,0,0\nline2\n%end 1 100 1\n".utf8))

        let response = await task.value
        #expect(response.output == "line1\nline2")          // notification NOT in output
        #expect(collector.notifications.contains {
            if case .layoutChange = $0 { return true }; return false
        })
    }

    /// A captured line that merely CONTAINS a control marker as a substring
    /// (e.g. a shell printing "50%end of run") must stay verbatim in the
    /// response — only a line that STARTS with `%end `/`%error ` closes the
    /// block. Guards against the old leading-junk realignment (which used a
    /// substring search) truncating captured content.
    @Test func substringMarkerInBlockStaysContent() async {
        let (service, _) = makeAttachedService()
        service.sendToSSH = { _ in }

        let task = Task { await service.send(.listPanes()) }
        try? await Task.sleep(for: .milliseconds(50))

        service.feedData(Data("%begin 1 100 1\ndone 50%end of run\n%end 1 100 1\n".utf8))

        let response = await task.value
        #expect(response.output == "done 50%end of run")
    }

    /// BUG-007: a notification interleaved in a block can arrive behind a stray
    /// escape/DCS junk prefix (transport framing), so the strict hasPrefix checks
    /// miss it and it would be folded into the response as raw protocol text.
    /// Anchored realignment (non-printable prefix only) must still route it out.
    @Test func junkPrefixedNotificationInBlockRoutedOut() async {
        let (service, collector) = makeAttachedService()
        service.sendToSSH = { _ in }

        let task = Task { await service.send(.listPanes()) }
        try? await Task.sleep(for: .milliseconds(50))

        service.feedData(Data(
            "%begin 1 100 1\nline1\n\u{1b}Pjunk%layout-change @0 b25d,80x24,0,0,0\nline2\n%end 1 100 1\n".utf8))

        let response = await task.value
        #expect(response.output == "line1\nline2")          // chatter NOT folded in
        #expect(collector.notifications.contains {
            if case .layoutChange = $0 { return true }; return false
        })
    }

    /// BUG-007: a `%output` interleaved in a block behind an escape junk prefix
    /// must not paint raw protocol into the captured response.
    @Test func junkPrefixedOutputInBlockNotFolded() async {
        let (service, _) = makeAttachedService()
        service.sendToSSH = { _ in }

        let task = Task { await service.send(.listPanes()) }
        try? await Task.sleep(for: .milliseconds(50))

        service.feedData(Data(
            "%begin 1 100 1\nrow1\n\u{1b}[K%output %0 hello\nrow2\n%end 1 100 1\n".utf8))

        let response = await task.value
        #expect(response.output == "row1\nrow2")
    }

    /// BUG-007 guard: a captured line that STARTS with an escape colour code but
    /// carries no protocol marker must stay verbatim — the non-printable-prefix
    /// anchor must route out chatter without eating real escaped content.
    @Test func escapePrefixedContentWithoutMarkerStaysContent() async {
        let (service, _) = makeAttachedService()
        service.sendToSSH = { _ in }

        let task = Task { await service.send(.listPanes()) }
        try? await Task.sleep(for: .milliseconds(50))

        service.feedData(Data(
            "%begin 1 100 1\n\u{1b}[32mgreen text\u{1b}[0m\n%end 1 100 1\n".utf8))

        let response = await task.value
        #expect(response.output == "\u{1b}[32mgreen text\u{1b}[0m")
    }
}

@Suite("Input hex encoding")
struct InputHexEncodingTests {
    /// `sendData` must hex-encode every byte for `send-keys -H`: lowercase,
    /// two digits, single-space separated — including 0x00 and 0xff.
    @Test func sendDataHexEncodesBytes() async {
        // Attached: pane input is dropped before tmux greets, since the channel
        // is still a plain shell until then.
        let (service, _) = makeAttachedService()
        let sent = SendableBox<[String]>([])
        service.sendToSSH = { cmd in sent.update { $0.append(cmd) } }

        service.sendData(to: TmuxPaneID(0), data: Data([0x00, 0x1b, 0xff]))

        // The leading-edge flush runs async on the input-flush queue; the
        // 16ms trailing flush finds an empty buffer and sends nothing more.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sent.current == ["send-keys -t %0 -H 00 1b ff\n"])
    }
}

@Suite("Chunked input")
struct ChunkedInputTests {
    @Test func splitAcrossChunks() {
        let (s, c) = makeService()
        s.feedData(Data("%output %0 hel".utf8))
        #expect(c.lastOutput == nil) // no newline yet
        s.feedData(Data("lo\n".utf8))
        #expect(c.lastOutput == "hello".data(using: .utf8))
    }

    @Test func multipleLineInOneChunk() {
        let (s, c) = makeService()
        s.feedData(Data("%output %0 first\n%output %0 second\n%output %1 third\n".utf8))
        #expect(c.outputTexts == ["first", "second", "third"])
    }

    @Test func crlfHandled() {
        let (s, c) = makeService()
        s.feedData(Data("%output %0 test\r\n".utf8))
        #expect(c.lastOutput == "test".data(using: .utf8))
    }
}

@Suite("Logging hook")
struct LogHandlerTests {
    @Test func logHandlerReceivesCommands() {
        let service = TmuxControlMode()
        service.sendToSSH = { _ in }
        let captured = SendableBox<[String]>([])
        service.logHandler = { line in captured.update { $0.append(line) } }

        service.sendFireAndForget(.selectPane(id: TmuxPaneID(2)))
        #expect(captured.current.contains { $0.contains("select-pane -t %2") })
    }
}

@Suite("Reconnect state reset")
struct ReconnectResetTests {
    /// `%output` takes the raw fast path in `handleLine` and is immune to a
    /// stuck block — pin that down so the zombie analysis below stays honest.
    @Test func outputBypassesStuckBlock() {
        let (s, c) = makeService()
        s.feedData(Data("%begin 100 5 1\n".utf8))          // truncated block
        s.feedData(Data("%output %0 still-flows\n".utf8))
        #expect(c.outputTexts == ["still-flows"])
    }

    /// The "zombie pane" bug, mechanism 1 — now hardened at the parser: a
    /// response block truncated by a connection drop (`%begin` seen, `%end`
    /// lost) leaves the parser in block-collection mode. Out-of-band
    /// notifications (layout / window / session events) are routed PAST the
    /// stuck block instead of being swallowed as block content — the same
    /// routing that keeps a live `select-window` burst from corrupting a
    /// `capture-pane` seed. `reset()` is still required to clear the stuck
    /// block itself (a new `%begin` would otherwise be eaten as content) and to
    /// realign the FIFO (mechanism 2, below).
    @Test func notificationsSurviveTruncatedBlock() {
        let (s, c) = makeService()
        s.feedData(Data("%begin 100 5 1\n".utf8))          // response starts…
        // …connection dies; %end never arrives. A notification still gets out:
        s.feedData(Data("%layout-change @1 dead,80x24,0,0,1\n".utf8))
        #expect(c.notifications.count == 1)                 // routed out, not swallowed
    }

    /// The "zombie pane" bug, mechanism 2: continuations queued by the dead
    /// connection consume the new connection's response blocks FIFO, starving
    /// the post-reconnect commands. `refreshPanes` on reattach then never
    /// resolves (or resolves with the wrong block), pane view-models get
    /// rebuilt from garbage while surfaces stay bound to the old instances —
    /// input still works, rendering is dead. With the old un-timeboxed
    /// `send()` this hung the reconnect loop forever.
    @Test func orphanedContinuationsStarveNewSendsWithoutReset() async {
        let (s, _) = makeAttachedService()
        s.sendToSSH = { _ in }
        // Dead connection left two commands in flight (never answered). The
        // gap between them pins the FIFO enqueue order (orphan1 then orphan2) —
        // `async let` starts both concurrently, so without it the two sends can
        // append to `pendingQueue` in either order and the block-to-caller
        // matching below is a coin flip.
        async let orphan1 = s.send(.listPanes(), timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(20))
        async let orphan2 = s.send(.listWindows(), timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(50))
        // Reconnect WITHOUT reset. The reattach flow sends list-panes; the
        // new connection delivers its greeting + that one real response.
        // (greetingConsumed is still true from the old connection, so the new
        // greeting is treated as an ordinary response — part of the bug.)
        async let fresh = s.send(.listPanes(), timeout: .milliseconds(300))
        try? await Task.sleep(for: .milliseconds(50))
        s.feedData(Data("%begin 1 0 0\n%end 1 0 0\n".utf8))                 // new greeting
        s.feedData(Data("%begin 2 1 1\n%0 pane data\n%end 2 1 1\n".utf8))   // real response
        let (o1, o2, freshR) = await (orphan1, orphan2, fresh)
        #expect(o1.output.isEmpty)                          // orphan stole the greeting
        #expect(o2.output == "%0 pane data")                // orphan stole the real response
        #expect(freshR.isError)                             // the live caller starved
    }

    @Test func resetFailsPendingContinuations() async {
        let (s, _) = makeService()
        s.sendToSSH = { _ in }                              // command goes nowhere
        async let response = s.send(.listPanes())
        try? await Task.sleep(for: .milliseconds(50))       // let send() enqueue
        s.reset()
        let r = await response
        #expect(r.isError)
        #expect(r.output == "connection reset")
    }

    /// A partial line left in the byte buffer by the dead connection must not
    /// corrupt the first line of the new connection's stream.
    @Test func resetDropsPartialLineBuffer() {
        let (s, c) = makeService()
        s.feedData(Data("%output %0 trunca".utf8))          // no newline — stuck partial
        s.reset()
        s.feedData(Data("%output %1 fresh\n".utf8))
        #expect(c.outputTexts == ["fresh"])
    }

    @Test func responseAfterResetMatchesNewSend() async {
        let (s, _) = makeAttachedService()
        s.sendToSSH = { _ in }
        async let orphan = s.send(.listPanes())             // never answered
        try? await Task.sleep(for: .milliseconds(50))
        s.reset()
        _ = await orphan
        async let fresh = s.send(.listWindows())
        try? await Task.sleep(for: .milliseconds(50))
        s.feedData(Data("%begin 100 8 0\n%end 100 8 0\n".utf8))         // new connection's greeting
        s.feedData(Data("%begin 200 9 1\nwin-1\n%end 200 9 1\n".utf8))  // real response
        let r = await fresh
        #expect(!r.isError)
        #expect(r.output == "win-1")
    }

    /// THE churn regression: a send queued while the greeting block is still
    /// in flight must not have its continuation stolen by the greeting's
    /// `%end`. (This is what awaitControlMode resolving on `%begin` instead of
    /// block completion caused: every response shifted by one, all commands
    /// timed out, the timeout watchdog forced a reconnect, and the cycle
    /// repeated forever.)
    @Test func greetingBlockDoesNotStealSendQueuedMidBlock() async {
        let (s, _) = makeService()
        s.sendToSSH = { _ in }
        s.feedData(Data("%begin 100 1 0\n".utf8))           // greeting starts
        async let r = s.send(.listPanes(), timeout: .seconds(2))
        try? await Task.sleep(for: .milliseconds(50))
        s.feedData(Data("%end 100 1 0\n".utf8))             // greeting completes
        s.feedData(Data("%begin 101 2 1\npane\n%end 101 2 1\n".utf8))
        let resp = await r
        #expect(!resp.isError)
        #expect(resp.output == "pane")
    }
}

@Suite("Send timeout")
struct SendTimeoutTests {
    @Test func sendTimesOutInsteadOfHanging() async {
        let (s, _) = makeService()
        s.sendToSSH = { _ in }                              // no response will come
        let r = await s.send(.listPanes(), timeout: .milliseconds(100))
        #expect(r.isError)
        #expect(r.output.contains("timeout"))
    }

    @Test func responseBeforeTimeoutWins() async {
        let (s, _) = makeAttachedService()
        s.sendToSSH = { _ in }
        async let response = s.send(.listPanes(), timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(50))
        s.feedData(Data("%begin 300 2 1\npane-line\n%end 300 2 1\n".utf8))
        let r = await response
        #expect(!r.isError)
        #expect(r.output == "pane-line")
    }
}

@Suite("Control-mode greeting await")
struct AwaitControlModeTests {
    @Test func resolvesWhenGreetingArrives() async {
        let (s, _) = makeService()
        async let ready = s.awaitControlMode(timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(50))
        s.feedData(Data("%begin 400 1 0\n%end 400 1 0\n".utf8))
        #expect(await ready)
    }

    @Test func resolvesImmediatelyIfAlreadySeen() async {
        let (s, _) = makeService()
        s.feedData(Data("%begin 400 1 0\n%end 400 1 0\n".utf8))
        #expect(await s.awaitControlMode(timeout: .milliseconds(100)))
    }

    @Test func timesOutWhenNoGreeting() async {
        let (s, _) = makeService()
        let ready = await s.awaitControlMode(timeout: .milliseconds(100))
        #expect(!ready)
    }

    @Test func resetRearmsGreetingDetection() async {
        let (s, _) = makeService()
        s.feedData(Data("%begin 400 1 0\n%end 400 1 0\n".utf8))
        s.reset()
        // After reset the OLD greeting must not satisfy a new wait.
        let ready = await s.awaitControlMode(timeout: .milliseconds(100))
        #expect(!ready)
    }
}

// MARK: - Helpers

final class SendableBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
    var current: T { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - Live-transcript replay (path-preview cwd query)

/// Replays the EXACT byte shapes a real `tmux -C attach` produced for
/// `display-message -p -t %5 "#{pane_current_path}"` (captured 2026-07-10,
/// CRLF line endings, greeting block + session-changed first) and asserts
/// `send()` hands the path back. Guards the cwd query path-preview depends on.
@Suite struct DisplayMessageReplayTests {
    @Test func displayMessageRoundTripFromRealTranscript() async throws {
        let cm = TmuxControlMode()
        let sent = NotificationCollector()   // reuse as a thread-safe sink
        cm.sendToSSH = { _ in }
        cm.onNotification = { sent.collect($0) }

        cm.feedData(Data("%begin 1783748239 283462 0\r\n%end 1783748239 283462 0\r\n%session-changed $1 Nova\r\n".utf8))
        let ready = await cm.awaitControlMode(timeout: .seconds(2))
        #expect(ready)

        let pane = try #require(TmuxPaneID(string: "%5"))
        async let respTask = cm.send(
            .displayMessage(format: "#{pane_current_path}", target: pane),
            timeout: .seconds(3))
        try? await Task.sleep(for: .milliseconds(50))
        cm.feedData(Data("%begin 1783748239 283466 1\r\n/Users/nova/code/speakterm\r\n%end 1783748239 283466 1\r\n".utf8))
        let resp = await respTask
        #expect(!resp.isError)
        #expect(resp.output.trimmingCharacters(in: .whitespacesAndNewlines)
                == "/Users/nova/code/speakterm")
    }

    /// Same but with `%output` notifications interleaved inside the response
    /// block, as the live stream showed panes repainting mid-query.
    @Test func displayMessageWithInterleavedOutput() async throws {
        let cm = TmuxControlMode()
        cm.sendToSSH = { _ in }
        cm.onNotification = { _ in }
        cm.feedData(Data("%begin 1 100 0\r\n%end 1 100 0\r\n%session-changed $1 Nova\r\n".utf8))
        _ = await cm.awaitControlMode(timeout: .seconds(2))

        let pane = try #require(TmuxPaneID(string: "%5"))
        async let respTask = cm.send(
            .displayMessage(format: "#{pane_current_path}", target: pane),
            timeout: .seconds(3))
        try? await Task.sleep(for: .milliseconds(50))
        cm.feedData(Data("%output %4 \\033[?2026h\\033[?25l\r\n%begin 1 101 1\r\n/Users/nova/code/speakterm\r\n%output %5 xyz\r\n%end 1 101 1\r\n".utf8))
        let resp = await respTask
        #expect(!resp.isError)
        #expect(resp.output.trimmingCharacters(in: .whitespacesAndNewlines)
                == "/Users/nova/code/speakterm")
    }
}

/// Regression: `sendData` (keystroke / focus-report input via `send-keys -H`)
/// produces an empty %begin/%end response like any command. Before it was
/// registered in the fire-and-forget count, that empty block was matched
/// FIFO to whatever `send()` was pending — path-preview's cwd query mostly
/// got ⟨⟩ back (live-debugged 2026-07-10).
@Suite struct InputResponseAccountingTests {
    @Test func interleavedInputDoesNotStealSendResponse() async throws {
        let cm = TmuxControlMode()
        cm.sendToSSH = { _ in }
        cm.onNotification = { _ in }
        cm.feedData(Data("%begin 1 100 0\r\n%end 1 100 0\r\n%session-changed $1 Nova\r\n".utf8))
        _ = await cm.awaitControlMode(timeout: .seconds(2))

        let pane = try #require(TmuxPaneID(string: "%5"))
        // Focus-report bytes hit the pane right before the query (⌘click
        // makes the surface first responder → CSI I → sendData).
        cm.sendData(to: pane, data: Data([0x1b, 0x5b, 0x49]))
        try? await Task.sleep(for: .milliseconds(40))   // let the input flush fire

        async let respTask = cm.send(
            .displayMessage(format: "#{pane_current_path}", target: pane),
            timeout: .seconds(3))
        try? await Task.sleep(for: .milliseconds(50))

        // tmux answers in wire order: send-keys' EMPTY block first, then the
        // display-message block.
        cm.feedData(Data("%begin 1 101 1\r\n%end 1 101 1\r\n".utf8))
        cm.feedData(Data("%begin 1 102 1\r\n/Users/nova/code/speakterm\r\n%end 1 102 1\r\n".utf8))

        let resp = await respTask
        #expect(!resp.isError)
        #expect(resp.output.trimmingCharacters(in: .whitespacesAndNewlines)
                == "/Users/nova/code/speakterm")
    }
}

@Suite("Pre-greeting writes")
struct PreGreetingWriteTests {
    /// Between `usingTmux` going true and tmux greeting, the channel is still a
    /// plain shell. Anything written there is typed at a prompt — a scroll fling
    /// once put hundreds of `send-keys` lines into zsh, each echoing back
    /// `command not found` into the parser.
    @Test func paneInputIsDroppedBeforeTheGreeting() async {
        let service = TmuxControlMode()          // no greeting fed
        let sent = SendableBox<[String]>([])
        service.sendToSSH = { cmd in sent.update { $0.append(cmd) } }

        service.sendData(to: TmuxPaneID(0), data: Data([0x61]))
        service.sendFireAndForget(.selectPane(id: TmuxPaneID(0)))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sent.current.isEmpty)

        // Once tmux greets, the same writes go out.
        service.feedData(Data("%begin 0 0 0\n%end 0 0 0\n".utf8))
        service.sendData(to: TmuxPaneID(0), data: Data([0x61]))
        service.sendFireAndForget(.selectPane(id: TmuxPaneID(0)))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sent.current.count == 2)
    }

    /// `reset()` unlatches it, so a reconnect cannot inherit the old
    /// connection's permission to write.
    @Test func resetRevokesTheGreeting() async {
        let (service, _) = makeAttachedService()
        let sent = SendableBox<[String]>([])
        service.sendToSSH = { cmd in sent.update { $0.append(cmd) } }

        service.reset()
        service.sendFireAndForget(.selectPane(id: TmuxPaneID(0)))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sent.current.isEmpty)
    }
}
