import Foundation
import Testing
@testable import Bento
import BentoTerminalCore

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
        let decoded = try JSONDecoder().decode(Host.self, from: data)
        #expect(decoded.authMethod == .privateKey(keyLabel: "id_rsa"))
    }
}
