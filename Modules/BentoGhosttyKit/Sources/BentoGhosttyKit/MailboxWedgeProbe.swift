#if os(iOS)
import Foundation
import Darwin
import os
import BentoFoundationKit

/// Diagnostic instrumentation for the iOS foreground freeze (issue #1).
///
/// The hypothesis it exists to CONFIRM OR KILL: `ghostty_surface_process_output`
/// blocks pushing into libghostty's global App mailbox — 64 messages, pushed
/// with an infinite timeout — and the only thing that drains that mailbox is
/// `ghostty_app_tick`, which on iOS also runs on the main thread. Main pushes,
/// main blocks, and the only drainer is the thread that is blocked.
///
/// That predicts what nothing else does: the ghostty io/renderer threads are all
/// IDLE at freeze time (they never touch this queue), and rate-limiting by BYTES
/// changes nothing, because what runs out is a count of MESSAGES — one per BEL,
/// one per OSC. A shell prompt emits OSC 2 + OSC 7, so ~32 replayed prompts fill
/// it.
///
/// Two numbers decide it, and both have to be captured BEFORE the thread parks:
///   - how many mailbox pushes have happened since the last drain
///     (`wakeupsSinceTick` — `wakeup_cb` fires once per push, successful or not)
///   - how many message-producing sequences are in the chunk that got stuck
///
/// Read the resulting log line like this:
///   - `wakeups >= 60` AND `bel+osc >= 60`  → hypothesis confirmed, stop looking.
///   - both small                            → hypothesis dead; the blocked queue
///     is a different one (a per-surface renderer mailbox), look there next.
///   - `msSinceTick` large but `wakeups` small → something is suppressing ticks
///     independently of the mailbox.
///
/// This is a DIAGNOSTIC build's worth of code, not permanent instrumentation: it
/// costs one extra pass over each chunk on the output path. Delete it once the
/// answer is in.
public enum MailboxWedgeProbe {

    /// Off unless the app opts in, so a normal build pays nothing but a branch.
    public nonisolated(unsafe) static var enabled = false

    // MARK: - Mailbox pressure (written on main, read by the watchdog)

    private static let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        /// Pushes into the App mailbox since it was last drained. One per
        /// `wakeup_cb`, which libghostty invokes on EVERY push — including the
        /// one that fails and then parks. A direct proxy for slots consumed.
        var wakeupsSinceTick = 0
        var lastTickUptimeNs: UInt64 = 0
        /// Set for the duration of one `ghostty_surface_process_output` call.
        var pushInFlight = false
        var pushStartNs: UInt64 = 0
        var pushBytes = 0
        /// Message-producing sequences in the in-flight chunk — the number that
        /// converts "how many bytes" into "how many mailbox messages".
        var pushBel = 0
        var pushOsc = 0
        var pushSurface = 0
        /// So a persisting wedge is reported repeatedly rather than once.
        var lastReportNs: UInt64 = 0
    }

    /// Called from `wakeup_cb`. Can arrive on any thread.
    public static func noteWakeup() {
        guard enabled else { return }
        state.withLock { $0.wakeupsSinceTick += 1 }
    }

    /// Called immediately after `ghostty_app_tick` returns — the mailbox is now
    /// drained, so the pressure count starts over.
    public static func noteTick() {
        guard enabled else { return }
        let drained = state.withLock { s -> Int in
            let n = s.wakeupsSinceTick
            s.wakeupsSinceTick = 0
            s.lastTickUptimeNs = DispatchTime.now().uptimeNanoseconds
            return n
        }
        // 40 of 64 slots in one tick means the queue is running close to full in
        // normal use — worth seeing even on a run that never wedges.
        if drained >= 40 { dlog("[mbox] \(drained) pushes drained in one tick") }
    }

    // MARK: - The in-flight push beacon

    /// Bracket one `ghostty_surface_process_output` call.
    ///
    /// The census is computed HERE, before the call, because once the thread is
    /// parked inside libghostty nothing on it can run — the watchdog has to find
    /// the answer already written down.
    public static func beginPush(_ data: Data, surfaceTag: Int) {
        guard enabled else { return }
        let (bel, osc) = census(data)
        state.withLock { s in
            s.pushInFlight = true
            s.pushStartNs = DispatchTime.now().uptimeNanoseconds
            s.pushBytes = data.count
            s.pushBel = bel
            s.pushOsc = osc
            s.pushSurface = surfaceTag
            s.lastReportNs = 0
        }
    }

    public static func endPush() {
        guard enabled else { return }
        state.withLock { $0.pushInFlight = false }
    }

    /// BEL (`0x07`) and OSC introducers (`ESC ]`) — the two families on a raw
    /// output stream that make `processOutputLocked` push a mailbox message.
    /// One unsafe pass with memchr, so a 256KB chunk costs microseconds.
    private static func census(_ data: Data) -> (bel: Int, osc: Int) {
        data.withUnsafeBytes { raw -> (Int, Int) in
            guard let base = raw.baseAddress else { return (0, 0) }
            let count = raw.count
            var bel = 0, osc = 0, i = 0
            while i < count, let hit = memchr(base + i, 0x07, count - i) {
                bel += 1
                i = (UnsafeRawPointer(hit) - base) + 1
            }
            i = 0
            while i < count - 1, let hit = memchr(base + i, 0x1b, count - i - 1) {
                let at = UnsafeRawPointer(hit) - base
                if base.load(fromByteOffset: at + 1, as: UInt8.self) == 0x5d { osc += 1 }
                i = at + 1
            }
            return (bel, osc)
        }
    }

    // MARK: - Watchdog

    private nonisolated(unsafe) static var timer: DispatchSourceTimer?

    /// A timer on a BACKGROUND queue, which is the whole point: when the main
    /// thread is parked in the futex, it is the only thing left that can write
    /// anything down. `DebugLogger` writes through an unbuffered file handle
    /// under a lock, so the line survives the watchdog kill that follows.
    public static func start() {
        guard enabled, timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { sample() }
        timer = t
        t.resume()
        dlog("[mbox] wedge probe armed")
    }

    private static func sample() {
        let now = DispatchTime.now().uptimeNanoseconds
        let line: String? = state.withLock { s -> String? in
            guard s.pushInFlight else { return nil }
            let stuckMs = (now &- s.pushStartNs) / 1_000_000
            guard stuckMs > 2_000 else { return nil }
            // Once when it goes over, then every 3s while it persists.
            guard s.lastReportNs == 0 || (now &- s.lastReportNs) > 3_000_000_000 else { return nil }
            s.lastReportNs = now
            let sinceTickMs = s.lastTickUptimeNs == 0 ? -1
                : Int((now &- s.lastTickUptimeNs) / 1_000_000)
            return "[WEDGE] stuck in process_output \(stuckMs)ms "
                + "bytes=\(s.pushBytes) bel=\(s.pushBel) osc=\(s.pushOsc) "
                + "messages≈\(s.pushBel + s.pushOsc) surf=\(s.pushSurface) "
                + "wakeupsSinceTick=\(s.wakeupsSinceTick) msSinceTick=\(sinceTickMs)"
        }
        if let line { dlog(line) }
    }
}
#endif
