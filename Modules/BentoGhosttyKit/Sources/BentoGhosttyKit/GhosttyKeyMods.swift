#if canImport(AppKit) || canImport(UIKit)
import GhosttyKit

/// Modifier bookkeeping both surfaces hand libghostty with every key.
public enum GhosttyKeyMods {
    /// Which held modifiers the engine should treat as already "consumed" to
    /// produce this key's text — the layout's translation mods (Shift/CapsLock/
    /// Option-as-Alt), minus Ctrl/Super. Critical for shifted symbols whose glyph
    /// is NOT a case-fold of the base key (":" "?" "!" "@" …): with consumed mods
    /// hardcoded to NONE the engine saw an unconsumed Shift over a symbol it
    /// couldn't reconcile and dropped the key — Shift+; never emitted ":" from an
    /// external iPad keyboard.
    public static func consumed(_ mods: ghostty_input_mods_e,
                                surface: ghostty_surface_t) -> ghostty_input_mods_e {
        let translated = ghostty_surface_key_translation_mods(surface, mods)
        var raw = translated.rawValue
        raw &= ~GHOSTTY_MODS_CTRL.rawValue
        raw &= ~GHOSTTY_MODS_SUPER.rawValue
        return ghostty_input_mods_e(rawValue: raw)
    }
}
#endif
