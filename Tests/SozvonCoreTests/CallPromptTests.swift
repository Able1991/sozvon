// "A call is on. Record?" detection and "Later" (pending call info, reminders).

import Foundation
import XCTest
@testable import SozvonCore

@MainActor
private final class FakeMicSource: MicActivitySource {
    var clients: [MicClient] = []
    var onChange: (@MainActor () -> Void)?
    var started = false

    func activeClients() -> [MicClient] { clients }
    func start(onChange: @escaping @MainActor () -> Void) { started = true; self.onChange = onChange }
    func stop() { started = false; onChange = nil }

    func set(_ c: [MicClient]) {
        clients = c
        onChange?()
    }
}

private let zoom = MicClient(pid: 100, bundleID: "us.zoom.xos")
private let chromeHelper = MicClient(pid: 200, bundleID: "com.google.Chrome.helper")
private let me = MicClient(pid: 42, bundleID: "io.github.able1991.sozvon")
private let siri = MicClient(pid: 300, bundleID: "com.apple.SiriNCService")
private let dictation = MicClient(pid: 301, bundleID: "com.apple.SpeechRecognitionCore.speechrecognitiond")
private let faceTimeDaemon = MicClient(pid: 400, bundleID: "", processName: "avconferenced")

final class CallDetectorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func detector() -> CallDetector { CallDetector(ownPID: 42, ownBundleID: "io.github.able1991.sozvon") }

    func testKnownAppsAndHelpers() {
        XCTAssertEqual(CallApps.app(for: zoom)?.name, "Zoom")
        XCTAssertEqual(CallApps.app(for: chromeHelper)?.name, "Chrome")
        // The WebKit GPU process is shared by every WebKit app: Safari only while Safari runs.
        let gpu = MicClient(pid: 1, bundleID: "com.apple.WebKit.GPU")
        XCTAssertEqual(CallApps.app(for: gpu, safariRunning: true)?.name, "Safari")
        XCTAssertNil(CallApps.app(for: gpu, safariRunning: false))
        XCTAssertNil(CallApps.app(for: gpu))
        XCTAssertEqual(CallApps.app(for: MicClient(pid: 1, bundleID: "ru.keepcoder.Telegram"))?.name, "Telegram")
        XCTAssertEqual(CallApps.app(for: MicClient(pid: 1, bundleID: "ru.trueconf.client"))?.name, "TrueConf")
        XCTAssertEqual(CallApps.app(for: faceTimeDaemon)?.name, "FaceTime")
        XCTAssertNil(CallApps.app(for: siri))
        XCTAssertNil(CallApps.app(for: dictation))
        XCTAssertNil(CallApps.app(for: MicClient(pid: 1, bundleID: "us.zoomer")), "a prefix must end at a dot")
    }

    func testDebounce() {
        var d = detector()
        XCTAssertNil(d.update([zoom], now: at(0), busy: false))
        XCTAssertEqual(d.nextCheck(), at(5))
        XCTAssertNil(d.update([zoom], now: at(4.9), busy: false), "less than 5 seconds: no prompt yet")
        XCTAssertEqual(d.update([zoom], now: at(5), busy: false)?.name, "Zoom")
        XCTAssertNil(d.nextCheck(), "a prompt is shown: nothing to wait for")
    }

    func testReleaseRestartsDebounce() {
        var d = detector()
        d.update([zoom], now: at(0), busy: false)
        d.update([], now: at(3), busy: false)
        XCTAssertNil(d.update([zoom], now: at(6), busy: false), "the mic was released: the 5 seconds start over")
        XCTAssertEqual(d.update([zoom], now: at(11), busy: false)?.name, "Zoom")
    }

    func testPromptDisappearsOnRelease() {
        var d = detector()
        d.update([zoom], now: at(0), busy: false)
        XCTAssertNotNil(d.update([zoom], now: at(6), busy: false))
        XCTAssertNil(d.update([], now: at(7), busy: false))
        XCTAssertNil(d.prompt)
    }

    func testIgnoresOwnProcessSiriAndDictation() {
        var d = detector()
        let ownByBundle = MicClient(pid: 43, bundleID: "io.github.able1991.sozvon")
        let ownZoomPID = MicClient(pid: 42, bundleID: "us.zoom.xos")
        d.update([me, ownByBundle, ownZoomPID, siri, dictation], now: at(0), busy: false)
        XCTAssertNil(d.update([me, ownByBundle, ownZoomPID, siri, dictation], now: at(60), busy: false))
        XCTAssertNil(d.nextCheck())
    }

    func testNotNowSuppressesUntilRelease() {
        var d = detector()
        d.update([zoom], now: at(0), busy: false)
        XCTAssertNotNil(d.update([zoom], now: at(5), busy: false))
        d.dismiss()
        XCTAssertNil(d.prompt)
        XCTAssertNil(d.update([zoom], now: at(600), busy: false), "Not now: quiet while Zoom keeps the mic")
        XCTAssertNil(d.nextCheck())
        d.update([], now: at(601), busy: false)
        d.update([zoom], now: at(700), busy: false)
        XCTAssertEqual(d.update([zoom], now: at(705), busy: false)?.name, "Zoom", "a new call after release asks again")
    }

    func testNotNowForOneAppLeavesOthers() {
        var d = detector()
        d.update([zoom], now: at(0), busy: false)
        d.update([zoom, chromeHelper], now: at(2), busy: false)
        XCTAssertEqual(d.update([zoom, chromeHelper], now: at(7), busy: false)?.name, "Zoom", "the oldest first")
        d.dismiss()
        XCTAssertEqual(d.update([zoom, chromeHelper], now: at(8), busy: false)?.name, "Chrome")
    }

    func testBusyHidesAndSuppressesCurrentApps() {
        var d = detector()
        d.update([zoom], now: at(0), busy: false)
        XCTAssertNotNil(d.update([zoom], now: at(6), busy: false))
        XCTAssertNil(d.update([zoom], now: at(7), busy: true), "recording: no prompt")
        XCTAssertNil(d.update([zoom], now: at(900), busy: false), "the recording stopped mid-call: don't nag")
        d.update([], now: at(901), busy: false)
        d.update([zoom], now: at(1000), busy: false)
        XCTAssertNotNil(d.update([zoom], now: at(1005), busy: false))
    }

    func testCallStartingDuringRecordingIsNotOffered() {
        var d = detector()
        d.update([], now: at(0), busy: true)
        d.update([zoom], now: at(1), busy: true)
        XCTAssertNil(d.update([zoom], now: at(60), busy: false))
    }
}

