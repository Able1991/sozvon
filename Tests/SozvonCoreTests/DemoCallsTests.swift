// Demo calls (Settings > Assistants): fictional calls to try the assistant tools before the first recording.

import XCTest
@testable import SozvonCore

final class DemoCallsTests: TempDirTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)  // a fixed "now"

    private func realCall(_ id: String) throws -> URL {
        let d = calls.appendingPathComponent(id)
        try write("{\"schema\":1,\"id\":\"\(id)\",\"status\":\"done\"}", d.appendingPathComponent("call.json"))
        try write("[00:01] Я: привет\n", d.appendingPathComponent("transcript.txt"))
        return d
    }

    func testAddWritesMarkedCallsWithTextAndNoAudio() throws {
        let added = try DemoCalls.add(to: calls, now: now)
        XCTAssertEqual(added.count, DemoCalls.specs.count)
        XCTAssertGreaterThanOrEqual(added.count, 3)
        for dir in added {
            let c = CallFile.read(dir)
            XCTAssertEqual(c["demo"] as? Bool, true)
            XCTAssertEqual(c["status"] as? String, "done")
            XCTAssertEqual(c["schema"] as? Int, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.md").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.txt").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertFalse(files.contains { $0.hasSuffix(".m4a") }, "no audio")
            let call = try XCTUnwrap(Call.load(dir))
            XCTAssertTrue(call.isDemo)
            XCTAssertTrue(call.hasTranscript && call.hasSummary && !call.hasAudio)
            XCTAssertGreaterThan(call.duration, 0)
        }
    }

    func testNoProjectsAndNoVoicesAreCreated() throws {
        let added = try DemoCalls.add(to: calls, now: now)
        for dir in added { XCTAssertEqual(CallFile.read(dir)["profile"] as? String ?? "", "") }
        let items = try FileManager.default.contentsOfDirectory(atPath: data.path)
        XCTAssertTrue(items.isEmpty, "nothing outside the calls folder: \(items)")
    }

    func testDatesAreRelativeToNowAndInThePast() throws {
        let added = try DemoCalls.add(to: calls, now: now)
        let dates = try added.map { try XCTUnwrap(Call.parseID(CallFile.callID($0))) }
        XCTAssertTrue(dates.allSatisfy { $0 < now })
        XCTAssertTrue(dates.allSatisfy { now.timeIntervalSince($0) < 4 * 86_400 }, "a recent few days")
        let later = now.addingTimeInterval(10 * 86_400)
        let again = try DemoCalls.add(to: calls, now: later)
        XCTAssertTrue(again.isEmpty, "already added: nothing doubles")
        try DemoCalls.remove(in: calls) { _ in }
        let shifted = try DemoCalls.add(to: calls, now: later)
        let d2 = try shifted.map { try XCTUnwrap(Call.parseID(CallFile.callID($0))) }
        XCTAssertTrue(d2.allSatisfy { $0 > now.addingTimeInterval(5 * 86_400) }, "shifted with the moment of adding")
    }

    func testTranscriptsAndSummariesFeedTheAssistantTools() throws {
        let added = try DemoCalls.add(to: calls, now: now)
        let all = try added.map { try String(contentsOf: $0.appendingPathComponent("summary.md")) }.joined()
        XCTAssertTrue(all.contains("- [ ] "), "open commitments for get_commitments")
        for dir in added {
            let t = try String(contentsOf: dir.appendingPathComponent("transcript.txt"))
            XCTAssertTrue(t.hasPrefix("[00:"), "engine transcript format")
            XCTAssertFalse((CallFile.read(dir)["participants"] as? [String] ?? CallFile.read(dir)["names"] as? [String] ?? []).isEmpty)
        }
    }

    func testRemoveTouchesOnlyDemoCalls() throws {
        let real = try realCall("2026-11-01 10-00")
        let legacy = calls.appendingPathComponent("2026-10-01 09-00 · Acme")  // no call.json
        try write("x", legacy.appendingPathComponent("transcript.md"))
        let almost = calls.appendingPathComponent("2026-10-02 09-00")  // "demo": "true" is not demo
        try write("{\"id\":\"2026-10-02 09-00\",\"demo\":\"true\"}", almost.appendingPathComponent("call.json"))
        let added = try DemoCalls.add(to: calls, now: now)
        XCTAssertEqual(Set(DemoCalls.existing(in: calls).map(\.lastPathComponent)), Set(added.map(\.lastPathComponent)))

        var moved: [URL] = []
        try DemoCalls.remove(in: calls) { moved.append($0) }
        XCTAssertEqual(Set(moved.map(\.lastPathComponent)), Set(added.map(\.lastPathComponent)))
        XCTAssertFalse(moved.contains { $0.lastPathComponent == real.lastPathComponent })
    }

    func testRemoveWithRealFileMoveLeavesTheRest() throws {
        let real = try realCall("2026-11-01 10-00")
        try DemoCalls.add(to: calls, now: now)
        let bin = tmp.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try DemoCalls.remove(in: calls) { try FileManager.default.moveItem(at: $0, to: bin.appendingPathComponent($0.lastPathComponent)) }
        XCTAssertTrue(DemoCalls.existing(in: calls).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: calls.path), [real.lastPathComponent])
    }

    func testDemoDoesNotTouchRealCallFiles() throws {
        let real = try realCall("2026-11-01 10-00")
        let before = try Data(contentsOf: real.appendingPathComponent("call.json"))
        try DemoCalls.add(to: calls, now: now)
        XCTAssertEqual(try Data(contentsOf: real.appendingPathComponent("call.json")), before)
        XCTAssertFalse(DemoCalls.isDemo(CallFile.read(real)))
    }

    func testRealCallOnTheSameMinuteKeepsItsFolder() throws {
        let first = try DemoCalls.add(to: calls, now: now)
        let id = CallFile.callID(first[0])
        let clash = try CallFolder.create(in: calls, at: try XCTUnwrap(Call.parseID(id)))
        XCTAssertNotEqual(clash.lastPathComponent, first[0].lastPathComponent)
    }
}
