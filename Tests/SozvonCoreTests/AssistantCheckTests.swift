import XCTest
@testable import SozvonCore

/// The last line of `bin/check_assistant.py`: whether the chosen assistant answered, and what it said.
final class AssistantCheckTests: XCTestCase {
    func testAnAnswerIsOK() {
        XCTAssertEqual(AssistantCheck.parse(["something", "RESULT: ok OK"], code: 0), .ok)
    }

    func testAnErrorKeepsTheAssistantsOwnWords() {
        let line = "RESULT: error Error: sandbox is enabled but not available on this system. Sandbox is unavailable"
        XCTAssertEqual(AssistantCheck.parse([line], code: 1),
                       .failed("Error: sandbox is enabled but not available on this system. Sandbox is unavailable"))
    }

    func testNoResultLineIsAFailureWithTheLastLine() {
        XCTAssertEqual(AssistantCheck.parse(["Traceback", "ModuleNotFoundError: x"], code: 3),
                       .failed("ModuleNotFoundError: x"))
        XCTAssertEqual(AssistantCheck.parse([], code: 1), .failed(""))
    }
}
