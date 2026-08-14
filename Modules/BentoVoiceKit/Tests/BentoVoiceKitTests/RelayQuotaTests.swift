import XCTest
@testable import BentoVoiceKit

/// The client half of the relay's voice quota: identifying this install, and
/// turning a refusal into something a user can act on. The relay's own metering
/// is tested in the worker (`relay/src/quota.test.ts`).
final class RelayQuotaTests: XCTestCase {

    private func scratchDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "bento.relayquota.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    func testInstallIDIsMintedOnceAndLooksLikeAUUID() {
        let defaults = scratchDefaults()
        let first = RelayInstall.id(defaults: defaults)
        XCTAssertNotNil(UUID(uuidString: first), "the relay rejects anything that isn't a UUID")
        XCTAssertEqual(first, first.lowercased(), "sent lowercase; the relay compares lowercased")
        XCTAssertEqual(RelayInstall.id(defaults: defaults), first, "stable across calls")
    }

    func testInstallIDIsNotTheTelemetryIdentifier() {
        let defaults = scratchDefaults()
        _ = RelayInstall.id(defaults: defaults)
        XCTAssertNil(defaults.string(forKey: "telemetry_install_id"),
                     "metering must not mint or reuse the consent-bound telemetry id")
    }

    func testStampSetsTheHeader() {
        let defaults = scratchDefaults()
        var request = URLRequest(url: URL(string: "https://relay.bentoai.dev/v1/asr/qwen/transcribe")!)
        RelayInstall.stamp(&request, defaults: defaults)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-bento-install"),
                       RelayInstall.id(defaults: defaults))
    }

    func testParsesTheSocketErrorFrameShape() {
        // What `refuseSocket` sends: the `error` object of a Qwen error frame.
        let payload: [String: Any] = [
            "type": "bento_relay",
            "code": "quota_exhausted",
            "message": "daily voice quota reached",
            "reset_seconds": 7200,
        ]
        let parsed = RelayQuotaError.from(payload: payload)
        XCTAssertEqual(parsed?.reason, .quotaExhausted)
        XCTAssertEqual(parsed?.resetSeconds, 7200)
    }

    func testParsesThe429BodyShape() {
        // The HTTP body uses `error` for the code; both shapes must parse.
        let body = Data(#"{"error":"too_many_installs","message":"…","reset_seconds":86400}"#.utf8)
        let parsed = BatchTranscriptionService.refusal(status: 429, body: body)
        XCTAssertEqual(parsed?.reason, .tooManyInstalls)
        XCTAssertEqual(parsed?.resetSeconds, 86400)
    }

    func testOnlyQuotaStatusesAreReadAsRefusals() {
        let body = Data(#"{"error":"quota_exhausted"}"#.utf8)
        XCTAssertNil(BatchTranscriptionService.refusal(status: 502, body: body),
                     "an upstream failure is not the user's quota")
        XCTAssertNil(BatchTranscriptionService.refusal(status: 429, body: Data("nope".utf8)))
        XCTAssertNil(RelayQuotaError.from(payload: ["code": "something_else"]))
    }

    func testCopyTellsTheUserWhatToDo() {
        let spent = RelayQuotaError(reason: .quotaExhausted, resetSeconds: 3 * 3600)
        let text = spent.errorDescription ?? ""
        XCTAssertTrue(text.contains("back in 3h"), "says when it comes back: \(text)")
        XCTAssertTrue(text.contains("Settings"), "says the way out: \(text)")

        // No countdown when the relay didn't say when — better silent than wrong.
        let unknown = RelayQuotaError(reason: .quotaExhausted)
        XCTAssertFalse((unknown.errorDescription ?? "").contains("back in"))

        // Sub-hour waits round up to a minute rather than reading "back in 0m".
        let soon = RelayQuotaError(reason: .globalQuota, resetSeconds: 30)
        XCTAssertTrue((soon.errorDescription ?? "").contains("back in 1m"))
    }
}
