import Foundation

/// Removes the screen/tmux window-title sequence `ESC k <text> ST` (and the BEL
/// variant) from a terminal byte stream.
///
/// Inside tmux, `$TERM` is screen/tmux-like, so title-setting shells (e.g.
/// oh-my-zsh's `title` hook) emit the screen form `ESC k <title> ESC \` instead
/// of an xterm OSC. libghostty doesn't recognize `ESC k`, so it renders the
/// title text (typically the running command's name) as **literal text** — the
/// "command name repeated before its output" artifact, seen only on the tmux
/// `-CC` path (outside tmux the shell uses OSC titles, which ghostty handles).
///
/// We drop the whole sequence. It carries no visible content (it only sets a
/// title), and tmux separately reports window renames via `%window-renamed`.
///
/// Stateful: a sequence can be split across feed chunks, so the parser state
/// persists between `strip(_:)` calls. Every other escape (CSI `ESC [`, OSC
/// `ESC ]`, etc.) passes through untouched — only `ESC k` is diverted.
public final class ScreenTitleStripper {
    public init() {}

    private enum State { case normal, esc, title, titleEsc }
    private var state: State = .normal

    private static let ESC: UInt8 = 0x1B
    private static let BEL: UInt8 = 0x07
    private static let k: UInt8 = 0x6B      // 'k'
    private static let backslash: UInt8 = 0x5C  // '\' → ST when after ESC

    public func strip(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var out = Data()
        out.reserveCapacity(data.count)
        for b in data {
            switch state {
            case .normal:
                if b == Self.ESC { state = .esc }   // hold ESC pending its kind
                else { out.append(b) }

            case .esc:
                if b == Self.k {
                    state = .title                  // ESC k → start title (drop both)
                } else {
                    out.append(Self.ESC)            // not ESC k → emit the held ESC…
                    if b == Self.ESC {
                        state = .esc                // …and hold this new ESC
                    } else {
                        out.append(b)               // …followed by this byte
                        state = .normal
                    }
                }

            case .title:
                if b == Self.BEL { state = .normal }       // BEL terminates
                else if b == Self.ESC { state = .titleEsc } // maybe ST
                // otherwise: title text, drop it

            case .titleEsc:
                if b == Self.backslash { state = .normal } // ESC \ = ST, terminates
                else if b == Self.ESC { state = .titleEsc } // another ESC, keep waiting
                else { state = .title }                     // spurious ESC, keep dropping
            }
        }
        return out
    }
}
