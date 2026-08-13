import Foundation
import Testing
import BentoFilePreviewKit

/// The routing rule is the whole of issue #3's scope decision, and it is easy
/// to widen by accident (one extra UTType family and Markdown loses its
/// renderer), so it is pinned here.
struct QuickLookRoutingTests {

    @Test("Text, code and Markdown keep the web renderer")
    func staysOurs() {
        for name in ["NOTES.md", "main.swift", "config.json", "docker-compose.yaml",
                     "index.html", "data.csv", "build.log", "notes.txt", "run.sh",
                     "app.py", "schema.xml"] {
            #expect(QuickLookRouting.prefersQuickLook(fileName: name) == false, "\(name)")
        }
    }

    @Test("Extensionless and unknown files stay on the byte sniff")
    func unknownStaysOurs() {
        for name in ["README", "Makefile", "Dockerfile", "notes.qqqzz"] {
            #expect(QuickLookRouting.prefersQuickLook(fileName: name) == false, "\(name)")
        }
    }

    @Test("System formats route to Quick Look")
    func goesToQuickLook() {
        for name in ["report.pdf", "notes.rtf", "spec.docx", "plan.pages", "deck.key",
                     "budget.numbers", "demo.mp4", "voice.m4a", "book.epub",
                     "model.usdz", "shot.cr2", "layers.psd", "bundle.zip",
                     "Inter.ttf", "Inter.otf", "Helvetica.ttc"] {
            #expect(QuickLookRouting.prefersQuickLook(fileName: name) == true, "\(name)")
        }
    }

    @Test("Source files whose system type is a media type stay ours")
    func mediaTypeTrapsStayOurs() {
        // `.ts` is registered as an MPEG transport stream and `.dts` as an
        // audio track — a TypeScript file opening in a video player is the
        // failure this guards.
        for name in ["client.ts", "types.d.ts", "board.dts", "firmware.bin"] {
            #expect(QuickLookRouting.prefersQuickLook(fileName: name) == false, "\(name)")
        }
    }
}
