import XCTest
@testable import SozvonCore

final class DiskHealthTests: XCTestCase {
    func testWriteHealthReportsOnce() {
        var h = WriteHealth()
        let full = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        XCTAssertEqual(h.record(error: full), .failed(full: true))
        XCTAssertNil(h.record(error: full))
        XCTAssertNil(h.record(error: full))
        XCTAssertEqual(h.record(error: nil), .recovered)
        XCTAssertNil(h.record(error: nil))
    }

    func testOtherErrorIsNotFull() {
        var h = WriteHealth()
        XCTAssertEqual(h.record(error: NSError(domain: NSOSStatusErrorDomain, code: -50)), .failed(full: false))
    }

    func testCocoaOutOfSpaceIsFull() {
        var h = WriteHealth()
        XCTAssertEqual(h.record(error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)),
                       .failed(full: true))
    }

    func testLowSpace() {
        XCTAssertTrue(DiskSpace.lowSpace(freeBytes: 999_999_999))
        XCTAssertFalse(DiskSpace.lowSpace(freeBytes: 1_000_000_000))
        XCTAssertFalse(DiskSpace.lowSpace(freeBytes: nil))
    }
}