@MainActor
final class CallWatcherTests: XCTestCase {
    func testWatcherDebouncesWithScheduledCheck() {
        let src = FakeMicSource()
        var now = Date(timeIntervalSince1970: 0)
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        let w = CallWatcher(source: src, ownPID: 42, ownBundleID: "io.github.able1991.sozvon", now: { now },
                            schedule: { delay, work in scheduled.append((delay, work)) })
        var prompts: [String?] = []
        w.onPrompt = { prompts.append($0?.name) }
        w.start()
        XCTAssertTrue(src.started)
        src.set([zoom])
        XCTAssertEqual(scheduled.last?.0, 5, "check again when the debounce runs out")
        now = now.addingTimeInterval(5)
        scheduled.last?.1()
        XCTAssertEqual(w.prompt?.name, "Zoom")
        XCTAssertEqual(prompts, ["Zoom"])
        w.dismiss()
        XCTAssertEqual(prompts, ["Zoom", nil])
        now = now.addingTimeInterval(30)
        src.set([zoom])
        XCTAssertNil(w.prompt)
        src.set([])
        src.set([zoom])
        now = now.addingTimeInterval(5)
        scheduled.last?.1()
        XCTAssertEqual(prompts, ["Zoom", nil, "Zoom"])
        src.set([])
        XCTAssertEqual(prompts, ["Zoom", nil, "Zoom", nil], "the prompt disappears when the mic is released")
    }

    func testWebKitGPUCountsOnlyWhileSafariRuns() {
        let src = FakeMicSource()
        var now = Date(timeIntervalSince1970: 0)
        var safari = false
        let w = CallWatcher(source: src, ownPID: 42, ownBundleID: "x", now: { now }, schedule: { _, _ in })
        w.isSafariRunning = { safari }
        w.start()
        let gpu = MicClient(pid: 7, bundleID: "com.apple.WebKit.GPU")
        src.set([gpu])
        now = now.addingTimeInterval(10)
        w.refresh()
        XCTAssertNil(w.prompt, "Mail or another WebKit app on the mic: no Safari prompt")
        safari = true
        src.set([])
        src.set([gpu])
        now = now.addingTimeInterval(10)
        w.refresh()
        XCTAssertEqual(w.prompt?.name, "Safari")
    }

    func testStaleScheduledCheckIsIgnoredAndBusyBlocks() {
        let src = FakeMicSource()
        var now = Date(timeIntervalSince1970: 0)
        var scheduled: [@MainActor () -> Void] = []
        var busy = false
        let w = CallWatcher(source: src, ownPID: 42, ownBundleID: "x", now: { now },
                            schedule: { _, work in scheduled.append(work) })
        w.isBusy = { busy }
        w.start()
        src.set([zoom])
        busy = true
        now = now.addingTimeInterval(10)
        w.refresh()
        scheduled.first?()  // the first check is stale
        XCTAssertNil(w.prompt)
        busy = false
        w.refresh()
        XCTAssertNil(w.prompt, "recorded while Zoom held the mic: quiet until it releases")
        w.stop()
        XCTAssertFalse(src.started)
    }
}

