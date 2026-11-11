// The capsule: when a press becomes a window drag (handed to the system) and when it stays a click.

import XCTest
@testable import SozvonCore

final class PanelDragTests: XCTestCase {
    func testAPressThatBarelyMovesStaysAClick() {
        XCTAssertFalse(PanelDrag.moved(CGPoint(x: 100, y: 100), CGPoint(x: 102, y: 97)))
    }

    func testMovingMoreThanThreePointsIsADrag() {
        XCTAssertTrue(PanelDrag.moved(CGPoint(x: 100, y: 100), CGPoint(x: 104, y: 100)))
        XCTAssertTrue(PanelDrag.moved(CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 96)))
    }

    func testAFastFlickFarOutsideTheCapsuleIsStillADrag() {
        XCTAssertTrue(PanelDrag.moved(CGPoint(x: 100, y: 100), CGPoint(x: 900, y: 40)))
    }

    func testNoPressNoDrag() {
        XCTAssertFalse(PanelDrag.moved(nil, CGPoint(x: 900, y: 40)))
        XCTAssertFalse(PanelDrag.moved(CGPoint(x: 1, y: 1), nil))
    }
}
