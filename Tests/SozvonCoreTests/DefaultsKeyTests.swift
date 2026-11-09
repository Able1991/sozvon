import XCTest
@testable import SozvonCore

/// These strings are already stored in users' preferences: renaming one would silently reset the setting.
final class DefaultsKeyTests: XCTestCase {
    func testStoredKeyNamesStayTheSame() {
        XCTAssertEqual(DefaultsKey.lastProfile, "lastProfile")
        XCTAssertEqual(DefaultsKey.setupResumeStep, "setupResumeStep")
        XCTAssertEqual(DefaultsKey.callsProject, "callsProject")
    }
}
