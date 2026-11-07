// Marks, audio retention, silence recovery, calendar prefill.

import Foundation
import XCTest
@testable import SozvonCore

final class CallMarksTests: XCTestCase {
    func testOffsetsFromEarliestTrackDedupedAndClamped() {
        let audio = AudioTimes(micStart: 1000.5, systemStart: 1000.0)
        XCTAssertEqual(CallMarks.offsets([999, 1060.04, 1062, 1200], audio: audio), [0, 60, 200])
        XCTAssertEqual(CallMarks.offsets([1010], audio: AudioTimes()), [], "no audio: no timeline")
    }

    func testReadIgnoresJunk() {
        XCTAssertEqual(CallMarks.read(["marks": [30, "x", -1, 12.5]]), [12.5, 30])
        XCTAssertEqual(CallMarks.read([:]), [])
    }
}

final class AudioRetentionTests: TempDirTestCase {
    private func call(_ id: String, created: Date, status: String = "done", transcript: Bool = true) throws -> URL {
        let d = calls.appendingPathComponent(id)
        try write("{\"id\":\"\(id)\",\"status\":\"\(status)\",\"created_at\":\"\(ISO8601DateFormatter().string(from: created))\"}",
                  d.appendingPathComponent("call.json"))
        try write("audio", d.appendingPathComponent("mic.m4a"))
        try write("audio!", d.appendingPathComponent("system.m4a"))
        if transcript { try write("[00:01] A: hi\n", d.appendingPathComponent("transcript.txt")) }
        return d
    }

    func testOnlyOldFinishedTranscribedIdleCallsExpire() throws {
        let now = Date()
        let old = try call("old", created: now.addingTimeInterval(-40 * 86400))
        _ = try call("fresh", created: now.addingTimeInterval(-3 * 86400))
        _ = try call("failed", created: now.addingTimeInterval(-40 * 86400), status: "failed")
        _ = try call("notext", created: now.addingTimeInterval(-40 * 86400), transcript: false)
        let busy = try call("busy", created: now.addingTimeInterval(-40 * 86400))
        XCTAssertEqual(AudioRetention.expired(in: calls, days: 30, now: now, busy: [busy]).map(\.lastPathComponent), ["old"])
        XCTAssertEqual(AudioRetention.expired(in: calls, days: 0, now: now), [], "0 = keep forever")

        XCTAssertEqual(AudioRetention.removeAudio(old, now: now), 11)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.appendingPathComponent("mic.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("transcript.txt").path))
        XCTAssertNotNil(try json(old.appendingPathComponent("call.json"))[AudioRetention.removedKey])
        XCTAssertEqual(AudioRetention.expired(in: calls, days: 30, now: now, busy: [busy]), [], "already without audio")
    }
}

final class SilenceWatchTests: XCTestCase {
    func testRestartOnceThenGiveUpThenResetOnSound() {
        var w = SilenceWatch()
        XCTAssertEqual(w.update(silent: 60), .none)
        XCTAssertEqual(w.update(silent: 120), .restart)
        XCTAssertEqual(w.update(silent: 130), .none)
        XCTAssertEqual(w.update(silent: 149), .none)
        XCTAssertTrue(w.warns(silent: 150))
        XCTAssertEqual(w.update(silent: 150), .tell)
        XCTAssertEqual(w.update(silent: 400), .none, "says it once")
        XCTAssertEqual(w.update(silent: 0), .none)
        XCTAssertEqual(w.update(silent: 121), .restart, "a new silence starts over")
    }

    func testOtherSideNeverHeardIsToldAtTwoAndAHalfMinutes() {
        var w = SilenceWatch(patient: true)
        _ = w.update(silent: 0, sound: true)  // a chime: not enough to count as heard
        XCTAssertFalse(w.heard)
        XCTAssertEqual(w.update(silent: 120), .restart)
        XCTAssertEqual(w.update(silent: 150), .tell)
    }

