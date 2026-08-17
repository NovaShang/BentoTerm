import Foundation
import UniformTypeIdentifiers

/// Decides which files leave our renderer and go to the system's.
///
/// Text, code and Markdown deliberately stay ours: the web renderer gives
/// syntax highlighting, a line gutter, `path:42` jump-and-highlight, theme
/// following and scroll preservation across reloads — Quick Look's plain-text
/// preview has none of that. Quick Look takes everything else it knows how to
/// draw, which is most of what used to land on the info-only `.binary` case.
///
/// The decision is made from the extension alone, on purpose:
///   • it costs no bytes, so a 40MB PDF is never head-read first;
///   • `QLPreviewController.canPreview` wants a URL that exists, which is
///     exactly what we don't have yet for a remote file — asking it would mean
///     downloading first to find out whether downloading was worth it.
/// An extension we can't map at all falls through to the byte sniff, so
/// extensionless scripts and READMEs keep reaching the text renderer.
public enum QuickLookRouting {

    /// Types the system previews well that a conformance check alone would
    /// miss or actively misroute — RTF and iWork documents conform to
    /// `public.text`/`public.composite-content`, so without this list they'd
    /// be dumped into the code renderer as raw markup.
    private static let alwaysExtensions: Set<String> = [
        "pdf",
        "rtf", "rtfd",
        "doc", "docx", "dot", "dotx",
        "xls", "xlsx", "xlsm",
        "ppt", "pptx",
        "pages", "numbers", "key",
        "epub",
        "usdz", "usda", "usdc", "usd",
        "ics", "vcf",
    ]

    /// Extensions whose system type is a trap for the people using this app:
    /// `.ts`/`.mts` are registered as MPEG transport streams and `.dts` as an
    /// audio track, so a TypeScript file or a device tree would open in a
    /// video player instead of the code renderer. `.bin` claims MacBinary, an
    /// archive type Quick Look draws as a blank icon — the info-only card says
    /// more.
    private static let neverExtensions: Set<String> = [
        "ts", "mts", "cts", "dts", "dtsi", "bin",
    ]

    /// Families the system draws: pictures (all of them now — the app's own
    /// image view is gone), anything that plays, 3D scenes, fonts (Quick Look
    /// lays out a specimen sheet, every weight and the glyph table, where we
    /// had only the "binary" card), and archives (whose Quick Look at least
    /// names and sizes the contents instead of our flat "binary").
    private static let previewableFamilies: [UTType] = [
        .image, .movie, .audio, .audiovisualContent, .threeDContent, .font, .archive, .pdf,
    ]

    /// Never leaves our renderer, whatever the system thinks of the type.
    private static func isOurs(_ type: UTType) -> Bool {
        type.conforms(to: .plainText)
            || type.conforms(to: .sourceCode)
            || type.conforms(to: .script)
            || type.conforms(to: .shellScript)
            || type.conforms(to: .delimitedText)
            || type.conforms(to: .json)
            || type.conforms(to: .yaml)
            || type.conforms(to: .xml)
            || type.conforms(to: .html)
    }

    /// Consulted by the loader before any read. Pictures reach here too now —
    /// the app no longer decodes any image itself.
    public static func prefersQuickLook(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if neverExtensions.contains(ext) { return false }
        if alwaysExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        if isOurs(type) { return false }
        return previewableFamilies.contains { type.conforms(to: $0) }
    }
}
