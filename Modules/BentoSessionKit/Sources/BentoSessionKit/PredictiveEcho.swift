import Foundation

/// Mosh-style predictive local echo for the raw (no-tmux) SSH/pty path.
///
/// On a high-latency link a keystroke takes a full round-trip to appear, so
/// typing feels like wading through mud. This engine draws the predicted
/// character *immediately* as an underlined libghostty preedit overlay, then
/// retires the prediction when the server's echo confirms it.
///
/// The safety property that makes this sound: **predictions never touch
/// libghostty's authoritative grid.** They live only in the preedit overlay
/// (the same channel IME composition uses), which clears cleanly and is
/// repainted over by the real bytes. So a wrong guess is self-healing — the
/// worst case is a briefly-visible underlined character that the true echo
/// corrects a frame later. The on-screen *result* is always whatever the
/// server actually sent; only the transient overlay can be wrong.
///
/// v1 is deliberately conservative. It predicts only printable ASCII and
/// backspace on what looks like a shell command line, and **gives up the moment
/// the server sends anything that isn't the exact echo it expected** — a color
/// code, a prompt redraw, a cursor move, a mismatched byte. Giving up just
/// clears the overlay; the authoritative bytes render normally. It also stands
/// down in the alternate screen (vim/less/htop), where there's no line editor
/// to predict for. Everything harder — a full predicted terminal emulator to
/// survive syntax-highlighting shells, cursor-key prediction — is left for
/// later; this floor is safe everywhere and helps most on the common case
/// (ssh to a plain remote prompt).
///
/// Lives in the shared layer and is driven from `TerminalViewModel`'s raw
/// send/receive choke points, so iOS and macOS share one implementation.
@MainActor
final class PredictiveEcho {
    /// Push predicted text to the surface as a preedit overlay; "" clears it.
    /// Set by the host wiring to the active surface's `setPredictedText`.
    var render: ((String) -> Void)?

    /// Master switch (feature flag). While false the engine is fully inert —
    /// no state kept, no overlay drawn.
    var enabled: Bool

    /// Predicted bytes typed but not yet confirmed by the server's echo, oldest
    /// first. Always printable ASCII (0x20–0x7e) by construction.
    private var pending: [UInt8] = []
    /// Send timestamp per pending byte (parallel to `pending`) — for measuring
    /// echo latency when each is confirmed.
    private var sentAt: [TimeInterval] = []

    /// True while the remote program owns the whole screen (alt buffer). No
    /// shell line editor there, so we don't predict. Belt-and-suspenders: even
    /// if this misclassifies, the give-up rule keeps the overlay honest.
    private var inAltScreen = false

    /// Rolling estimate of echo latency (seconds): time from predicting a byte
    /// to its confirmation. Predictions only *display* once this proves the link
    /// is slow enough to be worth it — on a fast link the echo beats the next
    /// frame, so showing an overlay would only add flicker.
    private var latencyEWMA: TimeInterval = 0
    private var hasMeasured = false

    /// Below this measured latency, predictions are computed but not shown.
    private static let displayThreshold: TimeInterval = 0.035   // 35 ms

    private static let printableRange: ClosedRange<UInt8> = 0x20...0x7e
    private static let del: UInt8 = 0x7f

    init(enabled: Bool) {
        self.enabled = enabled
    }

    /// A keystroke is about to be written to the transport. Update the
    /// prediction and (maybe) the overlay. Never alters what's sent — the caller
    /// still writes `data` verbatim.
    func willSend(_ data: Data) {
        guard enabled, !inAltScreen else { return }

        // Only single-byte printable ASCII and backspace are predictable. Enter,
        // control chars, escape sequences, and multi-byte (IME-committed) input
        // all invalidate the simple line model — give up and let the echo drive.
        if data.count == 1, let b = data.first {
            if Self.printableRange.contains(b) {
                pending.append(b)
                sentAt.append(Date.timeIntervalSinceReferenceDate)
                updateOverlay()
                return
            }
            if b == Self.del, !pending.isEmpty {
                // Predict deleting our own not-yet-confirmed char. (We can't
                // predict deleting an already-echoed char — the overlay only
                // adds — so with nothing pending we give up instead.)
                pending.removeLast()
                sentAt.removeLast()
                updateOverlay()
                return
            }
        }
        flush()
    }

    /// A chunk of server output is about to be fed to the surface. Reconcile it
    /// against the prediction: confirm the bytes it echoes, give up on the first
    /// surprise. Does not consume `data` — the caller still feeds it in full.
    func didReceive(_ data: Data) {
        guard enabled else { return }
        trackAltScreen(data)
        if inAltScreen { flush(); return }
        guard !pending.isEmpty else { return }

        for b in data {
            guard let expected = pending.first else { break }  // all confirmed
            if b == expected {
                pending.removeFirst()
                let sent = sentAt.removeFirst()
                recordLatency(Date.timeIntervalSinceReferenceDate - sent)
            } else {
                // Reality diverged from the guess — abandon the whole prediction.
                // The real bytes (this one included) render authoritatively. But a
                // non-matching reply is STILL a round-trip signal: the server
                // answered ~one RTT after we sent, so sample the latency before
                // giving up. Without this, a shell that never echoes cleanly
                // (syntax highlighting redraws the line in color) would never
                // measure the link and would optimistically flicker a prediction
                // on every keystroke — even on a fast connection.
                if let sent = sentAt.first {
                    recordLatency(Date.timeIntervalSinceReferenceDate - sent)
                }
                flush()
                return
            }
        }
        updateOverlay()
    }

