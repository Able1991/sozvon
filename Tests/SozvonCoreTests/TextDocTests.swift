// Selectable summary and transcript: the text one text view shows, what Copy puts on the clipboard, which
// paragraph a character belongs to, and when a click plays instead of selecting.

import XCTest
@testable import SozvonCore

final class TranscriptTextTests: XCTestCase {
    private let lines = [
        TranscriptLine(start: 3, speaker: "Anna", text: "Hi Sarah."),
        TranscriptLine(start: 72, speaker: "Tom Baker", text: "Works for me. \u{2B50}"),
        TranscriptLine(start: 0, speaker: "Speaker 2", text: "Ёлка 🎄 тут"),
    ]

    private func doc(voiced: Set<String> = []) -> TextDoc {
        TranscriptText.build([.other("## Расшифровка"), .line(lines[0]), .other("---"), .line(lines[1]), .line(lines[2])],
                             me: "Anna", voiced: voiced)
    }

    func testShowsTimeNameAndTextWithoutTheStar() {
        let d = doc()
        XCTAssertEqual(d.string, "Расшифровка\n\t0:03\tAnna: Hi Sarah.\n\t1:12\tTom Baker: Works for me.\n\t0:00\tSpeaker 2: Ёлка 🎄 тут")
        XCTAssertEqual(d.paragraphs.map(\.kind), [
            .heading,
            .line(ordinal: 0, occurrence: 0, starred: false),
            .line(ordinal: 1, occurrence: 0, starred: true),
            .line(ordinal: 2, occurrence: 0, starred: false),
        ], "--- is dropped")
    }

    func testCopyKeepsTheTranscriptFormat() {
        let d = doc()
        XCTAssertEqual(d.copyText(NSRange(location: 0, length: d.length)),
                       "Расшифровка\n[0:03] Anna: Hi Sarah.\n[1:12] Tom Baker: Works for me.\n[0:00] Speaker 2: Ёлка 🎄 тут")
    }

    func testCopyOfPartOfALineIsJustThoseWords() {
        let d = doc()
        let r = (d.string as NSString).range(of: "Sarah")
        XCTAssertEqual(d.copyText(r), "Sarah")
    }

    func testTimeTouchedBySelectionIsCopiedWhole() {
        let d = doc()
        // From the middle of "1:12" to the end of "Tom".
        let t = (d.string as NSString).range(of: "1:12")
        let tom = (d.string as NSString).range(of: "Tom")
        XCTAssertEqual(d.copyText(NSRange(location: t.location + 2, length: NSMaxRange(tom) - t.location - 2)), "[1:12] Tom")
    }

    func testSelectionAcrossParagraphs() {
        let d = doc()
        let from = (d.string as NSString).range(of: "Sarah").location
        let to = NSMaxRange((d.string as NSString).range(of: "Works"))
        XCTAssertEqual(d.copyText(NSRange(location: from, length: to - from)), "Sarah.\n[1:12] Tom Baker: Works")
    }

    func testParagraphOfACharacter() {
        let d = doc()
        let ns = d.string as NSString
        XCTAssertEqual(d.paragraph(at: 0), 0)
        XCTAssertEqual(d.paragraph(at: ns.range(of: "Hi").location), 1)
        XCTAssertEqual(d.paragraph(at: ns.range(of: "1:12").location), 2)
        XCTAssertEqual(d.paragraph(at: ns.range(of: "тут").location), 3)
        XCTAssertNil(d.paragraph(at: d.length + 5))
        XCTAssertEqual(d.paragraph(forLine: 1), 2)
        XCTAssertNil(d.paragraph(forLine: 7))
    }

    func testSegmentOfACharacter() {
        let d = doc()
        let at = (d.string as NSString).range(of: "1:12").location
        XCTAssertEqual(d.segment(containing: at)?.segment.role, .time)
        XCTAssertEqual(d.segment(containing: at)?.range, NSRange(location: at - 1, length: 6))
        XCTAssertNil(d.segment(containing: -1))
    }

    func testUnconfirmedSpeakers() {
        func roles(_ d: TextDoc) -> [TextDoc.Role] { d.segments.map(\.role).filter { if case .speaker = $0 { true } else { false } } }
        XCTAssertEqual(roles(doc()), [.speaker(unconfirmed: false), .speaker(unconfirmed: true), .speaker(unconfirmed: false)],
                       "the user and generic labels keep the label color")
        XCTAssertEqual(roles(doc(voiced: ["tom baker"])), [.speaker(unconfirmed: false), .speaker(unconfirmed: false),
                                                          .speaker(unconfirmed: false)])
    }

    func testEqualLinesCountOccurrences() {
        let l = TranscriptLine(start: 5, speaker: "A", text: "ok")
        let d = TranscriptText.build([.line(l), .line(l)], me: "", voiced: [])
        XCTAssertEqual(d.paragraphs.map(\.kind), [.line(ordinal: 0, occurrence: 0, starred: false),
                                                  .line(ordinal: 1, occurrence: 1, starred: false)])
    }

