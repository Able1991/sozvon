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
        XCTAssertEqual(CallAutomation.mode(d), .ask, "по умолчанию спрашиваем")
        d.set(false, forKey: CallAutomation.legacyPromptKey)
        XCTAssertEqual(CallAutomation.mode(d), .off, "старый выключатель «Предлагать запись» выключен")
        CallAutomation.setMode(.record, d)
        XCTAssertEqual(CallAutomation.mode(d), .record, "новый выбор важнее старого")
        XCTAssertFalse(CallAutomation.autoStop(d), "автостоп по умолчанию выключен")
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
        XCTAssertNil(e.update(inCall: false, now: t0), "запись без звонка (встреча в комнате) не останавливается")
        XCTAssertNil(e.update(inCall: true, now: t0))
        XCTAssertNil(e.update(inCall: true, now: t0 + 60))
        XCTAssertEqual(e.update(inCall: false, now: t0 + 61, grace: 30), 30)
        XCTAssertEqual(e.update(inCall: false, now: t0 + 81, grace: 30), 10)
        XCTAssertNil(e.update(inCall: true, now: t0 + 82, grace: 30), "приложение снова взяло микрофон: отсчёт сброшен")
        XCTAssertEqual(e.update(inCall: false, now: t0 + 83, grace: 30), 30)
        XCTAssertEqual(e.update(inCall: false, now: t0 + 120, grace: 30), 0, "пора остановить")
    }

    func testShortMicUseDoesNotArm() {
        var e = CallEndDetector()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(e.update(inCall: true, now: t0))
        XCTAssertNil(e.update(inCall: false, now: t0 + 5), "голосовое на 5 секунд во время записи встречи")
        XCTAssertNil(e.update(inCall: false, now: t0 + 100), "и через 100 секунд тоже не останавливаем")
    }

    func testHoldIsCountedAtReleaseWithoutRefreshesInBetween() {
        var e = CallEndDetector()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(e.update(inCall: true, now: t0))
        XCTAssertEqual(e.update(inCall: false, now: t0 + 600, grace: 30), 30, "держал 10 минут, обновлений между не было")
    }

    func testOtherSideStillHeardMeansTheCallGoesOn() {
        var e = CallEndDetector()
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = e.update(inCall: true, now: t0)
        XCTAssertEqual(e.update(inCall: false, now: t0 + 60, grace: 30), 30)
        XCTAssertNil(e.update(inCall: false, otherSideAudible: true, now: t0 + 70, grace: 30), "микрофон выключен, но собеседника слышно")
        XCTAssertEqual(e.update(inCall: false, now: t0 + 71, grace: 30), 30, "отсчёт заново")
        XCTAssertEqual(e.update(inCall: false, now: t0 + 101, grace: 30), 0)
    }

    func testSoundAloneDoesNotArm() {
        var e = CallEndDetector()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(e.update(inCall: false, otherSideAudible: true, now: t0))
        XCTAssertNil(e.update(inCall: false, now: t0 + 100), "музыка на Маке не делает запись звонком")
    }

    func testKeepRecording() {
        var e = CallEndDetector()
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = e.update(inCall: true, now: t0)
        XCTAssertEqual(e.update(inCall: false, now: t0 + 60, grace: 30), 30)
        e.keepRecording()
        XCTAssertNil(e.update(inCall: false, now: t0 + 160, grace: 30), "«Продолжить»: не останавливаем")
        XCTAssertNil(e.update(inCall: true, now: t0 + 161, grace: 30), "новый звонок в той же записи")
        XCTAssertNil(e.update(inCall: true, now: t0 + 221, grace: 30))
        XCTAssertNil(e.update(inCall: false, now: t0 + 222, grace: 30), "приложение отпустило микрофон на mute: запись не трогаем")
        XCTAssertNil(e.update(inCall: false, now: t0 + 400, grace: 30), "до конца этой записи")
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
        XCTAssertTrue(w.inCall, "Zoom держит микрофон, даже до 5 секунд")
        src.clients = []
        w.refresh()
        XCTAssertFalse(w.inCall)
        XCTAssertGreaterThanOrEqual(refreshes, 3)
    }
}
