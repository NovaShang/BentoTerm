import Foundation

/// Stateless parsers for tmux's textual output. Use these on the response
/// body returned by `TmuxControlMode.send(_:)` (for `list-panes` /
/// `list-windows` / `list-sessions`), or on the raw bytes captured from a
/// shell where tmux ran directly.
public enum TmuxParsers {
    /// Parse the output of `list-panes` with the format
    /// `#{pane_id}:…:#{window_id}:#{pane_in_mode}:#{@bento_state}:#{pane_title}`.
    /// The zoom flag is per-window (every pane in a zoomed window reports 1).
    /// Every fixed field precedes `pane_title` (last) so the title may contain
    /// colons; `window_active`/`window_id` make session-wide listings (`-s`)
    /// attributable to windows without separate window state.
    public static func parsePaneList(_ output: String) -> [Pane] {
        output.split(separator: "\n").compactMap { line in
            // maxSplits 15 → 16 fields; the title (last) may itself contain
            // colons, so every fixed field is placed before it.
            let parts = line.split(separator: ":", maxSplits: 15,
                                   omittingEmptySubsequences: false)
            guard parts.count >= 6,
                  let paneID = TmuxPaneID(string: String(parts[0])),
                  let width = Int(parts[1]),
                  let height = Int(parts[2]),
                  let x = Int(parts[3]),
                  let y = Int(parts[4]) else {
                return nil
            }
            let isActive = parts[5] == "1"
            let isZoomed = parts.count > 6 && parts[6] == "1"
            let command = parts.count > 7 ? nonEmpty(parts[7]) : nil
            let mouseAny = parts.count > 8 && parts[8] == "1"
            let mouseSGR = parts.count > 9 && parts[9] == "1"
            let alternateOn = parts.count > 10 && parts[10] == "1"
            let inActiveWindow = parts.count > 11 ? parts[11] == "1" : true
            let windowID = parts.count > 12 ? TmuxWindowID(string: String(parts[12])) : nil
            let inMode = parts.count > 13 && parts[13] == "1"
            let statusOption = parts.count > 14 ? nonEmpty(parts[14]) : nil
            let title = parts.count > 15 ? nonEmpty(parts[15]) : nil

            return Pane(
                id: paneID,
                width: width,
                height: height,
                x: x,
                y: y,
                isActive: isActive,
                isZoomed: isZoomed,
                currentCommand: command,
                title: title,
                mouseAny: mouseAny,
                mouseSGR: mouseSGR,
                alternateOn: alternateOn,
                windowID: windowID,
                inActiveWindow: inActiveWindow,
                inMode: inMode,
                statusOption: statusOption
            )
        }
    }

    /// An unset pane option expands to nothing; that is "no value", not "".
    private static func nonEmpty(_ field: Substring) -> String? {
        field.isEmpty ? nil : String(field)
    }

    /// Geometry of one pane extracted from a tmux window-layout string.
    public struct PaneGeometry: Equatable, Sendable {
        public let id: TmuxPaneID
        public let width: Int
        public let height: Int
        public let x: Int
        public let y: Int
    }

    /// Matches leaf-pane geometry; hoisted because parsePaneGeometry runs on
    /// every %layout-change and NSRegularExpression compilation isn't free.
    private static let paneGeometryRegex = try? NSRegularExpression(
        pattern: #"(\d+)x(\d+),(\d+),(\d+),(\d+)"#)

    /// Parse a tmux window-layout string (as carried by `%layout-change` or
    /// `list-windows`' `#{window_layout}`) into each leaf pane's geometry.
    ///
    /// The format is a recursive description:
    ///   `<checksum>,<WxH>,<X>,<Y>{<child>,<child>,…}`  (horizontal split)
    ///   `<WxH>,<X>,<Y>[<child>,<child>,…]`             (vertical split)
    ///   `<WxH>,<X>,<Y>,<paneId>`                       (leaf pane)
    /// e.g. `5504,181x45,0,0{56x45,0,0,38,124x45,57,0[71x30,…,39,52x30,…,70]}`.
    /// Only leaves carry a trailing `,<paneId>` (split nodes are followed by
    /// `{`/`[`), so matching `WxH,X,Y,id` extracts exactly the leaf panes.
    public static func parsePaneGeometry(_ layout: String) -> [PaneGeometry] {
        guard let re = Self.paneGeometryRegex else { return [] }
        let ns = layout as NSString
        let matches = re.matches(in: layout, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { m in
            guard let w = Int(ns.substring(with: m.range(at: 1))),
                  let h = Int(ns.substring(with: m.range(at: 2))),
                  let x = Int(ns.substring(with: m.range(at: 3))),
                  let y = Int(ns.substring(with: m.range(at: 4))),
                  let id = Int(ns.substring(with: m.range(at: 5))) else { return nil }
            return PaneGeometry(id: TmuxPaneID(id), width: w, height: h, x: x, y: y)
        }
    }

    /// Parse the output of `list-windows` with the format
    /// `#{window_id}:#{window_index}:#{window_active}:#{window_layout}:#{window_name}`.
    /// `window_name` is free text (a title may contain colons), so it is the
    /// LAST field — every fixed field precedes it, mirroring `parsePaneList`'s
    /// `pane_title`. A colon in the name no longer corrupts `window_layout`
    /// (which Bento persists for the Tiled⇄List layout restore).
    public static func parseWindowList(_ output: String) -> [TmuxWindow] {
        output.split(separator: "\n").compactMap { line in
            // maxSplits 4 → 5 fields; the name (last) may itself contain colons.
            let parts = line.split(separator: ":", maxSplits: 4)
            guard parts.count >= 1,
                  let winID = TmuxWindowID(string: String(parts[0])) else {
                return nil
            }
            let index = parts.count > 1 ? Int(parts[1]) : nil
            let isActive = parts.count > 2 && parts[2] == "1"
            let layout = parts.count > 3 ? String(parts[3]) : nil
            let name = parts.count > 4 ? String(parts[4]) : ""

            return TmuxWindow(
                id: winID,
                index: index,
                name: name,
                panes: [],
                layout: layout,
                isActive: isActive
            )
        }
    }
}
