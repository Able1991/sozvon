// Summary cards of the Calls window.

import XCTest
@testable import SozvonCore

final class SummaryBlocksTests: XCTestCase {
    func testSectionsBecomeBlocks() {
        let md = """
        Intro line.

        ## Summary
        Agreed on webhooks.

        ## Decisions
        - One
        - Two
        ### Detail
        ---

        ## Empty
        """
        XCTAssertEqual(SummaryBlocks.split(md), [
            SummaryBlock(title: "", lines: ["Intro line."]),
            SummaryBlock(title: "Summary", lines: ["Agreed on webhooks."]),
            SummaryBlock(title: "Decisions", lines: ["- One", "- Two", "### Detail"]),
            SummaryBlock(title: "Empty", lines: []),
        ])
    }

    func testEmpty() {
        XCTAssertEqual(SummaryBlocks.split(""), [])
        XCTAssertEqual(SummaryBlocks.split("\n---\n"), [])
    }
}
