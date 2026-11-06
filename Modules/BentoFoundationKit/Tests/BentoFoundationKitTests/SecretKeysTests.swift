import XCTest
@testable import BentoFoundationKit

/// The account strings are where existing secrets already live — these pin
/// them byte for byte so a refactor can't orphan a stored password.
final class SecretKeysTests: XCTestCase {

    func testAccountStringsAreStable() {
        XCTAssertEqual(SecretKeys.sshPassword(host: "bento-review"), "sshPassword:bento-review")
        XCTAssertEqual(SecretKeys.sshPassphrase(keyPath: "/Users/me/.ssh/id_ed25519"),
                       "sshPassphrase:/Users/me/.ssh/id_ed25519")
        let id = UUID(uuidString: "6F1C2B3A-0000-4000-8000-000000000001")!
        XCTAssertEqual(SecretKeys.macKeychain(hostID: id),
                       "macKeychain:6F1C2B3A-0000-4000-8000-000000000001")
    }
}
