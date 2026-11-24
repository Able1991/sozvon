import XCTest
@testable import SozvonCore

final class SleepGuardTests: XCTestCase {
    func testHoldsWhileRecordingOrWorking() {
        var begun = 0, ended = 0
        let g = SleepGuard(begin: { _ in begun += 1; return NSObject() }, end: { _ in ended += 1 })
        g.update(recording: true, hasWork: false); g.update(recording: true, hasWork: true)
        XCTAssertEqual(begun, 1); XCTAssertTrue(g.isHeld); XCTAssertEqual(ended, 0)
    }

    func testReleasedWhenNothingNeedsIt() {
        var ended = 0
        let g = SleepGuard(begin: { _ in NSObject() }, end: { _ in ended += 1 })
        g.update(recording: false, hasWork: true); g.update(recording: false, hasWork: false)
        g.update(recording: false, hasWork: false)
        XCTAssertEqual(ended, 1); XCTAssertFalse(g.isHeld)
    }

    func testTakesAgainAfterRelease() {
        var begun = 0
        let g = SleepGuard(begin: { _ in begun += 1; return NSObject() }, end: { _ in })
        g.update(recording: true, hasWork: false); g.update(recording: false, hasWork: false)
        g.update(recording: false, hasWork: true)
        XCTAssertEqual(begun, 2); XCTAssertTrue(g.isHeld)
    }
}
