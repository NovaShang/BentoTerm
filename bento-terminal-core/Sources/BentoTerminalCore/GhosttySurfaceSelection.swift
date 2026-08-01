#if canImport(AppKit) || canImport(UIKit)
import CoreGraphics
import GhosttyKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Engine-level text-selection helpers shared by the iOS and macOS ghostty
/// surfaces. These are pure libghostty calls operating on a `ghostty_surface_t`
/// plus a point already converted to surface pixels — the platform views own
/// the view-point→pixel conversion (scale / orientation) and forward here, so
/// the selection logic lives in exactly one place.
@MainActor
enum GhosttySel {
    /// Select the word under `px` (emulates a double-click). Returns whether a
    /// selection now exists.
    @discardableResult
    static func selectWord(_ surface: ghostty_surface_t, px: (x: Double, y: Double)) -> Bool {
        ghostty_surface_mouse_pos(surface, px.x, px.y, GHOSTTY_MODS_NONE)
        for _ in 0..<2 {
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        }
        ghostty_surface_refresh(surface)
        return ghostty_surface_has_selection(surface)
    }

    /// Begin a left-button press at `px`. ghostty either starts a selection or
    /// forwards it to the app (when the TUI enabled mouse reporting); `mods`
    /// carries the held keyboard modifiers so modified / shift-to-select clicks
    /// work. Returns whether ghostty consumed it for the app's mouse reporting.
    @discardableResult
    static func begin(_ surface: ghostty_surface_t, px: (x: Double, y: Double),
                      mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE) -> Bool {
        ghostty_surface_mouse_pos(surface, px.x, px.y, mods)
        return ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    /// Extend the in-progress drag (selection, or motion reported to the app).
    static func extend(_ surface: ghostty_surface_t, px: (x: Double, y: Double),
                       mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE) {
        ghostty_surface_mouse_pos(surface, px.x, px.y, mods)
        ghostty_surface_refresh(surface)
    }

    /// Finish the left-button press.
    static func end(_ surface: ghostty_surface_t, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE) {
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        ghostty_surface_refresh(surface)
    }

    static func hasSelection(_ surface: ghostty_surface_t) -> Bool {
        ghostty_surface_has_selection(surface)
    }

    /// Top-left of the current selection, in the surface's own pixel space
    /// (`ghostty_text_s.tl_px`). Used to position the selection start handle.
    /// nil if there's no selection. The caller converts to view points.
    static func selectionTopLeftPx(_ surface: ghostty_surface_t) -> (x: Double, y: Double)? {
        guard ghostty_surface_has_selection(surface) else { return nil }
        var t = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &t) else { return nil }
        let r = (t.tl_px_x, t.tl_px_y)
        ghostty_surface_free_text(surface, &t)
        return r
    }

