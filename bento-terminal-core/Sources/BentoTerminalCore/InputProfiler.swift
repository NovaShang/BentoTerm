import Foundation
import os

/// Keystroke-latency profiler.
///
/// A keystroke's round trip crosses six thread hops before a pixel changes:
///
///   keyDown (main) → ghostty encode (main) → tmux input batch (inputFlushQueue)
///   → PTY write → tmux → PTY read source (main) → tmux parse (tmuxParseQueue)
///   → notification drain (main) → PaneViewModel.feedData (main)
///   → ghostty process_output (ioQueue) → draw (renderQueue)
///
/// Wall-clock latency is dominated not by the work in each segment but by the
/// time a segment spends QUEUED behind something else — above all behind the
/// main thread. So every hop is measured twice: `*Hop` stages are pure queueing
/// delay (enqueue → callee entry), the others are execution time.
///
/// Disabled by default and gated on a single `static let`, so a non-profiling
/// build pays one predictable branch per call site.
///
/// Enable with `BENTO_PROFILE=1` in the environment, or
/// `defaults write com.bento.menubar BentoProfileInput -bool YES`.
/// Summary is rewritten every `BENTO_PROFILE_INTERVAL` seconds (default 2) to
/// `BENTO_PROFILE_OUT` (default `/tmp/bento-input-profile.txt`).
public enum Prof {

    // MARK: - Stages

    public enum Stage: Int, CaseIterable {
        // ---- outbound: key → PTY ----
        /// Whole `NSView.keyDown`, including the IME round trip. [main]
        case keyDown
        /// The AppKit event's own age when we first see it: `now − event.timestamp`.
        /// This is the pure "main thread was busy, your key waited" number. [main]
        case keyEventLag
        /// `inputContext.handleEvent` — the synchronous trip through macOS's
        /// input method system, which every printable keystroke makes. [main]
        case imeHandleEvent
        /// Main-thread work by OTHER stages that ran INSIDE `imeHandleEvent`.
        /// IMK's synchronous call spins the runloop, so output processing can be
        /// re-entered from inside a keystroke. Large value here means the IME
        /// call isn't slow by itself — it's absorbing the output pipeline. [main]
        case imeReentrant
        /// Our NSTextInputClient replies to IMK's synchronous queries
        /// (selectedRange, markedRange, attributedSubstring, …). IMK asks on
        /// every keystroke, so a slow reply here would show up as a slow
        /// `imeHandleEvent`. [main]
        case imeCallback
        /// `firstRect(forCharacterRange:)` — measured apart from the other
        /// callbacks because it calls `convertToScreen`, which can reach the
        /// window server, unlike the constant-returning ones. [main]
        case imeFirstRect
        /// `sendKeyEvent` → `ghostty_surface_key` returns. [main]
        case keyEncode
        /// ghostty's write-to-host → `PaneViewModel.sendInput` → tmux enqueue. [main]
        case hostWrite
        /// tmux input enqueue → the batched `sendToSSH` callback fires.
        /// Includes the 16ms trailing coalesce window (leading edge should be ~0).
        case inputBatchWait
        /// `sendToSSH` → `LocalPty.write` returns (the write(2) syscall).
        case transportWrite

        // ---- inbound: PTY → pixels ----
        /// PTY read source fired → its `DispatchQueue.main.async` body starts. [queue]
        case ptyReadHop
        /// The transport callback's `Task { @MainActor }` → `routeIncomingData`
        /// entry. A second main-thread enqueue on top of `ptyReadHop`, and the
        /// main actor's executor queue is not the runloop's, so it can be
        /// starved independently. [queue]
        case mainActorHop
        /// `routeIncomingData` body. [main]
        case routeIn
        /// dispatch to `tmuxParseQueue` → parse starts. [queue]
        case parseHop
        /// `TmuxControlMode.feedData` — control-mode protocol parse. [off-main]
        case tmuxParse
        /// Notification enqueued off-main → `drainTmuxNotifications` starts. [queue]
        /// The prime suspect: this is output waiting for the main thread.
        case drainHop
        /// `drainTmuxNotifications` body, all coalesced notifications. [main]
        case drain
        /// `PaneViewModel.feedData`: title strip + history append + forward. [main]
        case paneFeed
        /// The O(n) front-trim of `_history`. [main]
        case historyTrim
        /// `surface.feed` → `processFeed` starts on ioQueue. [queue]
        case surfaceFeedHop
        /// `ghostty_surface_process_output` + refresh. [ioQueue]
        case processOutput
        /// `ghostty_surface_draw`. [renderQueue]
        case draw

