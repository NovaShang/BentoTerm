import Foundation
import Testing
@testable import BentoTerm
import BentoSessionKit
import BentoFoundationKit

@Suite("HostStore Tests")
struct HostStoreTests {
    @Test func createHost() {
        let host = Host(
            name: "Test Server",
            hostname: "192.168.1.1",
            port: 22,
            username: "admin",
            authMethod: .password
        )
        #expect(host.displayName == "Test Server")
        #expect(host.port == 22)
    }

    @Test func hostDisplayNameFallback() {
        let host = Host(hostname: "10.0.0.1", username: "root")
        #expect(host.displayName == "root@10.0.0.1")
    }

    @Test func authMethodCoding() throws {
        let host = Host(
            hostname: "example.com",
            username: "user",
            authMethod: .privateKey(keyLabel: "id_rsa")
        )
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(BentoFoundationKit.Host.self, from: data)
        #expect(decoded.authMethod == .privateKey(keyLabel: "id_rsa"))
    }
}

/// The Keychain is not reachable from a unit-test process, so these drive the
/// rules through an in-memory stand-in keyed exactly like the real one
/// ("<type>:<account>"), which is what lets the private-key case be asserted.
@Suite("Host Credential Tests")
struct HostCredentialTests {

    private final class Box: @unchecked Sendable {
        var items: [String: String] = [:]
    }

    private func makeStore(_ box: Box) -> HostCredentialStore {
        HostCredentialStore(
            load: { account in box.items["password:\(account)"] },
            write: { secret, account in box.items["password:\(account)"] = secret },
            remove: { account in box.items["password:\(account)"] = nil }
        )
    }

    @Test func blankPasswordKeepsTheStoredOne() throws {
        let box = Box()
        let store = makeStore(box)
        let id = UUID()
        try store.savePassword("hunter2", for: id)

        try store.savePassword("", for: id)

        #expect(box.items["password:\(id.uuidString)"] == "hunter2")
    }

    @Test func typedPasswordReplacesTheStoredOne() throws {
        let box = Box()
        let store = makeStore(box)
        let id = UUID()
        try store.savePassword("hunter2", for: id)

        try store.savePassword("hunter3", for: id)

        #expect(box.items["password:\(id.uuidString)"] == "hunter3")
    }

    @Test func blankMacKeychainPasswordKeepsTheStoredOne() throws {
        let box = Box()
        let store = makeStore(box)
        let id = UUID()
        try store.saveMacKeychainPassword("login", for: id)

        try store.saveMacKeychainPassword("", for: id)

        #expect(box.items["password:macKeychain:\(id.uuidString)"] == "login")
    }

    @Test func storedPasswordIsReportedUnderTheKeySSHServiceReads() throws {
        let box = Box()
        let store = makeStore(box)
        let host = Host(hostname: "example.com", username: "root")
        #expect(store.hasPassword(for: host.id) == false)

        try store.savePassword("hunter2", for: host.id)

        #expect(store.hasPassword(for: host.id))
        // Same account string SSHService uses to load it back.
        #expect(box.items["password:\(host.id.uuidString)"] == "hunter2")
    }

    @Test func emptyStoredSecretCountsAsNotStored() {
        let box = Box()
        let store = makeStore(box)
        let id = UUID()
        box.items["password:\(id.uuidString)"] = ""

        #expect(store.hasPassword(for: id) == false)
    }

    @Test func clearingRemovesOnlyThatSecret() throws {
        let box = Box()
        let store = makeStore(box)
        let id = UUID()
        try store.savePassword("hunter2", for: id)
        try store.saveMacKeychainPassword("login", for: id)

        try store.clearPassword(for: id)

        #expect(store.hasPassword(for: id) == false)
        #expect(store.hasMacKeychainPassword(for: id))
    }

    @Test func forgettingAHostDropsItsPasswordsButNotSharedPrivateKeys() throws {
        let box = Box()
        let store = makeStore(box)
        let id = UUID()
        try store.savePassword("hunter2", for: id)
        try store.saveMacKeychainPassword("login", for: id)
        box.items["privatekey:id_ed25519"] = "KEYDATA"

        store.forgetAll(for: id)

        #expect(store.hasPassword(for: id) == false)
        #expect(store.hasMacKeychainPassword(for: id) == false)
        #expect(box.items["privatekey:id_ed25519"] == "KEYDATA")
    }
}

@Suite("Host Edit Form Tests")
struct HostEditFormTests {

    @Test func savingIsAllowedWhenThePasswordIsAlreadyStored() {
        #expect(HostEditView.isFormValid(
            hostname: "example.com", username: "root", authType: 0,
            password: "", hasStoredPassword: true, importedKeyLabel: nil))
    }

    @Test func savingIsBlockedWhenNoPasswordIsStoredOrTyped() {
        #expect(HostEditView.isFormValid(
            hostname: "example.com", username: "root", authType: 0,
            password: "", hasStoredPassword: false, importedKeyLabel: nil) == false)
    }

    @Test func aTypedPasswordIsEnoughForANewHost() {
        #expect(HostEditView.isFormValid(
            hostname: "example.com", username: "root", authType: 0,
            password: "hunter2", hasStoredPassword: false, importedKeyLabel: nil))
    }

    @Test func keyAuthStillNeedsAKeyRegardlessOfStoredPasswords() {
        #expect(HostEditView.isFormValid(
            hostname: "example.com", username: "root", authType: 1,
            password: "", hasStoredPassword: true, importedKeyLabel: nil) == false)
        #expect(HostEditView.isFormValid(
            hostname: "example.com", username: "root", authType: 1,
            password: "", hasStoredPassword: false, importedKeyLabel: "id_ed25519"))
    }

    @Test func hostnameAndUsernameAreStillRequired() {
        #expect(HostEditView.isFormValid(
            hostname: "", username: "root", authType: 0,
            password: "hunter2", hasStoredPassword: true, importedKeyLabel: nil) == false)
        #expect(HostEditView.isFormValid(
            hostname: "example.com", username: "", authType: 0,
            password: "hunter2", hasStoredPassword: true, importedKeyLabel: nil) == false)
    }
}
