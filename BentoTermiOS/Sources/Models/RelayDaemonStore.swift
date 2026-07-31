import Foundation
import SwiftUI

/// RelayDaemonStore persists the list of paired daemons to
/// Documents/relay-daemons.json. Mirrors HostStore's atomic-write +
/// quarantine-on-broken-decode pattern so a corrupt file never erases the
/// user's pairings.

/// One-shot pair prefill that arrives via `bento://pair?d=…&c=…` deep link.
/// HostListView observes `pendingPair`, opens RelayPairView with the values
/// applied, and clears it once the sheet has been presented.
struct PendingRelayPair: Equatable {
    let daemonID: String
    let code: String
    let label: String?
}

@MainActor
final class RelayDaemonStore: ObservableObject {
    @Published var daemons: [RelayDaemon] = []
    @Published var pendingPair: PendingRelayPair?

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("relay-daemons.json")
    }()

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            daemons = try JSONDecoder().decode([RelayDaemon].self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("json.broken-\(stamp)")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            dlog("relay-daemons decode failed: \(error). Moved to \(backup.lastPathComponent)")
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(daemons) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func add(_ daemon: RelayDaemon) {
        daemons.append(daemon)
        save()
    }

    func update(_ daemon: RelayDaemon) {
        guard let idx = daemons.firstIndex(where: { $0.id == daemon.id }) else { return }
        daemons[idx] = daemon
        save()
    }

    func delete(_ daemon: RelayDaemon) {
        daemons.removeAll { $0.id == daemon.id }
        // Best-effort: also drop the device key from Keychain. If it fails
        // we still want the daemon gone from the user's list.
        try? KeychainService.shared.deletePrivateKey(label: daemon.deviceKeyLabel)
        save()
    }

    func markConnected(_ daemon: RelayDaemon) {
        var updated = daemon
        updated.lastConnected = Date()
        update(updated)
    }
}