        // ---- whole-system ----
        /// `GhosttyRuntime.tick()`. [main]
        case runtimeTick
        /// One main-runloop busy stretch (wake → about to sleep). The headline
        /// number: anything over ~16ms is a dropped frame and feels like a hitch.
        case mainTurn
        /// keyDown → the process_output that carried its echo. End-to-end.
        case echoRTT

        var label: String {
            switch self {
            case .keyDown: return "keyDown"
            case .keyEventLag: return "keyEventLag"
            case .imeHandleEvent: return "imeHandleEvent"
            case .imeReentrant: return "imeReentrant"
            case .imeCallback: return "imeCallback"
            case .imeFirstRect: return "imeFirstRect"
            case .keyEncode: return "keyEncode"
            case .hostWrite: return "hostWrite"
            case .inputBatchWait: return "inputBatchWait"
            case .transportWrite: return "transportWrite"
            case .ptyReadHop: return "ptyReadHop"
            case .mainActorHop: return "mainActorHop"
            case .routeIn: return "routeIn"
            case .parseHop: return "parseHop"
            case .tmuxParse: return "tmuxParse"
            case .drainHop: return "drainHop"
            case .drain: return "drain"
            case .paneFeed: return "paneFeed"
            case .historyTrim: return "historyTrim"
            case .surfaceFeedHop: return "surfaceFeedHop"
            case .processOutput: return "processOutput"
            case .draw: return "draw"
            case .runtimeTick: return "runtimeTick"
            case .mainTurn: return "mainTurn"
            case .echoRTT: return "echoRTT"
            }
        }

        /// Queueing-delay stages — time spent waiting, not working.
        var isQueueDelay: Bool {
            switch self {
            case .keyEventLag, .ptyReadHop, .mainActorHop, .parseHop, .drainHop,
                 .surfaceFeedHop, .inputBatchWait:
                return true
            default:
                return false
            }
        }

        /// Runs on the main thread, so it contributes to a hitch. `imeReentrant`
        /// is excluded on purpose: it double-counts time already attributed to
        /// the output stages it is measuring.
        var onMain: Bool {
            switch self {
            case .keyDown, .imeHandleEvent, .imeCallback, .imeFirstRect,
                 .keyEncode, .hostWrite, .routeIn,
                 .drain, .paneFeed, .historyTrim, .runtimeTick:
                return true
            default:
                return false
            }
        }

