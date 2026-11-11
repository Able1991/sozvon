// The summary as one selectable text: a section per "## ", its lines in a group box under the title (DocText.swift).

import SwiftUI

/// The summary: titles, paragraphs, bullet lists, action items; selectable across sections, each with a Copy button.
struct SummaryCards: View {
    let text: String

    var body: some View {
        SummaryPane(markdown: text)
    }
}
