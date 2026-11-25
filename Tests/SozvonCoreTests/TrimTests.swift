// Trim a recording: when it is unavailable and where the silence hint puts the handles.

import XCTest
@testable import SozvonCore

final class TrimTests: XCTestCase {
    func testHintFromSilence() {
        let c: [String: Any] = ["silence": ["head": 372.0, "tail": 10.0]]
        let h = Trim.hint(call: c, duration: 3600)!
        XCTAssertEqual(h.start, 370); XCTAssertEqual(h.end, 3600)
        XCTAssertNil(Trim.hint(call: ["silence": ["head": 59.0, "tail": 59.0]], duration: 3600))
        XCTAssertNil(Trim.hint(call: ["silence": ["head": 372.0, "tail": 0.0], "trim_hint_dismissed": true], duration: 3600))
        XCTAssertNil(Trim.hint(call: [:], duration: 3600))
    }

    func testHintTailAndBoth() {
        let t = Trim.hint(call: ["silence": ["head": 5.0, "tail": 300.0]], duration: 1000)!
        XCTAssertEqual(t.start, 0); XCTAssertEqual(t.end, 702)
        let b = Trim.hint(call: ["silence": ["head": 60.0, "tail": 60.0]], duration: 1000)!
        XCTAssertEqual(b.start, 58); XCTAssertEqual(b.end, 942)
        // Silence longer than the call: the handles stay inside it, or no hint.
        XCTAssertNil(Trim.hint(call: ["silence": ["head": 1.0, "tail": 100.0]], duration: 50))
    }

    func testUnavailableReasons() {
        XCTAssertEqual(Trim.unavailable(call: ["status": "done"], hasAudio: true, busy: true), .busy)
        XCTAssertEqual(Trim.unavailable(call: ["audio_removed_at": "2026-11-01T00:00:00Z"], hasAudio: false, busy: false), .audioRemoved)
        XCTAssertEqual(Trim.unavailable(call: ["demo": true], hasAudio: false, busy: false), .demo)
        XCTAssertEqual(Trim.unavailable(call: ["audio": ["mic_seconds": 20.0]], hasAudio: true, busy: false), .tooShort)
        XCTAssertNil(Trim.unavailable(call: ["status": "recorded", "audio": ["mic_seconds": 1800.0]], hasAudio: true, busy: false))
    }

    func testUnavailablePrecedenceAndDuration() {
        let all: [String: Any] = ["demo": true, "audio_removed_at": "x", "audio": ["mic_seconds": 5.0]]
        XCTAssertEqual(Trim.unavailable(call: all, hasAudio: false, busy: true), .busy)
        XCTAssertEqual(Trim.unavailable(call: all, hasAudio: false, busy: false), .demo)
        var c = all; c["demo"] = nil
        XCTAssertEqual(Trim.unavailable(call: c, hasAudio: false, busy: false), .audioRemoved)
        c["audio_removed_at"] = nil
        XCTAssertEqual(Trim.unavailable(call: c, hasAudio: false, busy: false), .noAudio)
        // The longer track decides: 40 s on the system track is long enough.
        XCTAssertNil(Trim.unavailable(call: ["audio": ["mic_seconds": 5.0, "system_seconds": 40.0]], hasAudio: true, busy: false))
        XCTAssertFalse(TrimUnavailable.busy.reason.isEmpty)
    }

    func testHintMinutesForTheBanner() {
        let c: [String: Any] = ["silence": ["head": 372.0, "tail": 30.0]]
        XCTAssertEqual(Trim.hintMinutes(call: c).head, 6)
        XCTAssertEqual(Trim.hintMinutes(call: c).tail, 0)
        XCTAssertEqual(Trim.hintMinutes(call: ["silence": ["head": 60.0, "tail": 245.0]]).head, 1)
        XCTAssertEqual(Trim.hintMinutes(call: ["silence": ["head": 60.0, "tail": 245.0]]).tail, 4)
        XCTAssertEqual(Trim.hintMinutes(call: [:]).head, 0)
    }
}

final class CallTrimTests: TempDirTestCase {
    func testCallCarriesTrimStateFromCallJSON() throws {
        let dir = calls.appendingPathComponent("2026-11-05 10-00")
        try write(#"{"schema": 1, "id": "2026-11-05 10-00", "status": "done", "audio": {"mic_seconds": 3600.0}, "silence": {"head": 372.0, "tail": 0.0}}"#,
                  dir.appendingPathComponent("call.json"))
        try write("x", dir.appendingPathComponent("mic.m4a"))
        let c = try XCTUnwrap(Call.load(dir))
        XCTAssertNil(c.trimUnavailable(busy: false))
        XCTAssertEqual(c.trimUnavailable(busy: true), .busy)
        XCTAssertEqual(c.trimHint?.start, 370)
        XCTAssertEqual(c.trimHint?.end, 3600)
        XCTAssertEqual(c.trimHint?.headMinutes, 6)
        XCTAssertEqual(c.trimHint?.tailMinutes, 0)

        let short = calls.appendingPathComponent("2026-11-05 11-00")
        try write(#"{"schema": 1, "id": "2026-11-05 11-00", "status": "done", "audio": {"mic_seconds": 20.0}}"#,
                  short.appendingPathComponent("call.json"))
        try write("x", short.appendingPathComponent("mic.m4a"))
        let s = try XCTUnwrap(Call.load(short))
        XCTAssertEqual(s.trimUnavailable(busy: false), .tooShort)
        XCTAssertNil(s.trimHint)
    }
}
