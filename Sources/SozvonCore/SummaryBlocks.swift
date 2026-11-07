// The call summary (summary.md) split into the cards of the Calls window: one block per "## " section.

import Foundation

public struct SummaryBlock: Equatable, Sendable {
    /// The section heading without "#"; empty for text before the first heading.
    public var title: String
    /// The section's non-empty lines, trimmed; "---" rules are dropped.
    public var lines: [String]

    public init(title: String, lines: [String]) {
        self.title = title
        self.lines = lines
    }
}

public enum SummaryBlocks {
    /// "# " and "## " start a block; deeper headings ("### ") stay inside it as lines.
    /// A heading with nothing under it still makes a block; text before any heading makes an untitled one.
    public static func split(_ markdown: String) -> [SummaryBlock] {
        var out: [SummaryBlock] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "---" { continue }
            if line.hasPrefix("# ") || line.hasPrefix("## ") {
                out.append(SummaryBlock(title: line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces), lines: []))
                continue
            }
            if out.isEmpty { out.append(SummaryBlock(title: "", lines: [])) }
            out[out.count - 1].lines.append(line)
        }
        return out
    }
}
