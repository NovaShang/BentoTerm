import Foundation
import Testing

/// The update feed's facts, read back out of the app that was actually built.
///
/// **Why this is a test and not a code review.** These are Sparkle's Info.plist
/// keys, not Apple's, and Xcode's generated Info.plist only carries keys it
/// recognises: `INFOPLIST_KEY_SUFeedURL` in project.yml is dropped without a
/// word. The app builds, the updater starts with no feed and no key to verify
/// against, nothing is logged, and the first symptom is that no install out
/// there ever offers an update again. So the bundle gets asked directly.
///
/// The public key is spelled out rather than merely checked for existence: it
/// is the half of a pair whose private half signs every release. Changing it
/// strands every copy already installed — those verify against the key THEY
/// shipped with — so a change here should have to be typed twice.
@Suite struct UpdateFeedPlistTests {

    /// The host app under test, whose Info.plist is the thing being checked.
    private var info: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    @Test func theFeedPointsAtTheLatestReleasesAppcast() {
        let feed = info["SUFeedURL"] as? String
        #expect(feed == "https://github.com/NovaShang/BentoTerm/releases/latest/download/appcast.xml")
        // Not just "a URL": Sparkle refuses a plain-HTTP feed, and quietly
        // getting this wrong would disable updates rather than warn.
        #expect(feed?.hasPrefix("https://") == true)
    }

    @Test func thePublicKeyIsTheOneReleasesAreSignedWith() {
        #expect(info["SUPublicEDKey"] as? String == "GQdlUUq0q/cPJ/ymfftOUvylZIq5qayZb4rm+GvYxi8=")
    }

    /// Checking is on; installing is not. A terminal that relaunches itself to
    /// apply an update takes live panes with it, so the restart is always the
    /// user's move.
    @Test func itChecksOnItsOwnButNeverInstallsOnItsOwn() {
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == false)
    }

    /// The Privacy panel says nothing about this Mac is sent with the check.
    /// That sentence is only true while this key is false.
    @Test func noSystemProfileRidesAlongWithTheCheck() {
        #expect(info["SUSendProfileInfo"] as? Bool == false)
    }

    /// The keys Xcode generates have to survive the arrival of a base
    /// Info.plist — merging is the whole reason INFOPLIST_FILE could be added
    /// without moving everything else into it.
    @Test func theGeneratedKeysAreStillThere() {
        #expect(info["CFBundleDisplayName"] as? String == "BentoTerm")
        #expect((info["NSMicrophoneUsageDescription"] as? String)?.isEmpty == false)
    }
}
