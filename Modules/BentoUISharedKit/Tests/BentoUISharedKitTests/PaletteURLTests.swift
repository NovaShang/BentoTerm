import Testing
import Foundation
@testable import BentoUISharedKit

/// The parser behind BOTH ways of typing an address: the palette row and the
/// browser's address bar. One parser on purpose — `localhost:3000` has to mean
/// the same thing in both places, or the two doors lead somewhere different.
///
/// These tests exist because the feature shipped without them and the gap it
/// hid was not in the parsing (that was fine) but in there being nowhere to
/// type. The cases below are what a person actually types.
@Suite("Typing an address")
struct PaletteURLTests {

    @Test func bareDomainsGetHTTPS() {
        #expect(PaletteURL.candidate(for: "github.com")?.absoluteString == "https://github.com")
        #expect(PaletteURL.candidate(for: "bentoai.dev")?.absoluteString == "https://bentoai.dev")
        #expect(PaletteURL.candidate(for: "news.ycombinator.com")?.absoluteString
                == "https://news.ycombinator.com")
    }

    @Test func domainWithAPath() {
        #expect(PaletteURL.candidate(for: "github.com/NovaShang/BentoTerm")?.absoluteString
                == "https://github.com/NovaShang/BentoTerm")
    }

    /// The shape a terminal prints, and the reason this hatch exists. Plain
    /// http, because a dev server is not on https.
    @Test func loopbackWithAPortGetsHTTP() {
        #expect(PaletteURL.candidate(for: "localhost:3000")?.absoluteString
                == "http://localhost:3000")
        #expect(PaletteURL.candidate(for: "127.0.0.1:8080")?.absoluteString
                == "http://127.0.0.1:8080")
    }

    @Test func fullURLsPassThroughUntouched() {
        #expect(PaletteURL.candidate(for: "http://localhost:5173")?.absoluteString
                == "http://localhost:5173")
        #expect(PaletteURL.candidate(for: "https://github.com/x?a=1")?.absoluteString
                == "https://github.com/x?a=1")
    }

    /// A file that exists must never be shadowed by a guess that it was a
    /// domain — hence the short fixed TLD list. `main.rs` is a file.
    @Test func filenamesAreNotDomains() {
        for s in ["main.rs", "README.md", "Package.swift", "config.yaml", "index.html"] {
            #expect(PaletteURL.candidate(for: s) == nil, "\(s) was taken for a domain")
        }
    }

    @Test func prosePathsAndEmptyInputAreNotAddresses() {
        for s in ["", "   ", "npm run dev", "src/lib", "/etc/hosts", "~/code"] {
            #expect(PaletteURL.candidate(for: s) == nil, "\(s) was taken for an address")
        }
    }

    /// Anything with a space is a sentence or a command, never an address.
    @Test func spacesDisqualify() {
        #expect(PaletteURL.candidate(for: "github.com and more") == nil)
    }
}