    /// Read the text of a whole region (SCREEN = scrollback+screen, VIEWPORT =
    /// visible) via `ghostty_surface_read_text`, mirroring `selectedText`. Returns
    /// the text plus the region's top-left pixel anchor and its char offset/len in
    /// the engine's text space. nil if the read failed.
    static func readRegion(_ surface: ghostty_surface_t,
                           tag: ghostty_point_tag_e)
        -> (text: String, tlPxY: Double, offsetStart: UInt32, offsetLen: UInt32)?
    {
        var sel = ghostty_selection_s()
        sel.top_left = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        sel.bottom_right = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        sel.rectangle = false
        var t = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &t) else { return nil }
        defer { ghostty_surface_free_text(surface, &t) }
        let text: String
        if let ptr = t.text {
            text = String(bytes: UnsafeRawBufferPointer(start: ptr, count: Int(t.text_len)),
                          encoding: .utf8) ?? ""
        } else {
            text = ""
        }
        return (text, t.tl_px_y, t.offset_start, t.offset_len)
    }

    /// The currently selected text, or nil.
    static func selectedText(_ surface: ghostty_surface_t) -> String? {
        var t = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &t), let ptr = t.text else { return nil }
        let s = String(bytes: UnsafeRawBufferPointer(start: ptr, count: Int(t.text_len)), encoding: .utf8)
        ghostty_surface_free_text(surface, &t)
        return s
    }

    /// Select the entire screen/scrollback via ghostty's keybind action.
    @discardableResult
    static func selectAll(_ surface: ghostty_surface_t) -> Bool {
        let ok = bindingAction("select_all", on: surface)
        ghostty_surface_refresh(surface)
        return ok
    }

    /// Run a named ghostty keybind action (e.g. "select_all",
    /// "paste_from_clipboard", "scroll_to_bottom") on the surface. Returns
    /// whether the engine performed it.
    @discardableResult
    static func bindingAction(_ name: String, on surface: ghostty_surface_t) -> Bool {
        name.withCString {
            ghostty_surface_binding_action(surface, $0, UInt(name.utf8.count))
        }
    }

    // MARK: - Scrollback search
    //
    // Driven entirely through named keybind actions, which is the only route the
    // prebuilt libghostty exposes (there is no `ghostty_surface_search`). The
    // engine owns everything that matters: it walks the scrollback, highlights
    // the matches in the renderer, tracks which one is current, and reports the
    // counts back as SEARCH_TOTAL / SEARCH_SELECTED apprt actions.

    /// Start (or re-run) a search for `needle`. `search` takes the rest of the
    /// action string verbatim, so a needle containing ':' needs no escaping.
    @discardableResult
    static func search(_ surface: ghostty_surface_t, needle: String) -> Bool {
        guard !needle.isEmpty else { return endSearch(surface) }
        let ok = bindingAction("search:\(needle)", on: surface)
        ghostty_surface_refresh(surface)
        return ok
    }

    /// Move to the next / previous match. No-op in the engine if no search is active.
    @discardableResult
    static func navigateSearch(_ surface: ghostty_surface_t, forward: Bool) -> Bool {
        let ok = bindingAction("navigate_search:\(forward ? "next" : "previous")", on: surface)
        ghostty_surface_refresh(surface)
        return ok
    }

    /// End the search and drop the highlights.
    @discardableResult
    static func endSearch(_ surface: ghostty_surface_t) -> Bool {
        let ok = bindingAction("end_search", on: surface)
        ghostty_surface_refresh(surface)
        return ok
    }

    /// Set the engine's preedit overlay (IME composition / predicted echo) to
    /// `text`; nil or empty clears it. Shared by the iOS and macOS surfaces'
    /// setMarkedText / setPredictedText / commit-clear paths.
    static func setPreedit(_ surface: ghostty_surface_t, _ text: String?) {
        guard let text, !text.isEmpty else {
            ghostty_surface_preedit(surface, nil, 0)
            return
        }
        let utf8 = Array(text.utf8)
        utf8.withUnsafeBufferPointer { buf in
            buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { p in
                ghostty_surface_preedit(surface, p, UInt(buf.count))
            }
        }
    }

    /// Clear any selection (a plain left click collapses it).
    static func clear(_ surface: ghostty_surface_t, px: (x: Double, y: Double)?) {
        if let px { ghostty_surface_mouse_pos(surface, px.x, px.y, GHOSTTY_MODS_NONE) }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_NONE)
        ghostty_surface_refresh(surface)
    }

    /// Feed literal text to the surface (paste).
    static func insertText(_ surface: ghostty_surface_t, _ text: String) {
        guard !text.isEmpty else { return }
        let utf8 = Array(text.utf8)
        utf8.withUnsafeBufferPointer { buf in
            buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { p in
                ghostty_surface_text(surface, p, UInt(buf.count))
            }
        }
    }
}

/// System pasteboard bridge (one source of truth for both platforms).
@MainActor
enum TerminalClipboard {
    static func write(_ s: String) {
        guard !s.isEmpty else { return }
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = s
        #endif
    }

    static func read() -> String? {
        #if canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #elseif canImport(UIKit)
        return UIPasteboard.general.string
        #endif
    }
}
#endif
