import Foundation
import Security
import XCTest
@testable import BentoFoundationKit

/// The SecItem calls themselves need a real keychain; what is pinned here is
/// the address every call is built from — get one key wrong and a saved
/// password reads back as "not saved".
final class GenericPasswordStoreTests: XCTestCase {
    func testQueryAddressesServiceAndAccount() {
        let store = GenericPasswordStore(service: "com.bento.term.mac.ssh",
                                         accessibility: .afterFirstUnlockThisDeviceOnly)
        let q = store.query("sshPassword:box")
        XCTAssertEqual(q[kSecAttrService as String] as? String, "com.bento.term.mac.ssh")
        XCTAssertEqual(q[kSecAttrAccount as String] as? String, "sshPassword:box")
        XCTAssertEqual(q[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(q.count, 3)
    }

    func testAccessibilityMapsToTheSecConstants() {
        XCTAssertEqual(GenericPasswordStore.Accessibility.afterFirstUnlockThisDeviceOnly.secValue as String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(GenericPasswordStore.Accessibility.whenUnlockedThisDeviceOnly.secValue as String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }
}
