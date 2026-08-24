import XCTest
@testable import BentoFoundationKit

/// The rules that used to live in two places and now live in one.
///
/// The allowlist is the security boundary: terminal output is attacker-shaped
/// in the ordinary case (you `cat` a log someone else wrote), and an OSC 8
/// hyperlink's target never appears on screen — so a crafted `file://` link is
/// invisible until it opens. Everything else here is routing preference, which
/// is exactly why the two must not be able to override each other.
final class LinkRouterTests: XCTestCase {

    // MARK: The allowlist

    func testOpensWebAndMailSchemes() {
        XCTAssertTrue(LinkRouter.canOpen("https://example.com"))
        XCTAssertTrue(LinkRouter.canOpen("http://example.com"))
        XCTAssertTrue(LinkRouter.canOpen("mailto:a@b.com"))
        XCTAssertTrue(LinkRouter.canOpen("ftp://example.com/f"))
        XCTAssertTrue(LinkRouter.canOpen("ftps://example.com/f"))
    }

    func testSchemeMatchIsCaseInsensitive() {
        XCTAssertTrue(LinkRouter.canOpen("HTTPS://example.com"))
        XCTAssertTrue(LinkRouter.canOpen("MailTo:a@b.com"))
    }

    func testRefusesEverythingElse() {
        XCTAssertFalse(LinkRouter.canOpen("file:///etc/passwd"))
        XCTAssertFalse(LinkRouter.canOpen("bento://open"))
        XCTAssertFalse(LinkRouter.canOpen("javascript:alert(1)"))
        XCTAssertFalse(LinkRouter.canOpen("example.com"))   // no scheme
        XCTAssertFalse(LinkRouter.canOpen(""))
    }

    /// `canOpen` and `destination` read the same list. If they ever drift, a
    /// link the chip refuses to offer could still be opened by a direct call.
    func testCanOpenAgreesWithDestination() {
        for s in ["https://a.com", "mailto:a@b.com", "file:///x", "bento://x", "", "a.com"] {
            let refused = LinkRouter.destination(for: s, preference: .inApp) == .refused
            XCTAssertEqual(LinkRouter.canOpen(s), !refused, "disagreed on \(s)")
        }
    }

    // MARK: Routing

    func testWebLinksFollowThePreference() {
        XCTAssertEqual(LinkRouter.destination(for: "https://a.com", preference: .inApp), .inApp)
        XCTAssertEqual(LinkRouter.destination(for: "http://a.com", preference: .inApp), .inApp)
        XCTAssertEqual(LinkRouter.destination(for: "https://a.com", preference: .system), .system)
    }

    /// An embedded browser has nothing to show for a mail or FTP link, so those
    /// belong to whatever the OS registered no matter what the setting says.
    func testNonWebSchemesAlwaysGoToTheSystem() {
        for pref in LinkOpenPreference.allCases {
            XCTAssertEqual(LinkRouter.destination(for: "mailto:a@b.com", preference: pref), .system)
            XCTAssertEqual(LinkRouter.destination(for: "ftp://a.com/f", preference: pref), .system)
        }
    }

    func testForceSystemOverridesTheInAppPreference() {
        XCTAssertEqual(
            LinkRouter.destination(for: "https://a.com", preference: .inApp, forceSystem: true),
            .system)
    }

    /// The escape hatch can push a link OUT to the system browser; it must
    /// never pull a refused scheme IN. ⌘⇧-click on a crafted `file://` link
    /// still opens nothing.
    func testForceSystemCannotOpenARefusedScheme() {
        XCTAssertEqual(
            LinkRouter.destination(for: "file:///etc/passwd", preference: .inApp, forceSystem: true),
            .refused)
        XCTAssertEqual(
            LinkRouter.destination(for: "bento://open", preference: .system, forceSystem: true),
            .refused)
    }

    // MARK: Host identity

    /// Two panes on the same box share one forward. Identity is the remote id
    /// alone — the label is what a human reads and may legitimately differ
    /// (one pane knows a nicer name for the machine than the other).
    func testHostsWithTheSameRemoteIDAreEqualRegardlessOfLabel() {
        let a = LinkHost(remoteID: "build-box", label: "build-box")
        let b = LinkHost(remoteID: "build-box", label: "nova@build-box")
        XCTAssertEqual(a.remoteID, b.remoteID)
        XCTAssertNotEqual(a, b, "label is part of the value; forwards key on remoteID")
        XCTAssertFalse(a.isLocal)
    }

    func testLocalHostHasNoRemoteID() {
        let here = LinkHost.local(label: "This Mac")
        XCTAssertTrue(here.isLocal)
        XCTAssertNil(here.remoteID)
    }
}

/// Choosing the local side of a forward.
///
/// The same-number rule is not cosmetic: a page's own absolute links carry the
/// REMOTE port (`http://localhost:5173/api`), and they only keep working when
/// the local number matches. Renumbering is a fallback the user gets told about.
final class LocalPortProbeTests: XCTestCase {

    func testPrefersTheSameNumberWhenItIsFree() {
        guard let free = LocalPortProbe.ephemeral(), LocalPortProbe.isFree(free) else {
            return
        }
        XCTAssertEqual(LocalPortProbe.choose(matching: free, taken: []), free)
    }

    /// A port this process already promised to another forward is not free,
    /// even though nothing has bound it yet.
    func testSkipsPortsAlreadyClaimedInThisProcess() {
        guard let free = LocalPortProbe.ephemeral() else {
            return
        }
        let chosen = LocalPortProbe.choose(matching: free, taken: [free])
        XCTAssertNotNil(chosen)
        XCTAssertNotEqual(chosen, free)
    }

