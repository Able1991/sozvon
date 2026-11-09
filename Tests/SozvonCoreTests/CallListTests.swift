// The Calls window's list rules: project and reflections filter, day groups; countdown seconds.

import XCTest
@testable import SozvonCore

final class CallListTests: TempDirTestCase {
    private func make(_ id: String, profile: String = "", reflection: Bool = false) throws -> Call {
        let dir = calls.appendingPathComponent(id)
        var json = #"{"schema": 1, "id": "\#(id)", "status": "done""#
        if !profile.isEmpty { json += #", "profile": "\#(profile)""# }
        if reflection { json += #", "kind": "reflection""# }
        try write(json + "}", dir.appendingPathComponent("call.json"))
        return try XCTUnwrap(Call.load(dir))
    }

    func testFilterByProjectReflectionsAndAll() throws {
        let acme = try make("2026-11-05 10-00", profile: "acme")
        let other = try make("2026-11-05 11-00", profile: "other")
        let reflection = try make("2026-11-05 12-00", reflection: true)
        let all = [acme, other, reflection]
        XCTAssertEqual(CallFilter.apply(all, filter: "").map(\.id), all.map(\.id))
        XCTAssertEqual(CallFilter.apply(all, filter: "acme").map(\.id), [acme.id])
        XCTAssertEqual(CallFilter.apply(all, filter: CallFilter.reflections).map(\.id), [reflection.id])
        XCTAssertTrue(CallFilter.apply(all, filter: "missing").isEmpty)
    }

    func testLiveCallIsShownWhateverTheFilter() throws {
        let other = try make("2026-11-05 11-00", profile: "other")
        XCTAssertFalse(CallFilter.isShown(other, filter: "acme", isLive: false))
        XCTAssertTrue(CallFilter.isShown(other, filter: "acme", isLive: true))
        XCTAssertTrue(CallFilter.isShown(other, filter: "", isLive: false))
        XCTAssertTrue(CallFilter.isShown(other, filter: "other", isLive: false))
    }

    func testReflectionsFilterDoesNotMatchProfileOfThatName() throws {
        let c = try make("2026-11-05 11-00", profile: CallFilter.reflections)
        XCTAssertFalse(CallFilter.matches(c, filter: CallFilter.reflections), "only kind=reflection counts")
    }

    func testDayGroupsKeepOrderAndLabels() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let now = try XCTUnwrap(Call.parseID("2026-11-05 18-00"))
        let t1 = try make("2026-11-05 10-00")
        let t2 = try make("2026-11-05 09-00")
        let y = try make("2026-11-04 23-59")
        let old = try make("2026-10-01 08-00")
        let undated = try make("no-date-folder")
        let labels = CallDays.Labels(today: "Today", yesterday: "Yesterday", undated: "Undated") { _ in "OLD" }
        let groups = CallDays.group([t1, t2, y, old, undated], now: now, calendar: cal, labels: labels)
        XCTAssertEqual(groups.map(\.0), ["Today", "Yesterday", "OLD", "Undated"])
        XCTAssertEqual(groups[0].1.map(\.id), [t1.id, t2.id], "order inside a day is the input order")
        XCTAssertEqual(groups[3].1.map(\.id), [undated.id])
    }

    func testDayGroupsOfEmptyList() {
        let labels = CallDays.Labels(today: "T", yesterday: "Y", undated: "U") { _ in "D" }
        XCTAssertTrue(CallDays.group([], now: Date(), calendar: .current, labels: labels).isEmpty)
    }

    func testMidnightBoundary() throws {
        let cal = Calendar.current
        let now = try XCTUnwrap(Call.parseID("2026-11-05 00-01"))
        let justBefore = try make("2026-11-04 23-59")
        let labels = CallDays.Labels(today: "Today", yesterday: "Yesterday", undated: "U") { _ in "D" }
        XCTAssertEqual(CallDays.group([justBefore], now: now, calendar: cal, labels: labels).map(\.0), ["Yesterday"])
    }
}

final class CountdownTests: XCTestCase {
    func testSecondsRoundUp() {
        XCTAssertEqual(Countdown.seconds(left: 9.2), 10)
        XCTAssertEqual(Countdown.seconds(left: 10), 10)
        XCTAssertEqual(Countdown.seconds(left: 0.01), 1)
        XCTAssertEqual(Countdown.seconds(left: 0), 0)
        XCTAssertEqual(Countdown.seconds(left: -3.5), -3)
    }

    func testStartTick() {
        let now = Date(timeIntervalSince1970: 1000)
        var t = Countdown.startTick(deadline: now.addingTimeInterval(9.5), now: now)
        XCTAssertEqual(t.shown, 10)
        XCTAssertFalse(t.due)
        t = Countdown.startTick(deadline: now.addingTimeInterval(0.2), now: now)
        XCTAssertEqual(t.shown, 1)
        XCTAssertFalse(t.due)
        t = Countdown.startTick(deadline: now, now: now)
        XCTAssertEqual(t.shown, 0)
        XCTAssertTrue(t.due)
        t = Countdown.startTick(deadline: now.addingTimeInterval(-4), now: now)
        XCTAssertEqual(t.shown, 0, "never negative on screen")
        XCTAssertTrue(t.due)
    }
}
