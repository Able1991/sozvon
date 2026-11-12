// Automatic start and stop around a call: the settings and the end-of-call countdown.

import Foundation
import XCTest
@testable import SozvonCore

@MainActor
private final class MicFake: MicActivitySource {
    var clients: [MicClient] = []
    func activeClients() -> [MicClient] { clients }
    func start(onChange: @escaping @MainActor () -> Void) {}
    func stop() {}
}

final class CallAutomationTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "sozvon-tests-callauto")!
        d.removePersistentDomain(forName: "sozvon-tests-callauto")
        return d
    }

    func testModeDefaultsAndMigration() {
        let d = defaults()
        XCTAssertEqual(CallAutomation.mode(d), .ask, "we ask by default")
        d.set(false, forKey: CallAutomation.legacyPromptKey)
        XCTAssertEqual(CallAutomation.mode(d), .off, "the old \"Offer to record\" switch is off")
        CallAutomation.setMode(.record, d)
        XCTAssertEqual(CallAutomation.mode(d), .record, "the new choice wins over the old one")
        XCTAssertFalse(CallAutomation.autoStop(d), "auto-stop is off by default")
        d.removePersistentDomain(forName: "sozvon-tests-callauto")
    }

    func testConsentReminderIsOffUntilChosen() {
        let d = defaults()
        XCTAssertFalse(CallAutomation.remindConsent(d))
        CallAutomation.setRemindConsent(true, d)
        XCTAssertTrue(CallAutomation.remindConsent(d))
        d.removePersistentDomain(forName: "sozvon-tests-callauto")
    }

    func testEndCountdown() {
        var e = CallEndDetector()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(e.update(inCall: false, now: t0), "a recording without a call (a meeting in a room) is not stopped")
        XCTAssertNil(e.update(inCall: true, now: t0))
        XCTAssertNil(e.update(inCall: true, now: t0 + 60))
        XCTAssertEqual(e.update(inCall: false, now: t0 + 61, grace: 30), 30)
        XCTAssertEqual(e.update(inCall: false, now: t0 + 81, grace: 30), 10)
        XCTAssertNil(e.update(inCall: true, now: t0 + 82, grace: 30), "the app took the microphone again: the countdown is reset")
        XCTAssertEqual(e.update(inCall: false, now: t0 + 83, grace: 30), 30)
        XCTAssertEqual(e.update(inCall: false, now: t0 + 120, grace: 30), 0, "time to stop")
    }

    func testShortMicUseDoesNotArm() {
        var e = CallEndDetector()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(e.update(inCall: true, now: t0))
        XCTAssertNil(e.update(inCall: false, now: t0 + 5), "a 5 second voice message while a meeting is being recorded")
        XCTAssertNil(e.update(inCall: false, now: t0 + 100), "and not stopped after 100 seconds either")
    }

    func testHoldIsCountedAtReleaseWithoutRefreshesInBetween() {
        var e = CallEndDetector()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(e.update(inCall: true, now: t0))
        XCTAssertEqual(e.update(inCall: false, now: t0 + 600, grace: 30), 30, "held for 10 minutes with no updates in between")
    }

    func testOtherSideStillHeardMeansTheCallGoesOn() {
        var e = CallEndDetector()
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = e.update(inCall: true, now: t0)
        XCTAssertEqual(e.update(inCall: false, now: t0 + 60, grace: 30), 30)
        XCTAssertNil(e.update(inCall: false, otherSideAudible: true, now: t0 + 70, grace: 30), "the microphone is off, but the other side is audible")
        XCTAssertEqual(e.update(inCall: false, now: t0 + 71, grace: 30), 30, "the countdown starts over")
        XCTAssertEqual(e.update(inCall: false, now: t0 + 101, grace: 30), 0)
    }

    func testSoundAloneDoesNotArm() {
        var e = CallEndDetector()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(e.update(inCall: false, otherSideAudible: true, now: t0))
        XCTAssertNil(e.update(inCall: false, now: t0 + 100), "music on the Mac does not make a recording a call")
    }

    func testKeepRecording() {
        var e = CallEndDetector()
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = e.update(inCall: true, now: t0)
        XCTAssertEqual(e.update(inCall: false, now: t0 + 60, grace: 30), 30)
        e.keepRecording()
        XCTAssertNil(e.update(inCall: false, now: t0 + 160, grace: 30), "\"Continue\": do not stop")
        XCTAssertNil(e.update(inCall: true, now: t0 + 161, grace: 30), "a new call in the same recording")
        XCTAssertNil(e.update(inCall: true, now: t0 + 221, grace: 30))
        XCTAssertNil(e.update(inCall: false, now: t0 + 222, grace: 30), "the app released the microphone on mute: the recording is left alone")
        XCTAssertNil(e.update(inCall: false, now: t0 + 400, grace: 30), "until the end of this recording")
    }

    @MainActor
    func testWatcherReportsCallOnMic() {
        let src = MicFake()
        let w = CallWatcher(source: src, ownPID: 1, ownBundleID: "own", schedule: { _, _ in })
        var refreshes = 0
        w.onRefresh = { refreshes += 1 }
        w.start()
        XCTAssertFalse(w.inCall)
        src.clients = [MicClient(pid: 42, bundleID: "us.zoom.xos")]
        w.refresh()
        XCTAssertTrue(w.inCall, "Zoom holds the microphone, even for under 5 seconds")
        src.clients = []
        w.refresh()
        XCTAssertFalse(w.inCall)
        XCTAssertGreaterThanOrEqual(refreshes, 3)
    }
}