    /// A port with a live listener on it is taken. This is the whole reason
    /// renumbering exists, so it has to actually be detected.
    func testAPortWithAListenerIsNotFree() throws {
        let listener = try TinyListener()
        defer { listener.stop() }
        XCTAssertFalse(LocalPortProbe.isFree(listener.port))
        let chosen = LocalPortProbe.choose(matching: listener.port, taken: [])
        XCTAssertNotNil(chosen)
        XCTAssertNotEqual(chosen, listener.port, "must have renumbered off the busy port")
    }

    func testPrivilegedAndOutOfRangePortsAreRefused() {
        XCTAssertFalse(LocalPortProbe.isPlausible(80))
        XCTAssertFalse(LocalPortProbe.isPlausible(0))
        XCTAssertFalse(LocalPortProbe.isPlausible(70000))
        XCTAssertTrue(LocalPortProbe.isPlausible(5173))
    }

    // MARK: PortForward bookkeeping

    func testRenumberedIsWhatTheUserGetsWarnedAbout() {
        let host = LinkHost(remoteID: "box", label: "box")
        XCTAssertFalse(PortForward(host: host, remotePort: 5173, localPort: 5173).isRenumbered)
        XCTAssertTrue(PortForward(host: host, remotePort: 5173, localPort: 51234).isRenumbered)
    }

    /// Two panes on the same box asking for the same port are the same forward.
    func testForwardIdentityIsHostPlusRemotePort() {
        let box = LinkHost(remoteID: "box", label: "box")
        let other = LinkHost(remoteID: "other", label: "other")
        XCTAssertEqual(PortForward(host: box, remotePort: 3000, localPort: 3000).id,
                       PortForward(host: box, remotePort: 3000, localPort: 9999).id)
        XCTAssertNotEqual(PortForward(host: box, remotePort: 3000, localPort: 3000).id,
                          PortForward(host: other, remotePort: 3000, localPort: 3000).id)
    }

    /// The browser loads the local port but everything else about the URL —
    /// path, query, scheme — is the page the user asked for.
    func testLocalURLKeepsThePathAndOnlyMovesThePort() throws {
        let f = PortForward(host: LinkHost(remoteID: "box", label: "box"),
                            remotePort: 5173, localPort: 51234)
        let original = try XCTUnwrap(URL(string: "http://localhost:5173/app?x=1#top"))
        let local = f.localURL(replacing: original)
        XCTAssertEqual(local.port, 51234)
        XCTAssertEqual(local.host, "127.0.0.1")
        XCTAssertEqual(local.path, "/app")
        XCTAssertEqual(local.query, "x=1")
        XCTAssertEqual(local.fragment, "top")
    }
}

/// A socket that is actually listening, so "is this port free" is tested
/// against the real answer rather than against a mock.
private final class TinyListener {
    let port: Int
    private let fd: Int32

    init() throws {
        // Everything runs on a LOCAL fd until the end: touching `self.fd`
        // inside these closures would be using self before `port` is set.
        let f = socket(AF_INET, SOCK_STREAM, 0)
        guard f >= 0 else { throw NSError(domain: "TinyListener", code: 1) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(f, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(f, 1) == 0 else {
            close(f); throw NSError(domain: "TinyListener", code: 2)
        }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(f, $0, &len) }
        }
        self.port = Int(UInt16(bigEndian: out.sin_port))
        self.fd = f
    }

    func stop() { close(fd) }
}

/// The exact `ssh` argument vectors the macOS forwarder runs.
///
/// Verified against the real binary while writing this: all three shapes below
/// parse through to "Control socket connect(…)" — i.e. everything except the
/// live master is correct — whereas a malformed `-L` fails earlier and
/// differently ("Bad local forwarding specification"). So this test is pinning
/// down a shape that was checked, not one that was guessed.
final class SSHForwardCommandTests: XCTestCase {

    /// Loopback is spelled out rather than left to `GatewayPorts`: a forward
    /// puts someone else's service on this machine and must not land on the
    /// network this machine is joined to.
    func testTheSpecBindsLoopbackExplicitly() {
        XCTAssertEqual(SSHForwardCommand.spec(localPort: 51234, remotePort: 5173),
                       "127.0.0.1:51234:localhost:5173")
    }

    func testForwardArgv() {
        XCTAssertEqual(
            SSHForwardCommand.forward(localPort: 5173, remotePort: 5173,
                                      alias: "build-box", controlPath: "/tmp/s-ab12"),
            ["-o", "ControlPath=/tmp/s-ab12",
             "-O", "forward", "-L", "127.0.0.1:5173:localhost:5173", "build-box"])
    }

    func testCancelArgv() {
        XCTAssertEqual(
            SSHForwardCommand.cancel(localPort: 51234, remotePort: 3000,
                                     alias: "box", controlPath: "/tmp/s-cd34"),
            ["-o", "ControlPath=/tmp/s-cd34",
             "-O", "cancel", "-L", "127.0.0.1:51234:localhost:3000", "box"])
    }

    func testCheckArgv() {
        XCTAssertEqual(SSHForwardCommand.check(alias: "box", controlPath: "/tmp/s-ef56"),
                       ["-o", "ControlPath=/tmp/s-ef56", "-O", "check", "box"])
    }

    /// When the user's own ssh_config names a ControlPath we pass none, so ssh
    /// resolves it the same way it does for every other command they run.
    /// Overriding would silently opt them out of their own multiplexing.
    func testNoControlPathOptionWhenTheUserConfiguresTheirOwn() {
        let argv = SSHForwardCommand.forward(localPort: 8080, remotePort: 8080,
                                             alias: "box", controlPath: nil)
        XCTAssertEqual(argv, ["-O", "forward", "-L", "127.0.0.1:8080:localhost:8080", "box"])
        XCTAssertFalse(argv.contains { $0.hasPrefix("ControlPath") })
    }
}