    func testFindMatchesMapToTheShownText() {
        let d = doc()
        let texts = lines.map(\.text)
        for (q, expect) in [("sarah", "Sarah"), ("елка", "Ёлка"), ("тут", "тут"), ("me", "me")] {
            let m = TranscriptFind.matches(q, in: texts)
            XCTAssertFalse(m.isEmpty, q)
            for match in m {
                let r = TranscriptText.range(of: match, lines: lines, in: d)
                XCTAssertEqual(r.map { (d.string as NSString).substring(with: $0) }, expect, q)
            }
        }
    }

    func testEmpty() {
        let d = TranscriptText.build([], me: "", voiced: [])
        XCTAssertEqual(d.string, "")
        XCTAssertEqual(d.copyText(NSRange(location: 0, length: 0)), "")
        XCTAssertNil(d.paragraph(at: 0))
    }
}

final class SummaryTextTests: XCTestCase {
    private let md = """
    Intro with a [link](https://example.com).

    ## Decisions
    - Use **HMAC** in `X-Signature`
    - Three retries
    ### Detail
    Plain line.

    ## Action Items
    - [ ] Anna: send the keys
    - [x] check the docs
    """

    func testShowsTheSummaryAsText() {
        let d = SummaryText.build(SummaryBlocks.split(md))
        XCTAssertEqual(d.string, """
        Intro with a link.
        Decisions
        •\tUse HMAC in X-Signature
        •\tThree retries
        Detail
        Plain line.
        Action Items
        \tsend the keys
        \tcheck the docs
        """)
        XCTAssertEqual(d.paragraphs.map(\.kind), [
            .text(block: 0, line: .paragraph),
            .title(block: 1),
            .text(block: 1, line: .bullet(first: true, last: false)),
            .text(block: 1, line: .bullet(first: false, last: true)),
            .text(block: 1, line: .subheading),
            .text(block: 1, line: .paragraph),
            .title(block: 2),
            .text(block: 2, line: .task(owner: "Anna", done: false)),
            .text(block: 2, line: .task(owner: "", done: true)),
        ])
    }

    func testCopyIsPlainTextWithBulletsAndTitles() {
        let d = SummaryText.build(SummaryBlocks.split(md))
        XCTAssertEqual(d.copyText(NSRange(location: 0, length: d.length)), """
        Intro with a link.

        Decisions
        • Use HMAC in X-Signature
        • Three retries
        Detail
        Plain line.

        Action Items
        - [ ] Anna: send the keys
        - [x] check the docs
        """)
    }

    func testCopyOfOneBlock() {
        let d = SummaryText.build(SummaryBlocks.split(md))
        XCTAssertEqual(d.copyText(SummaryText.range(ofBlock: 1, in: d)), """
        Decisions
        • Use HMAC in X-Signature
        • Three retries
        Detail
        Plain line.
        """)
        XCTAssertEqual(d.copyText(SummaryText.range(ofBlock: 0, in: d)), "Intro with a link.")
        XCTAssertEqual(SummaryText.range(ofBlock: 9, in: d), NSRange(location: NSNotFound, length: 0))
    }

    func testInlineMarkdownKeepsLinksAndEmphasis() {
        let d = SummaryText.build(SummaryBlocks.split(md))
        let ns = d.string as NSString
        XCTAssertEqual(d.inlines.first { $0.link != nil }?.range, ns.range(of: "link"))
        XCTAssertEqual(d.inlines.first { $0.link != nil }?.link, URL(string: "https://example.com"))
        XCTAssertEqual(d.inlines.first { $0.style.contains(.bold) }?.range, ns.range(of: "HMAC"))
        XCTAssertEqual(d.inlines.first { $0.style.contains(.code) }?.range, ns.range(of: "X-Signature"))
    }

    func testBrokenMarkdownStaysAsWritten() {
        let d = SummaryText.build([SummaryBlock(title: "", lines: ["a **b"])])
        XCTAssertEqual(d.string, "a **b")
    }
}

final class ClickToPlayTests: XCTestCase {
    func testAPlainClickPlays() {
        XCTAssertTrue(ClickToPlay.plays(clickCount: 1, modified: false, moved: 0, selectionLength: 0))
        XCTAssertTrue(ClickToPlay.plays(clickCount: 1, modified: false, moved: 2, selectionLength: 0), "a hand trembles")
    }

    func testDragDoubleAndTripleClickSelectInstead() {
        XCTAssertFalse(ClickToPlay.plays(clickCount: 1, modified: false, moved: 30, selectionLength: 12))
        XCTAssertFalse(ClickToPlay.plays(clickCount: 1, modified: false, moved: 10, selectionLength: 0))
        XCTAssertFalse(ClickToPlay.plays(clickCount: 2, modified: false, moved: 0, selectionLength: 5))
        XCTAssertFalse(ClickToPlay.plays(clickCount: 3, modified: false, moved: 0, selectionLength: 40))
    }

    func testShiftOrCommandClickExtendsTheSelection() {
        XCTAssertFalse(ClickToPlay.plays(clickCount: 1, modified: true, moved: 0, selectionLength: 0))
    }

    func testAClickThatLeftASelectionDoesNotPlay() {
        XCTAssertFalse(ClickToPlay.plays(clickCount: 1, modified: false, moved: 0, selectionLength: 3))
    }
}