final class PendingInfoTests: TempDirTestCase {
    private func makeCall(_ id: String, _ json: String) throws -> URL {
        let dir = calls.appendingPathComponent(id)
        try write(json, dir.appendingPathComponent("call.json"))
        return dir
    }

    func testRoundTripAndTransitions() throws {
        let dir = try makeCall("2026-11-04 15-04", #"{"schema": 1, "id": "2026-11-04 15-04", "status": "recorded", "topic": "x"}"#)
        XCTAssertFalse(try XCTUnwrap(Call.load(dir)).infoPending)

        XCTAssertTrue(CallFile.setInfoPending(dir, true))
        var c = CallFile.read(dir)
        XCTAssertEqual(c["info_pending"] as? Bool, true)
        XCTAssertEqual(c["schema"] as? Int, 1, "schema stays 1")
        XCTAssertEqual(c["topic"] as? String, "x", "other fields kept")
        XCTAssertTrue(try XCTUnwrap(Call.load(dir)).infoPending)

        // The answers written later keep the flag; only an explicit clear removes it.
        CallFile.writeInfo(dir, CallInfo(topic: "y"))
        XCTAssertTrue(PendingInfo.isPending(CallFile.read(dir)))

        XCTAssertTrue(CallFile.setInfoPending(dir, false))
        c = CallFile.read(dir)
        XCTAssertNil(c["info_pending"], "cleared: the field is removed, not false")
        XCTAssertFalse(try XCTUnwrap(Call.load(dir)).infoPending)
    }

    func testOnlyRecordedCallsArePending() throws {
        let dir = try makeCall("2026-11-04 15-04",
                               #"{"schema": 1, "id": "2026-11-04 15-04", "status": "done", "info_pending": true}"#)
        XCTAssertFalse(PendingInfo.isPending(CallFile.read(dir)), "transcribed another way (MCP): no longer pending")
        XCTAssertFalse(try XCTUnwrap(Call.load(dir)).infoPending)
        XCTAssertFalse(PendingInfo.isPending(["status": "recorded", "info_pending": "yes"]))
    }

    func testAllOldestFirst() throws {
        _ = try makeCall("2026-11-04 16-00", #"{"schema": 1, "id": "2026-11-04 16-00", "status": "recorded", "info_pending": true}"#)
        _ = try makeCall("2026-11-04 15-04", #"{"schema": 1, "id": "2026-11-04 15-04", "status": "recorded", "info_pending": true}"#)
        _ = try makeCall("2026-11-04 15-04-2", #"{"schema": 1, "id": "2026-11-04 15-04-2", "status": "recorded", "info_pending": true}"#)
        _ = try makeCall("2026-11-04 14-00", #"{"schema": 1, "id": "2026-11-04 14-00", "status": "recorded"}"#)
        XCTAssertEqual(PendingInfo.all(in: calls).map(\.id), ["2026-11-04 15-04", "2026-11-04 15-04-2", "2026-11-04 16-00"])
    }
}

final class ReminderPlannerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }
    let a = PendingCall(dir: URL(fileURLWithPath: "/c/a"), id: "2026-11-04 15-04", date: nil)
    let b = PendingCall(dir: URL(fileURLWithPath: "/c/b"), id: "2026-11-04 16-00", date: nil)

    func testWaitsForTenIdleMinutes() {
        var r = ReminderPlanner(now: at(0))
        XCTAssertEqual(r.due([a], now: at(9.9), busy: false), [])
        XCTAssertEqual(r.due([a], now: at(10), busy: false), [a])
    }

    func testNeverWhileRecordingAndRecordingResetsIdle() {
        var r = ReminderPlanner(now: at(0))
        XCTAssertEqual(r.due([a], now: at(30), busy: true), [], "never during a recording")
        r.activity(busy: false, now: at(40))
        XCTAssertEqual(r.due([a], now: at(49), busy: false), [], "idle counts from the end of the recording")
        XCTAssertEqual(r.due([a], now: at(50), busy: false), [a])
    }

    func testOncePerHourPerCall() {
        var r = ReminderPlanner(now: at(0))
        XCTAssertEqual(r.due([a], now: at(10), busy: false), [a])
        XCTAssertEqual(r.due([a], now: at(30), busy: false), [])
        XCTAssertEqual(r.due([a, b], now: at(40), busy: false), [b], "a new pending call is reminded on its own clock")
        XCTAssertEqual(r.due([a, b], now: at(69.9), busy: false), [])
        XCTAssertEqual(r.due([a, b], now: at(70), busy: false), [a])
        XCTAssertEqual(r.due([a, b], now: at(100), busy: false), [b])
    }

    func testDescribedCallIsForgotten() {
        var r = ReminderPlanner(now: at(0))
        XCTAssertEqual(r.due([a], now: at(10), busy: false), [a])
        XCTAssertEqual(r.due([], now: at(11), busy: false), [])
        XCTAssertEqual(r.due([a], now: at(12), busy: false), [a], "pending again (Later once more): a fresh call")
    }
}