    func testOtherSideHeardBeforeIsToldOnlyAfterFiveMinutes() {
        var w = SilenceWatch(patient: true)
        for _ in 0..<SilenceWatch.heardAfterUpdates { _ = w.update(silent: 0, sound: true) }
        XCTAssertTrue(w.heard)
        XCTAssertEqual(w.update(silent: 120), .restart, "the quiet recapture still runs")
        XCTAssertEqual(w.update(silent: 150), .none, "they are most likely listening")
        XCTAssertFalse(w.warns(silent: 299))
        XCTAssertEqual(w.update(silent: 300), .tell)
        XCTAssertEqual(w.update(silent: 0), .none)
        XCTAssertTrue(w.heard, "heard stays for the whole recording")
    }

    func testMicIsNotPatient() {
        var w = SilenceWatch()
        for _ in 0..<100 { _ = w.update(silent: 0, sound: true) }
        _ = w.update(silent: 120)
        XCTAssertEqual(w.update(silent: 150), .tell, "digital zeros from the mic are a fault, whatever came before")
    }

    func testMicDigitalSilenceCounts() {
        var m = SignalMonitor()
        let t0 = Date()
        _ = m.update(now: t0, mic: (0.3, t0), system: (0.3, t0), micZero: true)
        let r = m.update(now: t0.addingTimeInterval(130), mic: (0, t0.addingTimeInterval(130)),
                         system: (0.3, t0.addingTimeInterval(130)), micZero: true)
        XCTAssertEqual(r.micSilent, 130)
        XCTAssertEqual(r.micMissing, 0, "packets keep coming")
        let back = m.update(now: t0.addingTimeInterval(131), mic: (0.2, t0.addingTimeInterval(131)),
                            system: (0.3, t0.addingTimeInterval(131)))
        XCTAssertEqual(back.micSilent, 0)
    }
}

final class ZeroWatchTests: XCTestCase {
    func testNewTapAfterEightSecondsThenAgainWithGrowingPauses() {
        var w = ZeroWatch()
        let t0 = Date(timeIntervalSince1970: 1000)
        func at(_ s: Double, zero: Bool = true) -> ZeroWatch.Action { w.update(now: t0.addingTimeInterval(s), zero: zero) }
        XCTAssertEqual(at(0), .none)
        XCTAssertEqual(at(7.9), .none)
        XCTAssertEqual(at(8), .newTap)
        XCTAssertEqual(at(22), .none)
        XCTAssertEqual(at(23), .newTap, "15 s later")
        XCTAssertEqual(at(52), .none)
        XCTAssertEqual(at(53), .newTap, "then 30 s")
        XCTAssertEqual(at(112), .none)
        XCTAssertEqual(at(113), .newTap, "then 60 s")
        var t = 113.0
        for _ in 0..<10 { t += 400; XCTAssertEqual(at(t), .newTap, "zeros alone never leave the tap") }
        XCTAssertEqual(at(t + ZeroWatch.maxPause - 1), .none, "never more often than maxPause once grown")
    }

    func testSoundStartsOver() {
        var w = ZeroWatch()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = w.update(now: t0, zero: true)
        XCTAssertEqual(w.update(now: t0.addingTimeInterval(8), zero: true), .newTap)
        XCTAssertEqual(w.update(now: t0.addingTimeInterval(9), zero: false), .none)
        XCTAssertEqual(w.update(now: t0.addingTimeInterval(10), zero: true), .none)
        XCTAssertEqual(w.update(now: t0.addingTimeInterval(18), zero: true), .newTap, "a new episode: a new tap first")
    }
}

final class LevelsTests: XCTestCase {
    func testScales() {
        XCTAssertEqual(Levels.meter(1), 1)
        XCTAssertEqual(Levels.meter(0.01), 0.2, accuracy: 0.001, "-40 dB: QuietMicWatch.loud")
        XCTAssertEqual(Levels.meter(0.001), 0, accuracy: 0.001, "-60 dB is below the meter")
        XCTAssertEqual(Levels.display(0.001), 0.3, accuracy: 0.001, "the waveform still shows -60 dB")
        XCTAssertEqual(Levels.display(0.1), 1, "-20 dB is the top of the waveform")
        XCTAssertTrue(Levels.isDigitalSilence(0))
        XCTAssertFalse(Levels.isDigitalSilence(0.0003), "a quiet room, about -70 dB")
    }
}

final class CalendarMatchTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    let projects = [Project(slug: "globex", title: "Globex.io / МедиаКлуб", people: ["Олег Иванов", "Мария"]),
                    Project(slug: "vitrina", title: "Витрина", people: ["Ира"])]