        /// Main-thread stages belonging to the OUTPUT pipeline (bytes → screen),
        /// as opposed to the input pipeline. Tracked cumulatively so we can ask
        /// "did output processing run while this keystroke was being handled?"
        var isOutputPipeline: Bool {
            switch self {
            case .routeIn, .drain, .paneFeed, .historyTrim, .runtimeTick:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Switch

    /// Read once. A disabled build is one static-let load plus a branch.
    public static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["BENTO_PROFILE"] == "1" { return true }
        if env["BENTO_PROFILE"] == "0" { return false }
        return UserDefaults.standard.bool(forKey: "BentoProfileInput")
    }()

    /// Also emit os_signpost intervals so Instruments' Points of Interest track
    /// lines up with a Time Profiler / System Trace recording. Costs real time
    /// per call, so it's a separate opt-in: `BENTO_PROFILE_SIGNPOST=1`.
    public static let signpostsEnabled: Bool = {
        enabled && ProcessInfo.processInfo.environment["BENTO_PROFILE_SIGNPOST"] == "1"
    }()

    private static let signposter =
        OSSignposter(subsystem: "com.novashang.bento", category: "InputLatency")

    // MARK: - Clock

    @inline(__always)
    public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    // MARK: - Storage

    /// Log-scale histogram: 4 buckets per octave, 128 buckets ≈ 1ns … 4s.
    private static let bucketCount = 128

    private struct StageStats {
        var count: UInt64 = 0
        var sumNs: UInt64 = 0
        var maxNs: UInt64 = 0
        var buckets = [UInt32](repeating: 0, count: Prof.bucketCount)
    }

    /// A sample counts as "while typing" if it lands within this long after the
    /// last keystroke. Latency that only occurs when the user is idle is not
    /// latency the user can feel, and mixing the two hides which is which.
    private static let typingWindowNs: UInt64 = 500_000_000

    private struct State {
        var stages = [StageStats](repeating: StageStats(), count: Stage.allCases.count)
        /// Same stages, restricted to samples taken while the user was typing.
        var typingStages = [StageStats](repeating: StageStats(), count: Stage.allCases.count)
        /// Timestamp of the most recent keystroke, for the typing window.
        var lastKeyNs: UInt64 = 0
        /// Hitches that happened while typing, i.e. ones the user felt.
        var typingHitches16: UInt64 = 0
        var typingHitches33: UInt64 = 0
        var typingHitches100: UInt64 = 0
        /// Per-stage nanoseconds accumulated inside the CURRENT main-runloop turn.
        var turnAccum = [UInt64](repeating: 0, count: Stage.allCases.count)
        /// Breakdown of the single worst main-runloop turn seen so far.
        var worstTurnNs: UInt64 = 0
        var worstTurnAccum = [UInt64](repeating: 0, count: Stage.allCases.count)
        /// Running total of main-thread OUTPUT-pipeline time. Diffing this across
        /// a region says whether output processing ran inside that region.
        var outputPipelineNs: UInt64 = 0
        /// Main-runloop turns that blew the one-frame budget.
        var hitches16: UInt64 = 0
        var hitches33: UInt64 = 0
        var hitches100: UInt64 = 0
        /// Total main-thread busy time, for the occupancy figure.
        var mainBusyNs: UInt64 = 0
        var startNs: UInt64 = 0
        /// keyDown timestamps awaiting an echo, oldest first.
        var pendingKeys: [UInt64] = []
        /// The most recent key event's OS timestamp, not yet known to have
        /// produced any bytes. 0 = none armed.
        var armedKeyNs: UInt64 = 0
        /// When the OLDEST byte currently sitting in tmux's input coalesce
        /// buffer was enqueued. 0 = buffer empty.
        var inputEnqueuedNs: UInt64 = 0
        /// Terminal output bytes delivered to panes — how hard the OTHER panes
        /// are working while you type, which is the variable being tested.
        var outputBytes: UInt64 = 0
        /// Label for the current measurement window (set when resetting).
        var label: String = ""
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    @inline(__always)
    private static func bucketIndex(_ ns: UInt64) -> Int {
        guard ns > 0 else { return 0 }
        let octave = 63 - ns.leadingZeroBitCount
        guard octave >= 2 else { return octave }
        let sub = Int((ns >> UInt64(octave - 2)) & 0b11)
        return min(bucketCount - 1, octave * 4 + sub)
    }

    /// Lower edge, in nanoseconds, of a bucket.
    private static func bucketFloor(_ index: Int) -> UInt64 {
        guard index >= 8 else { return UInt64(index) }
        let octave = index / 4
        let sub = index % 4
        return (UInt64(4 + sub) << UInt64(octave - 2))
    }

    /// Representative value for a bucket: its MIDPOINT. Using the lower edge
    /// biases every quantile low by up to a bucket width (~19%).
    private static func bucketValue(_ index: Int) -> UInt64 {
        let lo = bucketFloor(index)
        let hi = index + 1 < bucketCount ? bucketFloor(index + 1) : lo
        return hi > lo ? lo + (hi - lo) / 2 : lo
    }

    // MARK: - Recording

    /// Nesting depth of main-thread spans. Only the OUTERMOST span is attributed
    /// to the runloop turn — `keyDown` contains `keyEncode`/`hostWrite`, `drain`
    /// contains `paneFeed`, and summing both levels would count the same
    /// nanoseconds twice and inflate the breakdown past the turn's real length.
    /// Main-thread only, so a plain var is safe.
    private nonisolated(unsafe) static var mainSpanDepth = 0

    /// Record one sample for `stage`. `topLevel` false = nested inside another
    /// main-thread span, so it must not be added to the turn attribution.
    @inline(__always)
    public static func mark(_ stage: Stage, ns: UInt64, topLevel: Bool = true) {
        guard enabled else { return }
        let onMainNow = stage.onMain && pthread_main_np() != 0
        let nowNs = now()
        state.withLockUnchecked { s in
            var st = s.stages[stage.rawValue]
            st.count &+= 1
            st.sumNs &+= ns
            if ns > st.maxNs { st.maxNs = ns }
            st.buckets[bucketIndex(ns)] &+= 1
            s.stages[stage.rawValue] = st

            // Second copy restricted to the typing window — the same numbers, but
            // only for moments the user could actually perceive.
            if s.lastKeyNs != 0 && nowNs &- s.lastKeyNs < typingWindowNs {
                var t = s.typingStages[stage.rawValue]
                t.count &+= 1
                t.sumNs &+= ns
                if ns > t.maxNs { t.maxNs = ns }
                t.buckets[bucketIndex(ns)] &+= 1
                s.typingStages[stage.rawValue] = t
            }
            // Attribute main-thread work to the runloop turn it happened in, so a
            // hitch can be broken down by what actually ran during it.
            if onMainNow && topLevel { s.turnAccum[stage.rawValue] &+= ns }
            // Output-pipeline total is depth-independent: we want it to count even
            // when the pipeline is re-entered from inside a keystroke.
            if stage.isOutputPipeline { s.outputPipelineNs &+= ns }
            if s.startNs == 0 { s.startNs = now() }
        }
    }

    /// Record `stage` as the elapsed time since `t0`.
    @inline(__always)
    public static func end(_ stage: Stage, since t0: UInt64, topLevel: Bool = true) {
        guard enabled else { return }
        mark(stage, ns: now() &- t0, topLevel: topLevel)
    }

    /// Terminal output bytes delivered to a pane. Drives the throughput figure,
    /// so a run can be read as "at N KB/s of output, typing cost M ms".
    @inline(__always)
    public static func noteOutputBytes(_ n: Int) {
        guard enabled, n > 0 else { return }
        state.withLockUnchecked { $0.outputBytes &+= UInt64(n) }
    }

    /// Main-thread output-pipeline nanoseconds so far. Diff across a region to
    /// find out whether output processing ran inside it (see `imeReentrant`).
    @inline(__always)
    public static func outputWorkSoFar() -> UInt64 {
        guard enabled else { return 0 }
        return state.withLockUnchecked { $0.outputPipelineNs }
    }

    /// Time `body` as `stage`.
    @inline(__always)
    public static func span<T>(_ stage: Stage, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let onMainNow = pthread_main_np() != 0
        let wasTopLevel = onMainNow && mainSpanDepth == 0
        if onMainNow { mainSpanDepth += 1 }
        defer { if onMainNow { mainSpanDepth -= 1 } }
        let t0 = now()
        if signpostsEnabled {
            let id = signposter.makeSignpostID()
            let interval = signposter.beginInterval("stage", id: id, "\(stage.label)")
            defer { signposter.endInterval("stage", interval) }
            let r = try body()
            end(stage, since: t0, topLevel: !onMainNow || wasTopLevel)
            return r
        }
        defer { end(stage, since: t0, topLevel: !onMainNow || wasTopLevel) }
        return try body()
    }

    /// Stamp for a queue hop: call at enqueue, pass the result to `hopEnd`.
    @inline(__always)
    public static func hopBegin() -> UInt64 { enabled ? now() : 0 }

    @inline(__always)
    public static func hopEnd(_ stage: Stage, _ t0: UInt64) {
        guard enabled, t0 != 0 else { return }
        mark(stage, ns: now() &- t0)
    }

    // MARK: - End-to-end echo

    /// A key event arrived — remember when the OS says the user actually pressed
    /// it (`NSEvent.timestamp`, same mach-uptime base as `now()`). Not a
    /// measurement yet: keys that produce no bytes (⌘C, a dead key mid-compose)
    /// must not be paired with someone else's output.
    public static func armKeystroke(atNs t: UInt64) {
        guard enabled else { return }
        let nowNs = now()
        state.withLockUnchecked { s in
            s.armedKeyNs = t
            // Opens the typing window regardless of whether this key produces
            // bytes — the user is at the keyboard either way.
            s.lastKeyNs = nowNs
        }
    }

    /// The engine produced bytes for the host — the armed key is real input, so
    /// start its end-to-end clock. Non-key writes (terminal replies, paste) find
    /// nothing armed and are correctly ignored.
    public static func commitKeystroke() {
        guard enabled else { return }
        state.withLockUnchecked { s in
            let t = s.armedKeyNs
            guard t != 0 else { return }
            s.armedKeyNs = 0
            // Bound the queue: fast typing / key-repeat can outrun echoes.
            if s.pendingKeys.count >= 16 { s.pendingKeys.removeFirst() }
            s.pendingKeys.append(t)
        }
    }

    /// Output reached the engine — close out the oldest keystroke still waiting.
    /// Only meaningful while typing; a firehose of unrelated output will pair
    /// keystrokes with whatever arrives next, so read `echoRTT` alongside the
    /// output-side stage counts.
    public static func noteEcho() {
        guard enabled else { return }
        let t = now()
        let t0: UInt64? = state.withLockUnchecked { s in
            guard !s.pendingKeys.isEmpty else { return nil }
            return s.pendingKeys.removeFirst()
        }
        guard let t0 else { return }
        let dt = t &- t0
        // Drop stale pairings (a key with no echo, matched to output seconds later).
        guard dt < 2_000_000_000 else { return }
        mark(.echoRTT, ns: dt)
    }

    // MARK: - tmux input coalesce window

    /// Bytes handed to tmux's input batcher. Only the FIRST enqueue of a burst
    /// is stamped, so `inputBatchWait` reports how long the oldest byte waited —
    /// which is what the user feels.
    public static func noteInputEnqueued() {
        guard enabled else { return }
        let t = now()
        state.withLockUnchecked { s in
            if s.inputEnqueuedNs == 0 { s.inputEnqueuedNs = t }
        }
    }

    /// The batcher flushed to the transport.
    public static func noteInputFlushed() {
        guard enabled else { return }
        let t = now()
        let t0: UInt64 = state.withLockUnchecked { s in
            let v = s.inputEnqueuedNs
            s.inputEnqueuedNs = 0
            return v
        }
        guard t0 != 0 else { return }
        mark(.inputBatchWait, ns: t &- t0)
    }

    // MARK: - Main-runloop hitch detection

    private nonisolated(unsafe) static var runLoopObserver: CFRunLoopObserver?
    private nonisolated(unsafe) static var turnStartNs: UInt64 = 0

    /// Install the main-runloop observer and start the periodic dump. Call once,
    /// from the main thread, at app start. No-op when profiling is off.
    public static func start() {
        guard enabled, runLoopObserver == nil else { return }
        state.withLockUnchecked { $0.startNs = now() }

        let activities = CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue
            | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities, true, /* order */ Int.min
        ) { _, activity in
            switch activity {
            case .afterWaiting:
                turnStartNs = now()
                state.withLockUnchecked { s in
                    for i in s.turnAccum.indices { s.turnAccum[i] = 0 }
                }
            case .beforeWaiting, .exit:
                guard turnStartNs != 0 else { return }
                let busy = now() &- turnStartNs
                turnStartNs = 0
                closeTurn(busyNs: busy)
            default:
                break
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        runLoopObserver = observer

        installSignalHandlers()
        startDumpTimer()
        dumpQueue.async { writeSummary(header: "profiler armed") }
    }

    // MARK: - Scenario control (signals)

    private nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []
    private nonisolated(unsafe) static var snapshotSeq = 0

    /// Comparing scenarios (idle panes vs busy panes, IME on vs off) needs a
    /// clean window per scenario. Restarting the app for each one loses the
    /// point, and quantiles can't be subtracted, so drive it with signals:
    ///
    ///   kill -USR1 <pid>   start a fresh window (counters zeroed)
    ///   kill -USR2 <pid>   save the current window to <out>.N.txt
    private static func installSignalHandlers() {
        for sig in [SIGUSR1, SIGUSR2] {
            // GCD's signal source only observes; the default disposition still
            // applies and would kill the process. Ignore it first.
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: dumpQueue)
            src.setEventHandler {
                if sig == SIGUSR1 {
                    reset()
                    writeSummary(header: "window reset")
                } else {
                    snapshotSeq += 1
                    let path = "\(outputPath).\(snapshotSeq).txt"
                    writeSummary(header: "snapshot \(snapshotSeq)", to: path)
                }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    private static func closeTurn(busyNs: UInt64) {
        state.withLockUnchecked { s in
            var st = s.stages[Stage.mainTurn.rawValue]
            st.count &+= 1
            st.sumNs &+= busyNs
            if busyNs > st.maxNs { st.maxNs = busyNs }
            st.buckets[bucketIndex(busyNs)] &+= 1
            s.stages[Stage.mainTurn.rawValue] = st

            s.mainBusyNs &+= busyNs
            if busyNs > 16_000_000 { s.hitches16 &+= 1 }
            if busyNs > 33_000_000 { s.hitches33 &+= 1 }
            if busyNs > 100_000_000 { s.hitches100 &+= 1 }
            // A hitch while typing is one the user felt; one while idle is not.
            let typing = s.lastKeyNs != 0 && now() &- s.lastKeyNs < typingWindowNs
            if typing {
                if busyNs > 16_000_000 { s.typingHitches16 &+= 1 }
                if busyNs > 33_000_000 { s.typingHitches33 &+= 1 }
                if busyNs > 100_000_000 { s.typingHitches100 &+= 1 }
            }
            if busyNs > s.worstTurnNs {
                s.worstTurnNs = busyNs
                s.worstTurnAccum = s.turnAccum
            }
        }
    }

    // MARK: - Reporting

    private static let dumpQueue =
        DispatchQueue(label: "com.novashang.bento.profiler", qos: .utility)
    private nonisolated(unsafe) static var dumpTimer: DispatchSourceTimer?

    private static var outputPath: String {
        ProcessInfo.processInfo.environment["BENTO_PROFILE_OUT"]
            ?? "/tmp/bento-input-profile.txt"
    }

    private static func startDumpTimer() {
        let interval = Double(ProcessInfo.processInfo.environment["BENTO_PROFILE_INTERVAL"] ?? "")
            ?? 2.0
        let timer = DispatchSource.makeTimerSource(queue: dumpQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { writeSummary(header: nil) }
        timer.resume()
        dumpTimer = timer
    }

    /// Clear all counters (so a measurement can start from a known point).
    public static func reset() {
        guard enabled else { return }
        state.withLockUnchecked { s in
            s = State()
            s.startNs = now()
        }
    }

    private struct Snapshot {
        var label: String
        var count: UInt64
        var p50: UInt64
        var p95: UInt64
        var p99: UInt64
        var max: UInt64
        var sum: UInt64
        var queueDelay: Bool
    }

    private static func quantile(_ st: StageStats, _ q: Double) -> UInt64 {
        guard st.count > 0 else { return 0 }
        let target = UInt64(Double(st.count) * q)
        var seen: UInt64 = 0
        for (i, c) in st.buckets.enumerated() where c > 0 {
            seen &+= UInt64(c)
            // A bucket's midpoint can sit above the largest sample it holds, so
            // clamp — a quantile printed above `max` reads as a bug.
            if seen >= target { return min(bucketValue(i), st.maxNs) }
        }
        return st.maxNs
    }

    private static func fmt(_ ns: UInt64) -> String {
        if ns == 0 { return "     -" }
        if ns < 1_000 { return String(format: "%4dns", ns) }
        if ns < 1_000_000 { return String(format: "%5.1fus", Double(ns) / 1_000) }
        return String(format: "%5.2fms", Double(ns) / 1_000_000)
    }

    private static func writeSummary(header: String?, to path: String? = nil) {
        guard enabled else { return }
        func snapshot(_ stages: [StageStats]) -> [Snapshot] {
            Stage.allCases.compactMap { stage -> Snapshot? in
                let st = stages[stage.rawValue]
                guard st.count > 0 else { return nil }
                return Snapshot(label: stage.label,
                                count: st.count,
                                p50: quantile(st, 0.50),
                                p95: quantile(st, 0.95),
                                p99: quantile(st, 0.99),
                                max: st.maxNs,
                                sum: st.sumNs,
                                queueDelay: stage.isQueueDelay)
            }
        }

        let (snaps, typingSnaps, worstNs, worstAccum,
             h16, h33, h100, th16, th33, th100, busyNs, elapsed, outBytes) =
            state.withLockUnchecked { s -> ([Snapshot], [Snapshot], UInt64, [UInt64],
                                            UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                                            UInt64, UInt64, UInt64) in
                let elapsed = s.startNs == 0 ? 0 : now() &- s.startNs
                return (snapshot(s.stages), snapshot(s.typingStages),
                        s.worstTurnNs, s.worstTurnAccum,
                        s.hitches16, s.hitches33, s.hitches100,
                        s.typingHitches16, s.typingHitches33, s.typingHitches100,
                        s.mainBusyNs, elapsed, s.outputBytes)
            }

        var out = ""
        out += "=== Bento input profile ===\n"
        if let header { out += "\(header)\n" }
        let secs = Double(elapsed) / 1e9
        out += String(format: "window: %.1fs   main-thread busy: %.1f%%\n",
                      secs,
                      elapsed == 0 ? 0 : Double(busyNs) / Double(elapsed) * 100)
        // How hard the OTHER panes were working during this window — the load
        // variable a scenario comparison is varying.
        out += String(format: "output load: %.1f KB/s  (%.2f MB total)\n",
                      secs > 0 ? Double(outBytes) / 1024 / secs : 0,
                      Double(outBytes) / 1024 / 1024)
        out += String(format: "hitches: >16ms %llu   >33ms %llu   >100ms %llu   worst turn %.1fms\n",
                      h16, h33, h100, Double(worstNs) / 1e6)
        out += String(format: "  of those, WHILE TYPING: >16ms %llu   >33ms %llu   >100ms %llu\n\n",
                      th16, th33, th100)

        let header = "stage             q  count      p50      p95      p99      max    total\n"
            + "--------------------------------------------------------------------------\n"

        func table(_ rows: [Snapshot]) -> String {
            var s = header
            for r in rows {
                s += String(format: "%-16s  %@  %5llu  %@  %@  %@  %@  %7.1fms\n",
                            (r.label as NSString).utf8String!,
                            r.queueDelay ? "Q" : " ",
                            r.count,
                            fmt(r.p50), fmt(r.p95), fmt(r.p99), fmt(r.max),
                            Double(r.sum) / 1e6)
            }
            return s
        }

        // Typing table first: latency outside the typing window is latency
        // nobody experiences, and burying the perceivable numbers under it was
        // how a 92ms tail looked alarming for two rounds without evidence that
        // it ever coincided with a keystroke.
        out += "--- WHILE TYPING (within 500ms of a keystroke) ---\n"
        out += typingSnaps.isEmpty ? "(no keystrokes in this window)\n" : table(typingSnaps)
        out += "\n--- OVERALL (typing + idle) ---\n"
        out += table(snaps)
        out += "\n(Q = queueing delay: time spent waiting to run, not working.)\n"

        // What was the main thread actually doing during its worst stall?
        // Always printed, even when nothing is attributed: a long stall that maps
        // to NO instrumented stage means the cost is outside the pipeline we
        // measure, and that is a finding rather than an absence of one.
        if worstNs > 0 {
            let breakdown = Stage.allCases
                .filter { worstAccum[$0.rawValue] > 0 }
                .sorted { worstAccum[$0.rawValue] > worstAccum[$1.rawValue] }
            out += String(format: "\nworst main-turn (%.1fms) breakdown:\n", Double(worstNs) / 1e6)
            var attributed: UInt64 = 0
            for stage in breakdown {
                let ns = worstAccum[stage.rawValue]
                attributed &+= ns
                out += String(format: "  %-16s %7.2fms\n",
                              (stage.label as NSString).utf8String!, Double(ns) / 1e6)
            }
            let unattributed = worstNs > attributed ? worstNs - attributed : 0
            out += String(format: "  %-16s %7.2fms  (AppKit / SwiftUI / unmeasured)\n",
                          ("other" as NSString).utf8String!, Double(unattributed) / 1e6)
        }

        try? out.write(toFile: path ?? outputPath, atomically: true, encoding: .utf8)
    }

    /// Force a summary write (e.g. on quit).
    public static func flush() {
        guard enabled else { return }
        dumpQueue.async { writeSummary(header: "manual flush") }
    }
}
