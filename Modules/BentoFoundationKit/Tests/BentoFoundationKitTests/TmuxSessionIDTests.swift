import XCTest
@testable import BentoFoundationKit

/// The identity rules that keep a session on this Mac and a session on an ssh
/// host from being mistaken for each other.
final class TmuxSessionIDTests: XCTestCase {

    // MARK: - Keys

    /// A local session's key is its bare name, unchanged. Every key already
    /// written to `mac_last_terminal_sessions` by an older build is a bare
    /// name, so this is what makes them keep restoring after the upgrade.
    func testLocalKeyIsTheBareName() {
        XCTAssertEqual(TmuxSessionID.local("bento").key, "bento")
        XCTAssertEqual(TmuxSessionID(key: "bento"), .local("bento"))
        XCTAssertEqual(TmuxSessionID(key: "session-2")?.server, .local)
    }

    func testRemoteKeyCarriesTheHost() {
        let id = TmuxSessionID.ssh(host: "gpu-box", name: "bento")
        XCTAssertEqual(id.key, "ssh://gpu-box/bento")
        XCTAssertEqual(TmuxSessionID(key: id.key), id)
    }

    func testKeysRoundTrip() {
        for id: TmuxSessionID in [
            .local("bento"),
            .local("a-b_c.1"),
            .ssh(host: "gpu-box", name: "bento"),
            .ssh(host: "user@1.2.3.4", name: "work"),
            // A session name may contain slashes; only the FIRST one after the
            // scheme separates host from name, so these must survive.
            .ssh(host: "gpu-box", name: "a/b/c"),
        ] {
            XCTAssertEqual(TmuxSessionID(key: id.key), id, "round trip failed for \(id.key)")
        }
    }

    /// Landmine 3, stated as a test: same name, different machine, different
    /// identity. If these ever compare equal, the open-windows map, the reopen
    /// list and the tab strip all start showing one and acting on the other.
    func testSameNameOnDifferentServersIsADifferentSession() {
        let local = TmuxSessionID.local("foo")
        let remote = TmuxSessionID.ssh(host: "gpu-box", name: "foo")
        XCTAssertNotEqual(local, remote)
        XCTAssertNotEqual(local.key, remote.key)
        XCTAssertEqual(Set([local, remote]).count, 2)
    }

    func testMalformedRemoteKeysAreRejectedRatherThanGuessedAt() {
        XCTAssertNil(TmuxSessionID(key: ""))
        XCTAssertNil(TmuxSessionID(key: "ssh://gpu-box"))     // no name
        XCTAssertNil(TmuxSessionID(key: "ssh:///bento"))      // no host
        XCTAssertNil(TmuxSessionID(key: "ssh://gpu-box/"))    // empty name
    }

    // MARK: - Display

    /// The Sessions menu and the tab bar must not show a remote session as if
    /// it were a local one.
    func testRemoteSessionsAreLabelledWithTheirHost() {
        XCTAssertEqual(TmuxSessionID.local("bento").displayName, "bento")
        XCTAssertEqual(
            TmuxSessionID.ssh(host: "gpu-box", name: "bento").displayName,
            "bento — gpu-box")
    }

    // MARK: - The local-only barrier

    /// Landmine 2, stated as a test. `LocalTmuxSessionName` is the only thing
    /// `TmuxCLI` accepts, and this initializer is the only way to make one from
    /// a session that a window is attached to. It returning nil for a remote
    /// session is what makes "Kill Session" in a remote window incapable of
    /// killing the local session that shares its name — a compile-time
    /// guarantee, not a guard someone can delete by accident.
    ///
    /// If this test fails, the local-only operations are reachable from a
    /// remote window and can destroy the user's local session.
    func testARemoteSessionCannotBecomeALocalTmuxSessionName() {
        XCTAssertNil(LocalTmuxSessionName(.ssh(host: "gpu-box", name: "foo")))
        XCTAssertNil(LocalTmuxSessionName(.ssh(host: "gpu-box", name: "bento")))
    }

    func testALocalSessionCanBecomeALocalTmuxSessionName() {
        let name = LocalTmuxSessionName(.local("bento"))
        XCTAssertEqual(name?.rawValue, "bento")
        XCTAssertEqual(name?.id, .local("bento"))
    }

    /// Names read back out of the local server are local by construction, and
    /// round-trip to a local identity.
    func testNamesFromTheLocalServerAreLocal() {
        let name = LocalTmuxSessionName(onLocalServer: "bento")
        XCTAssertTrue(name.id.isLocal)
        XCTAssertEqual(name.id.key, "bento")
    }
}
