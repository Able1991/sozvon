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

final class SummaryPiecesTests: XCTestCase {
    func testLinesBecomePieces() {
        let lines = ["Intro", "- one", "* two", "- [ ] Anna: send it", "- [x] done thing", "### Detail", "- three", "tail"]
        XCTAssertEqual(SummaryBlocks.pieces(lines), [
            .paragraph("Intro"),
            .bullets(["one", "two"]),
            .task(ActionItem(owner: "Anna", task: "send it")),
            .task(ActionItem(owner: "", task: "done thing", done: true)),
            .heading("Detail"),
            .bullets(["three"]),
            .paragraph("tail"),
        ])
    }

    /// The Calls window used to parse every task line through a one-line "## Tasks" section.
    func testTaskLineMatchesTheSectionParser() {
        for line in ["- [ ] Anna: send it, Friday", "- [X] Me: ship", "- [ ] no owner here", "- [ ] ", "- [x]  "] {
            let viaSection = ActionItems.parse("## Tasks\n" + line).first
            let piece = SummaryBlocks.pieces([line]).first
            if let viaSection { XCTAssertEqual(piece, .task(viaSection), line) } else { XCTAssertNil(piece, line) }
        }
    }

    func testEmpty() {
        XCTAssertEqual(SummaryBlocks.pieces([]), [])
    }
}
