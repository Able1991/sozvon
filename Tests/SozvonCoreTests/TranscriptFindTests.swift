// Find inside a transcript: what matches, in what order, and how Next and Previous wrap.

import XCTest
@testable import SozvonCore

final class TranscriptFindTests: XCTestCase {
    private func found(_ q: String, _ lines: [String]) -> [(Int, String)] {
        TranscriptFind.matches(q, in: lines).map { ($0.line, String(lines[$0.line][$0.range])) }
    }

    func testFindsEveryOccurrenceInReadingOrder() {
        let r = found("счёт", ["один счёт и ещё счёт", "нет", "Счёт третий"])
        XCTAssertEqual(r.map(\.0), [0, 0, 2])
        XCTAssertEqual(r.map(\.1), ["счёт", "счёт", "Счёт"], "the matched text is the transcript's own")
    }

    func testIgnoresCaseAndTheDotsOfYo() {
        XCTAssertEqual(found("счет", ["Счёт"]).count, 1)
        XCTAssertEqual(found("СЧЁТ", ["счет"]).count, 1)
    }

    func testBlankQueryFindsNothing() {
        XCTAssertTrue(found("", ["text"]).isEmpty)
        XCTAssertTrue(found("   ", ["a  b"]).isEmpty)
    }

    func testSurroundingSpacesInTheQueryDoNotCount() {
        XCTAssertEqual(found(" ключ ", ["ключи"]).count, 1)
    }

    func testTheEngineStarIsNotText() {
        XCTAssertTrue(found("⭐", ["важно \u{2B50}"]).isEmpty)
    }

    func testNextAndPreviousWrapAround() {
        XCTAssertEqual(TranscriptFind.step(from: 2, by: 1, count: 3), 0)
        XCTAssertEqual(TranscriptFind.step(from: 0, by: -1, count: 3), 2)
        XCTAssertEqual(TranscriptFind.step(from: 1, by: 1, count: 3), 2)
        XCTAssertEqual(TranscriptFind.step(from: 5, by: 1, count: 0), 0, "nothing found")
    }
}