    /// Drop all predictions and clear the overlay. Called on give-up, on any
    /// non-predictable keystroke, and when the surface is torn down.
    func flush() {
        guard !pending.isEmpty || renderedNonEmpty else { return }
        pending.removeAll()
        sentAt.removeAll()
        renderedNonEmpty = false
        render?("")
    }

    // MARK: - Private

    private var renderedNonEmpty = false

    private func updateOverlay() {
        let show = shouldDisplay && !pending.isEmpty
        let text = show ? String(decoding: pending, as: UTF8.self) : ""
        // Avoid a redundant clear->clear when we're already blank.
        guard show || renderedNonEmpty else { return }
        renderedNonEmpty = show
        render?(text)
    }

    /// Show predictions once the link proves slow; be optimistic before the
    /// first measurement so typing feels instant from the first keystroke (on a
    /// fast link that first overlay clears within a frame — imperceptible).
    private var shouldDisplay: Bool {
        hasMeasured ? latencyEWMA >= Self.displayThreshold : true
    }

    private func recordLatency(_ rawSample: TimeInterval) {
        // Clamp: a char that sat pending for seconds (sent, never echoed, then
        // unrelated output arrives) must not inject a bogus multi-second RTT.
        // Clamping (rather than dropping) keeps `hasMeasured` progressing so the
        // gate still engages on a genuinely slow link.
        let sample = min(max(rawSample, 0), 2.0)
        latencyEWMA = hasMeasured ? (0.2 * sample + 0.8 * latencyEWMA) : sample
        hasMeasured = true
    }

    // MARK: Alternate-screen tracking

    /// Where the CSI scanner is between bytes — carried across chunks so a
    /// sequence split by a read boundary is still recognized.
    ///   ground → esc (saw ESC) → bracket (saw `[`) → priv (saw `?`, DEC private)
    ///   or other (non-private CSI we skip to its final byte).
    private enum CSIState { case ground, esc, bracket, priv, other }
    private var csi: CSIState = .ground
    private var csiParam = 0            // current numeric parameter, accumulating
    private var csiHitAltMode = false  // any param so far ∈ {47,1047,1049}

    private static func isAltMode(_ n: Int) -> Bool { n == 1049 || n == 1047 || n == 47 }

    /// Track alternate-screen enter/leave so we stand down inside TUIs
    /// (vim/less/htop), where there's no shell line editor to predict for.
    ///
    /// A single O(n), allocation-free pass: a tiny state machine that recognizes
    /// `ESC [ ? …47|1047|1049… h|l` and flips `inAltScreen`. Runs on every server
    /// output chunk on the main thread, so it must stay cheap — hence the fast
    /// path that bails when nothing is mid-sequence and the chunk has no ESC
    /// (plain-text floods), and `withUnsafeBytes` to avoid Data's per-element
    /// bridging. Correctness here is only an optimization anyway: the byte-match
    /// give-up rule is the real safety net, so a missed transition can at worst
    /// cost one flickered prediction, never a corrupt screen.
    private func trackAltScreen(_ data: Data) {
        if csi == .ground, data.firstIndex(of: 0x1b) == nil { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for b in raw { step(b) }
        }
    }

    private func step(_ b: UInt8) {
        switch csi {
        case .ground:
            if b == 0x1b { csi = .esc }
        case .esc:
            if b == 0x5b { csi = .bracket }          // '['
            else if b == 0x1b { csi = .esc }         // ESC ESC → resync
            else { csi = .ground }
        case .bracket:
            if b == 0x3f {                            // '?' → DEC private
                csi = .priv; csiParam = 0; csiHitAltMode = false
            } else if (0x40...0x7e).contains(b) {     // final byte, no params
                csi = .ground
            } else {
                csi = .other                          // non-private CSI, skip it
            }
        case .priv:
            switch b {
            case 0x30...0x39:                         // digit
                if csiParam < 1_000_000 { csiParam = csiParam * 10 + Int(b - 0x30) }
            case 0x3b:                                // ';' — next parameter
                if Self.isAltMode(csiParam) { csiHitAltMode = true }
                csiParam = 0
            case 0x68:                                // 'h' — set mode
                if csiHitAltMode || Self.isAltMode(csiParam) { inAltScreen = true }
                csi = .ground
            case 0x6c:                                // 'l' — reset mode
                if csiHitAltMode || Self.isAltMode(csiParam) { inAltScreen = false }
                csi = .ground
            case 0x40...0x7e:                         // some other final byte
                csi = .ground
            default:                                  // intermediates — ignore
                break
            }
        case .other:
            if (0x40...0x7e).contains(b) { csi = .ground }
        }
    }
}
