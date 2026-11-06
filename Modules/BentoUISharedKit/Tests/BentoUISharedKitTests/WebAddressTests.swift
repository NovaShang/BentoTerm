import Testing
import Foundation
@testable import BentoUISharedKit

/// The parser behind the browser's address bar. The cases below are what a
/// person actually types.
@Suite("Typing an address")
struct WebAddressTests {

    @Test func bareDomainsGetHTTPS() {
        #expect(WebAddress.candidate(for: "github.com")?.absoluteString == "https://github.com")
        #expect(WebAddress.candidate(for: "bentoai.dev")?.absoluteString == "https://bentoai.dev")
        #expect(WebAddress.candidate(for: "news.ycombinator.com")?.absoluteString
                == "https://news.ycombinator.com")
    }

    @Test func domainWithAPath() {
        #expect(WebAddress.candidate(for: "github.com/NovaShang/BentoTerm")?.absoluteString
                == "https://github.com/NovaShang/BentoTerm")
    }

    /// The shape a terminal prints, and the reason this hatch exists. Plain
    /// http, because a dev server is not on https.
    @Test func loopbackWithAPortGetsHTTP() {
        #expect(WebAddress.candidate(for: "localhost:3000")?.absoluteString
                == "http://localhost:3000")
        #expect(WebAddress.candidate(for: "127.0.0.1:8080")?.absoluteString
                == "http://127.0.0.1:8080")
    }

    @Test func fullURLsPassThroughUntouched() {
        #expect(WebAddress.candidate(for: "http://localhost:5173")?.absoluteString
                == "http://localhost:5173")
        #expect(WebAddress.candidate(for: "https://github.com/x?a=1")?.absoluteString
                == "https://github.com/x?a=1")
    }

    /// A file that exists must never be shadowed by a guess that it was a
    /// domain — hence the short fixed TLD list. `main.rs` is a file.
    @Test func filenamesAreNotDomains() {
        for s in ["main.rs", "README.md", "Package.swift", "config.yaml", "index.html"] {
            #expect(WebAddress.candidate(for: s) == nil, "\(s) was taken for a domain")
        }
    }

    @Test func prosePathsAndEmptyInputAreNotAddresses() {
        for s in ["", "   ", "npm run dev", "src/lib", "/etc/hosts", "~/code"] {
            #expect(WebAddress.candidate(for: s) == nil, "\(s) was taken for an address")
        }
    }

    /// Anything with a space is a sentence or a command, never an address.
    @Test func spacesDisqualify() {
        #expect(WebAddress.candidate(for: "github.com and more") == nil)
    }
}
