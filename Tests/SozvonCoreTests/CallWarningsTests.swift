// call.json "warnings": steps that failed on the last run (contract section 4).

import XCTest
@testable import SozvonCore

final class CallWarningsTests: TempDirTestCase {
    func testParsesKnownStepsAndSkipsTheRest() {
        let c: [String: Any] = ["warnings": [
            ["step": "summary", "error": "claude: rate limit"],
            ["step": "names", "error": "timed out"],
            ["step": "future", "error": "x"],       // unknown step: ignored
            ["step": "summary"],                    // no error text: kept with an empty reason
            "junk", 3,
        ] as [Any]]
        let w = CallWarnings.list(c)
        XCTAssertEqual(w.map(\.step), [.summary, .names, .summary])
        XCTAssertEqual(w[0].error, "claude: rate limit")
        XCTAssertEqual(w[2].error, "")
        XCTAssertEqual(CallWarnings.summary(c), "claude: rate limit")
    }

    func testAbsentOrBrokenFieldIsNoWarnings() {
        XCTAssertTrue(CallWarnings.list([:]).isEmpty)
        XCTAssertTrue(CallWarnings.list(["warnings": "oops"]).isEmpty)
        XCTAssertTrue(CallWarnings.list(["warnings": [] as [Any]]).isEmpty)
        XCTAssertNil(CallWarnings.summary(["warnings": [["step": "names", "error": "x"]]]))
    }

    func testOneLineReasonForANotification() {
        let c: [String: Any] = ["warnings": [["step": "summary", "error": "line one\nline two"]]]
        XCTAssertEqual(CallWarnings.summary(c), "line one line two")
    }

    func testCallCarriesTheSummaryWarning() throws {
        let dir = calls.appendingPathComponent("2026-11-04 15-04")
        try write(#"{"schema": 1, "id": "2026-11-04 15-04", "status": "done", "warnings": [{"step": "summary", "error": "down"}]}"#,
                  dir.appendingPathComponent("call.json"))
        let call = try XCTUnwrap(Call.load(dir))
        XCTAssertEqual(call.summaryWarning, "down")
        try write(#"{"schema": 1, "id": "2026-11-04 15-04", "status": "done"}"#, dir.appendingPathComponent("call.json"))
        XCTAssertNil(try XCTUnwrap(Call.load(dir)).summaryWarning)
    }
}
