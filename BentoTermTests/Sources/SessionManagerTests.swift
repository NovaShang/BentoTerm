import Testing
@testable import Bento
import BentoTerminalCore
import Foundation

@Suite("SessionManager Tests")
@MainActor
struct SessionManagerTests {
    private func makeHost(_ name: String) -> Host {
        Host(
            id: UUID(),
            name: name,
            hostname: "\(name).example.com",
            port: 22,
            username: "test",
            authMethod: .password
        )
    }

    @Test func viewModelIdentityIsStableAcrossLookups() async throws {
        let manager = SessionManager(maxSessions: 5)
        let host = makeHost("alpha")

        let vm1 = manager.viewModel(for: host, tmuxSessionName: "main")
        let vm2 = manager.viewModel(for: host, tmuxSessionName: "main")

        #expect(ObjectIdentifier(vm1) == ObjectIdentifier(vm2))
    }

    @Test func sameHostDifferentSessionsGetDifferentVMs() async throws {
        let manager = SessionManager(maxSessions: 5)
        let host = makeHost("alpha")

        let vmA = manager.viewModel(for: host, tmuxSessionName: "main")
        let vmB = manager.viewModel(for: host, tmuxSessionName: "scratch")

        #expect(ObjectIdentifier(vmA) != ObjectIdentifier(vmB))
    }

    @Test func differentHostsGetDifferentViewModels() async throws {
        let manager = SessionManager(maxSessions: 5)
        let a = makeHost("alpha")
        let b = makeHost("beta")

        let vmA = manager.viewModel(for: a, tmuxSessionName: "main")
        let vmB = manager.viewModel(for: b, tmuxSessionName: "main")

        #expect(ObjectIdentifier(vmA) != ObjectIdentifier(vmB))
    }

    @Test func noTmuxSessionIsRegisteredWithEmptyName() async throws {
        let manager = SessionManager(maxSessions: 5)
        let host = makeHost("alpha")
        _ = manager.viewModel(for: host, tmuxSessionName: "")
        try await Task.sleep(for: .milliseconds(50))

        #expect(manager.activeSessions.count == 1)
        #expect(manager.activeSessions.first?.key.tmuxSessionName == "")
    }

    @Test func registrationPopulatesActiveSessions() async throws {
        let manager = SessionManager(maxSessions: 5)
        let host = makeHost("alpha")
        _ = manager.viewModel(for: host, tmuxSessionName: "work")

        // Registration is deferred to next runloop tick.
        try await Task.sleep(for: .milliseconds(50))

        #expect(manager.activeSessions.count == 1)
        #expect(manager.activeSessions.first?.key.hostID == host.id)
        #expect(manager.activeSessions.first?.key.tmuxSessionName == "work")
    }

    @Test func sessionsForHostFiltersCorrectly() async throws {
        let manager = SessionManager(maxSessions: 5)
        let a = makeHost("alpha")
        let b = makeHost("beta")
        _ = manager.viewModel(for: a, tmuxSessionName: "main")
        _ = manager.viewModel(for: a, tmuxSessionName: "scratch")
        _ = manager.viewModel(for: b, tmuxSessionName: "main")
        try await Task.sleep(for: .milliseconds(80))

        let aSessions = manager.sessions(forHostID: a.id)
        let bSessions = manager.sessions(forHostID: b.id)

        #expect(aSessions.count == 2)
        #expect(bSessions.count == 1)
        #expect(Set(aSessions.map { $0.key.tmuxSessionName }) == ["main", "scratch"])
    }

    @Test func lruEvictsOldestWhenOverCap() async throws {
        let manager = SessionManager(maxSessions: 2)
        let host = makeHost("alpha")

        _ = manager.viewModel(for: host, tmuxSessionName: "a")
        try await Task.sleep(for: .milliseconds(20))
        _ = manager.viewModel(for: host, tmuxSessionName: "b")
        try await Task.sleep(for: .milliseconds(20))
        _ = manager.viewModel(for: host, tmuxSessionName: "c")
        try await Task.sleep(for: .milliseconds(80))

        #expect(manager.activeSessions.count == 2)
        let names = Set(manager.activeSessions.map { $0.key.tmuxSessionName })
        #expect(!names.contains("a"))
        #expect(names.contains("b"))
        #expect(names.contains("c"))
        #expect(manager.evictionNotice != nil)
    }

    @Test func disconnectRemovesFromActiveSessions() async throws {
        let manager = SessionManager(maxSessions: 5)
        let host = makeHost("alpha")
        _ = manager.viewModel(for: host, tmuxSessionName: "main")
        try await Task.sleep(for: .milliseconds(50))

        let key = SessionKey(hostID: host.id, tmuxSessionName: "main")
        manager.disconnect(key: key)

        #expect(manager.activeSessions.isEmpty)
        #expect(manager.existingViewModel(for: key) == nil)
    }

    @Test func handleHostDeletedRemovesAllSessionsForHost() async throws {
        let manager = SessionManager(maxSessions: 5)
        let host = makeHost("alpha")
        _ = manager.viewModel(for: host, tmuxSessionName: "main")
        _ = manager.viewModel(for: host, tmuxSessionName: "scratch")
        _ = manager.viewModel(for: host, tmuxSessionName: "")
        try await Task.sleep(for: .milliseconds(80))

        manager.handleHostDeleted(host)

        #expect(manager.activeSessions.isEmpty)
    }

    @Test func disconnectAllClearsEverything() async throws {
        let manager = SessionManager(maxSessions: 5)
        _ = manager.viewModel(for: makeHost("alpha"), tmuxSessionName: "main")
        _ = manager.viewModel(for: makeHost("beta"), tmuxSessionName: "main")
        try await Task.sleep(for: .milliseconds(50))

        manager.disconnectAll()

        #expect(manager.activeSessions.isEmpty)
    }
}
