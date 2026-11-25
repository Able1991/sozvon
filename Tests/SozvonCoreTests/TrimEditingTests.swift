// The trim panel's state machine: the keys, Cancel and Escape in each phase.

import XCTest
@testable import SozvonCore

final class TrimEditingTests: XCTestCase {
    func testArrowsMoveTheTakenHandleByOneOrTenSeconds() {
        var s = TrimState(start: 372, end: 3520)
        XCTAssertEqual(s.key(.right, shift: false, handle: .start, duration: 3900), .moved(.start))
        XCTAssertEqual(s.start, 373)
        XCTAssertEqual(s.key(.right, shift: true, handle: .start, duration: 3900), .moved(.start))
        XCTAssertEqual(s.start, 383)
        XCTAssertEqual(s.key(.left, shift: false, handle: .end, duration: 3900), .moved(.end))
        XCTAssertEqual(s.end, 3519)
        XCTAssertEqual(s.key(.left, shift: true, handle: .end, duration: 3900), .moved(.end))
        XCTAssertEqual(s.end, 3509)
        XCTAssertEqual(s.phase, .editing)
    }

    func testArrowsFromTheWholeCallMoveTheStartOffZero() {
        // The Calls window opens the panel on the whole call: the start handle at 0:00 moves right.
        var s = TrimState(duration: 1363, hint: nil)
        XCTAssertEqual(s.start, 0); XCTAssertEqual(s.end, 1363)
        _ = s.key(.right, shift: false, handle: .start, duration: 1363)
        XCTAssertEqual(s.start, 1)
        _ = s.key(.left, shift: false, handle: .end, duration: 1363)
        XCTAssertEqual(s.end, 1362)
    }

    func testHandlesStayInsideTheCallAndKeepTheMinimumRange() {
        var s = TrimState(start: 0, end: 100)
        _ = s.key(.left, shift: true, handle: .start, duration: 100)
        XCTAssertEqual(s.start, 0)
        _ = s.key(.right, shift: true, handle: .end, duration: 100)
        XCTAssertEqual(s.end, 100)
        s.set(.start, to: 95, duration: 100)
        XCTAssertEqual(s.start, 100 - Trim.minRangeSeconds)
        s.set(.end, to: 0, duration: 100)
        XCTAssertEqual(s.end, 100)
        s = TrimState(start: 20, end: 100)
        s.set(.end, to: 0, duration: 100)
        XCTAssertEqual(s.end, 20 + Trim.minRangeSeconds)
    }

    func testArrowsDoNothingOutsideEditing() {
        for phase in [TrimState.Phase.confirming, .working] {
            var s = TrimState(start: 10, end: 50, phase: phase)
            XCTAssertEqual(s.key(.right, shift: false, handle: .start, duration: 60), .ignored)
            XCTAssertEqual(s, TrimState(start: 10, end: 50, phase: phase))
        }
    }

    func testCancelInTheConfirmationGoesBackToEditing() {
        var s = TrimState(start: 10, end: 50, phase: .confirming)
        XCTAssertEqual(s.cancel(), .backToEditing)
        XCTAssertEqual(s.phase, .editing)
        XCTAssertEqual(s.start, 10); XCTAssertEqual(s.end, 50)
    }

    func testCancelWhileEditingClosesThePanel() {
        var s = TrimState(start: 10, end: 50)
        XCTAssertEqual(s.cancel(), .close)
        XCTAssertEqual(s.phase, .editing)
    }

    func testTheCutCannotBeCancelled() {
        var s = TrimState(start: 10, end: 50, phase: .working)
        XCTAssertEqual(s.cancel(), .none)
        XCTAssertEqual(s.phase, .working)
    }

    func testEscapeIsCancel() {
        var s = TrimState(start: 10, end: 50, phase: .confirming)
        XCTAssertEqual(s.key(.escape, shift: false, handle: .start, duration: 60), .cancel(.backToEditing))
        XCTAssertEqual(s.key(.escape, shift: false, handle: .start, duration: 60), .cancel(.close))
        s.phase = .working
        XCTAssertEqual(s.key(.escape, shift: false, handle: .end, duration: 60), .ignored)
    }
}
