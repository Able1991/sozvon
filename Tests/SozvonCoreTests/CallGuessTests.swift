// After a recording: project and participants from the calendar and the voices heard, and when to skip the form.

import Foundation
import XCTest
@testable import SozvonCore

final class CallGuessTests: XCTestCase {
    let acme = Project(slug: "acme", title: "Acme", people: ["Анна Петрова"])
    let beta = Project(slug: "beta", title: "Beta")
    var projects: [Project] { [acme, beta] }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func fill(_ info: CallInfo = CallInfo(), lastProject: String = "", event: CalendarEvent? = nil,
              heard: [HeardVoice] = [], startedAt: Date? = nil) -> (info: CallInfo, sure: Bool) {
        CallGuess.fill(info, defaultProfile: lastProject, startedAt: startedAt ?? t0 + 60, event: event, heard: heard, projects: projects)
    }

    func meeting(_ title: String, _ people: [String]) -> CalendarEvent {
        CalendarEvent(title: title, start: t0, end: t0 + 3600, attendees: people.map { .init(name: $0) }, hasCallLink: true)
    }

    func testCalendarAndVoicesAgree() {
        let r = fill(event: meeting("Acme: планирование", ["Анна Петрова"]),
                     heard: [HeardVoice(name: "Анна Петрова", profile: "acme", seconds: 300),
                             HeardVoice(name: "Олег", profile: "", seconds: 40)])
        XCTAssertEqual(r.info.profile, "acme")
        XCTAssertEqual(r.info.names, "Анна Петрова, Олег", "голос Анны уже есть из календаря, Олег добавлен")
        XCTAssertEqual(r.info.topic, "Acme: планирование")
        XCTAssertTrue(r.sure)
    }

    func testVoicesAloneGiveTheProject() {
        let r = fill(heard: [HeardVoice(name: "Анна Петрова", profile: "acme", seconds: 120)])
        XCTAssertEqual(r.info.profile, "acme")
        XCTAssertEqual(r.info.names, "Анна Петрова")
        XCTAssertTrue(r.sure)
    }

    func testCalendarAndVoicesDisagree() {
        let r = fill(event: meeting("Acme sync", ["Анна Петрова"]), heard: [HeardVoice(name: "Пётр", profile: "beta", seconds: 300)])
        XCTAssertEqual(r.info.profile, "acme", "календарь важнее")
        XCTAssertFalse(r.sure, "голоса говорят о другом проекте: спросить")
    }

    func testNothingKnown() {
        let r = fill()
        XCTAssertEqual(r.info, CallInfo())
        XCTAssertFalse(r.sure)
    }

    func testNoProjectNotSure() {
        let r = fill(event: meeting("Созвон", ["Иван"]))
        XCTAssertEqual(r.info.names, "Иван")
        XCTAssertEqual(r.info.profile, "")
        XCTAssertFalse(r.sure, "без проекта спросить")
    }

    func testTypedNamesStay() {
        let typed = CallInfo(profile: "beta", names: "Маша")
        let r = fill(typed, heard: [HeardVoice(name: "Анна Петрова", profile: "acme", seconds: 300)])
        XCTAssertEqual(r.info.names, "Маша", "что набрал пользователь, не трогаем")
        XCTAssertEqual(r.info.profile, "beta")
    }

    func testUnknownProjectOfAVoiceIsIgnored() {
        let r = fill(heard: [HeardVoice(name: "X", profile: "gone", seconds: 100)])
        XCTAssertEqual(r.info.profile, "")
        XCTAssertFalse(r.sure)
    }

    // The form starts with the last used project (AppDelegate.initialInfo): that is a default, not a fact about this call.

    func testLastProjectIsNotEvidence() {
        let seeded = CallInfo(profile: "acme")
        let r = fill(seeded, lastProject: "acme", heard: [HeardVoice(name: "Пётр", profile: "beta", seconds: 120)])
        XCTAssertEqual(r.info.profile, "beta", "голоса важнее прошлого проекта")
        XCTAssertTrue(r.sure)
    }

    func testLastProjectStaysAsTheFormsDefaultButIsNotSure() {
        let seeded = CallInfo(profile: "acme")
        let r = fill(seeded, lastProject: "acme", event: meeting("Созвон", ["Иван"]))
        XCTAssertEqual(r.info.profile, "acme", "в форме остаётся как раньше")
        XCTAssertFalse(r.sure, "проект никто не подтвердил")
    }

    func testProjectPickedDuringTheCallIsKept() {
        let picked = CallInfo(profile: "beta")
        let r = fill(picked, lastProject: "acme", event: meeting("Acme sync", ["Анна Петрова"]))
        XCTAssertEqual(r.info.profile, "beta", "выбранный во время звонка проект не перетирается календарём")
    }

    func testMeetingMustBeGoingOn() {
        let ev = meeting("Acme sync", ["Анна Петрова"])
        XCTAssertTrue(fill(event: ev, startedAt: t0 - 120).sure, "начали за пару минут до встречи")
        let after = fill(event: ev, startedAt: t0 + 3600 + 300)
        XCTAssertEqual(after.info.profile, "acme", "подсказка остаётся")
        XCTAssertFalse(after.sure, "звонок после конца встречи: спросить")
    }

    func testAShortVoiceMatchIsNotEnoughToSkip() {
        let r = fill(heard: [HeardVoice(name: "Анна Петрова", profile: "acme", seconds: 8)])
        XCTAssertEqual(r.info.profile, "acme")
        XCTAssertFalse(r.sure, "8 секунд совпадения мало, чтобы не спрашивать")
    }

    func testUnsureVoiceGivesTheProjectButNoNameAndNoCertainty() {
        let r = fill(event: meeting("Созвон", ["Иван"]),
                     heard: [HeardVoice(name: "Влад", profile: "acme", seconds: 600, unsure: true)], startedAt: t0 + 7200)
        XCTAssertEqual(r.info.profile, "acme", "проект у обоих имён один")
        XCTAssertEqual(r.info.names, "Иван", "имя под вопросом в участники не идёт")
        XCTAssertFalse(r.sure)
    }

    func testSameName() {
        XCTAssertTrue(CallGuess.same("Анна", "анна петрова"))
        XCTAssertTrue(CallGuess.same("Олег Иванов", "олег иванов"))
        XCTAssertFalse(CallGuess.same("Анна Петрова", "Анна Смирнова"))
    }
}

final class ReflectionTests: XCTestCase {
    func testKindIsStoredOnlyForAReflection() {
        var c: [String: Any] = [:]
        var i = CallInfo()
        i.reflection = true
        CallFile.apply(i, to: &c)
        XCTAssertEqual(c["kind"] as? String, "reflection")
        XCTAssertTrue(CallFile.info(c).reflection)
        i.reflection = false
        CallFile.apply(i, to: &c)
        XCTAssertNil(c["kind"], "a call keeps its call.json as before")
        XCTAssertFalse(CallFile.info(c).reflection)
    }

    func testAReflectionIsNeverSureEnoughToGoAheadAlone() {
        var i = CallInfo(profile: "acme", names: "Анна", topic: "мысли")
        i.reflection = true
        let r = CallGuess.fill(i, startedAt: Date(), event: nil, heard: [], projects: [Project(slug: "acme", title: "Acme")])
        XCTAssertFalse(r.sure)
    }
}