    private func event(_ title: String, from: Double, to: Double, link: Bool = false, people: [CalendarEvent.Attendee] = [],
                       allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(title: title, start: t.addingTimeInterval(from * 60), end: t.addingTimeInterval(to * 60),
                      isAllDay: allDay, attendees: people, hasCallLink: link)
    }

    func testPicksCallWithLinkOverLunchAndAllDay() {
        let lunch = event("Обед", from: -10, to: 50)
        let call = event("Созвон по релизу", from: 5, to: 35, link: true)
        let vacation = event("Отпуск", from: -600, to: 600, allDay: true)
        XCTAssertEqual(CalendarMatch.best([lunch, vacation, call], recordingStart: t), call)
        XCTAssertNil(CalendarMatch.best([event("Позже", from: 30, to: 60)], recordingStart: t), "starts in 30 minutes")
        XCTAssertNotNil(CalendarMatch.best([event("Затянулся", from: -70, to: -5)], recordingStart: t), "ended 5 minutes ago")
    }

    func testPeopleWithoutMeAndFromEmails() {
        let e = event("x", from: 0, to: 30, people: [.init(name: "Борис", isMe: true), .init(name: "Олег Иванов"),
                                                     .init(name: "", email: "maria.k@acme.com"), .init(name: "Олег Иванов")])
        XCTAssertEqual(CalendarMatch.people(e), ["Олег Иванов", "maria.k"])
    }

    func testProjectByTitleThenByPeople() {
        XCTAssertEqual(CalendarMatch.project(for: event("Globex.io: еженедельный", from: 0, to: 30), in: projects)?.slug, "globex")
        let byPeople = event("Синк", from: 0, to: 30, people: [.init(name: "Ира Смирнова")])
        XCTAssertEqual(CalendarMatch.project(for: byPeople, in: projects)?.slug, "vitrina")
        XCTAssertNil(CalendarMatch.project(for: event("Синк", from: 0, to: 30), in: projects))
    }

    func testFillKeepsWhatTheUserTyped() {
        let e = event("Витрина: планирование", from: 0, to: 30, people: [.init(name: "Ира")])
        let filled = CalendarMatch.fill(CallInfo(profile: "globex"), from: e, projects: projects)
        XCTAssertEqual(filled.topic, "Витрина: планирование")
        XCTAssertEqual(filled.names, "Ира")
        XCTAssertEqual(filled.profile, "vitrina", "the last project was only a guess")
        let typed = CalendarMatch.fill(CallInfo(profile: "globex", names: "Олег"), from: e, projects: projects)
        XCTAssertEqual(typed.names, "Олег")
        XCTAssertEqual(typed.profile, "globex", "the user picked during the recording")
        XCTAssertEqual(typed.topic, "Витрина: планирование")
    }
}

final class QuietMicWatchTests: XCTestCase {
    func testTellsOnceWhenNeverLoud() {
        var w = QuietMicWatch()
        XCTAssertFalse(w.update(level: 0.1, seconds: 60))
        XCTAssertTrue(w.update(level: 0.1, seconds: 180))
        XCTAssertFalse(w.update(level: 0.1, seconds: 400), "once")
        var ok = QuietMicWatch()
        _ = ok.update(level: 0.6, seconds: 10)
        XCTAssertFalse(ok.update(level: 0, seconds: 500), "a normal voice was heard: silence is just listening")
    }
}
