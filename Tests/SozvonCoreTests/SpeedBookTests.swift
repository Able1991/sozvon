import XCTest
@testable import SozvonCore

final class SpeedBookTests: XCTestCase {
    func testIgnoresShortCallsAndKeepsLastTen() {
        var b = SpeedBook()
        b.record(model: "turbo", callSeconds: 599, processingSeconds: 100)
        XCTAssertNil(b.factor(model: "turbo"))
        for i in 1...11 { b.record(model: "turbo", callSeconds: 600, processingSeconds: Double(i) * 60) }
        XCTAssertEqual(b.factor(model: "turbo")!, (2...11).map { Double($0) / 10 }.reduce(0, +) / 10, accuracy: 1e-9)
        XCTAssertEqual(b.estimate(model: "turbo", callSeconds: 1200)!, 1200 * b.factor(model: "turbo")!, accuracy: 1e-9)
        XCTAssertNil(b.estimate(model: "large-v3", callSeconds: 1200))
        XCTAssertEqual(b.lastModel, "turbo")
    }

    func testRejectsNonPositiveProcessingAndSurvivesJSON() throws {
        var b = SpeedBook()
        b.record(model: "turbo", callSeconds: 900, processingSeconds: 0)
        XCTAssertNil(b.lastModel)
        b.record(model: "turbo", callSeconds: 900, processingSeconds: 450)
        let back = try JSONDecoder().decode(SpeedBook.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back.factor(model: "turbo"), 0.5)
        XCTAssertEqual(back.lastModel, "turbo")
    }

    func testEstimateText() {
        XCTAssertEqual(EstimateText.duration(90), "≈ 1 мин")
        XCTAssertEqual(EstimateText.duration(12 * 60 + 20), "≈ 12 мин")
        XCTAssertEqual(EstimateText.duration(70 * 60), "≈ 1 ч 10 мин")
        XCTAssertEqual(EstimateText.duration(3600), "≈ 1 ч", "no \"0 мин\"")
        XCTAssertEqual(EstimateText.duration(2 * 3600 + 10), "≈ 2 ч")
        XCTAssertEqual(EstimateText.duration(3540), "≈ 59 мин")
        for s in [3570.0, 3585, 3599] {
            XCTAssertEqual(EstimateText.duration(s), "≈ 1 ч", "\(s) s rounds up to the hour, never \"≈ 60 мин\"")
        }
        XCTAssertEqual(EstimateText.duration(119), "≈ 1 мин")
        XCTAssertEqual(EstimateText.duration(20), "≈ 1 мин")
        XCTAssertEqual(EstimateText.remaining(estimate: 300, elapsed: 400), "почти готово")
        XCTAssertEqual(EstimateText.remaining(estimate: 900, elapsed: 300), "осталось ≈ 10 мин")
    }
}
