import Foundation

/// One-shot cleanup of UserDefaults left behind by features that no longer
/// exist. Shared by both apps because both wrote the keys.
///
/// The usage-counter service is gone: it posted to a relay that has been
/// deleted, so every event had become a request to a dead domain. What outlived
/// it on disk is worse than useless — a consent flag for a thing that cannot be
/// consented to, and a random install identifier minted to tag batches that will
/// never be sent. An identifier at rest with no feature behind it is exactly the
/// kind of residue the old service's own opt-out path was careful to delete, so
/// removing the service has to delete it too.
public enum RemovedFeatureCleanup {
    private static let doneKey = "purged_telemetry_defaults_v1"

    /// Call once at launch. Cheap and idempotent after the first run.
    public static func purgeTelemetryDefaults(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        defaults.removeObject(forKey: "telemetry_enabled")
        defaults.removeObject(forKey: "telemetry_install_id")
        defaults.removeObject(forKey: "telemetry_last_active_day")
        // The one-shot ledger was one key per event name, so it has to be swept
        // by prefix rather than by a list we would have to keep in sync with an
        // enum that no longer exists.
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("telemetry.once.") {
            defaults.removeObject(forKey: key)
        }
        dlog("purged leftover usage-counter defaults from the removed telemetry service")
    }
}
