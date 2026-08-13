import Foundation
import CoreText

/// Every monospaced font family installed on this machine.
///
/// The font picker used to offer four hardcoded names. It shouldn't: a
/// developer who cares enough to open a font picker has already installed the
/// one they want, and the count is whatever their font book says it is.
///
/// **Values are real family names now, not tokens.** `terminal_font_family`
/// used to hold `"maple-nf-cn"` / `"sf-mono"` and `ThemeStore.ghosttyFontFamily`
/// translated them. That switch keeps its cases (so an existing install keeps
/// rendering while it still holds a token) and its `default` branch already
/// passes anything else straight through — which is exactly what a family name
/// needs. So the migration is `normalized(_:)` below, called once when the
/// picker appears, and no migration code at all.
public enum MonospacedFonts {
    /// Shipped inside the app on both platforms, and the default. CJK-friendly,
    /// which is why it beats the system monospace as a default.
    public static let bundledDefault = "Maple Mono NF CN"

    /// Sorted for a picker: the default first, everything else alphabetical.
    /// Hidden system families (leading ".") are dropped — they are not
    /// selectable by name.
    public static func families() -> [String] {
        var found = Set<String>()
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection)
            as? [CTFontDescriptor] ?? []
        for descriptor in descriptors {
            guard isMonospaced(descriptor),
                  let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  !family.hasPrefix(".")
            else { continue }
            found.insert(family)
        }
        // The bundled font is registered with CoreText by the app, so it turns
        // up in the enumeration on its own — but it is also the default, and a
        // picker whose default is missing is worse than a duplicate.
        found.insert(bundledDefault)
        var sorted = found.subtracting([bundledDefault])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        sorted.insert(bundledDefault, at: 0)
        return sorted
    }

    /// Map whatever is stored today onto a family name that exists on THIS
    /// machine. Legacy tokens translate; an unknown value (a font that was
    /// uninstalled, a token we no longer know) falls back to the default rather
    /// than leaving the picker showing nothing.
    public static func normalized(_ stored: String?, available: [String]) -> String {
        let candidate: String
        switch stored {
        case "menlo":       candidate = "Menlo"
        case "courier":     candidate = "Courier New"
        case "jetbrains":   candidate = "JetBrains Mono"
        case "maple-nf-cn": candidate = bundledDefault
        case "sf-mono", "system", "system-medium", "", nil: candidate = "SF Mono"
        case let other?:    candidate = other
        }
        if available.contains(candidate) { return candidate }
        return available.first ?? bundledDefault
    }

    private static func isMonospaced(_ descriptor: CTFontDescriptor) -> Bool {
        guard let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute)
                as? [CFString: Any],
              let symbolic = traits[kCTFontSymbolicTrait] as? UInt32
        else { return false }
        return CTFontSymbolicTraits(rawValue: symbolic).contains(.monoSpaceTrait)
    }
}
