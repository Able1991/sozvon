// The summary as cards, one per "## " section.

import AppKit
import SozvonCore
import SwiftUI

/// The summary as cards, one per "## " section: paragraphs, bullet lists, action items.
struct SummaryCards: View {
    let text: String

    var body: some View {
        let blocks = SummaryBlocks.split(text)
        VStack(alignment: .leading, spacing: 24) {
            ForEach(blocks.indices, id: \.self) { i in
                SZBlock(blocks[i].title) {
                    SummaryBlockBody(lines: blocks[i].lines)
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// The lines of one summary card: consecutive bullets make one list (4 apart), other lines 10 apart.
struct SummaryBlockBody: View {
    let lines: [String]

    private var pieces: [SummaryPiece] { SummaryBlocks.pieces(lines) }

    var body: some View {
        let pieces = self.pieces
        ForEach(pieces.indices, id: \.self) { i in
            switch pieces[i] {
            case .paragraph(let s):
                inline(s).szFont(.bodyRelaxed).foregroundStyle(SZ.label).fixedSize(horizontal: false, vertical: true)
            case .heading(let s):
                inline(s).szFont(.bodyRelaxed).fontWeight(.semibold).foregroundStyle(SZ.label)
            case .bullets(let items):
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items.indices, id: \.self) { j in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(verbatim: "•").foregroundStyle(SZ.label3).frame(width: 18, alignment: .center)
                            inline(items[j]).foregroundStyle(SZ.label).fixedSize(horizontal: false, vertical: true)
                        }
                        .szFont(.bodyRelaxed)
                    }
                }
            case .task(let item):
                HStack(alignment: .top, spacing: 10) {
                    SZTaskRing(done: item.done).padding(.top, 2.5)
                    inline(item.task).szFont(.bodyRelaxed)
                        .foregroundStyle(item.done ? SZ.label2 : SZ.label)
                        .strikethrough(item.done)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if !item.owner.isEmpty {
                        Text(item.owner).szFont(.bodyRelaxed).font(.system(size: 12)).foregroundStyle(SZ.label2)
                            .lineLimit(1).fixedSize()
                    }
                }
            }
        }
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s) { return Text(a) }
        return Text(s)
    }
}
