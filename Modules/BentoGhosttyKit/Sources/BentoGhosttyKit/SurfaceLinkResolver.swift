import Foundation
import os

/// The order both surfaces answer "is there a link here?" in.
///
/// The ENGINE first: an OSC 8 hyperlink's target lives in the cell attributes,
/// never on screen — Claude Code emits `ESC]8;;URL ESC\ anchor ESC]8;; ESC\` and
/// its anchor is often prose in another language — so no scrape can recover it;
/// only ghostty, which parsed the sequence, has it. How the engine is asked
/// differs per platform (the Mac remembers the last hover, anchored to a cell;
/// a touch has no hover, so iOS provokes one at the tapped cell), which is why
/// the caller hands the answer in rather than this asking.
///
/// Then a scrape of the logical line under the point, from the same screen
/// snapshot path detection reads — one picture of the screen for both, so a URL
/// can't be invisible to one detector and fuzzy-matched as a path by the other.
public enum SurfaceLinkResolver {
    public static func url(engine: String?,
                           logicalLine: () -> (line: String, cell: Int)?) -> String? {
        if let engine {
            linkLog.log("link via engine (OSC 8) ⟨\(engine, privacy: .public)⟩")
            return engine
        }
        guard let (line, cell) = logicalLine() else { return nil }
        return TerminalLinkDetector.urlHit(inLine: line, atCell: cell)
    }
}
