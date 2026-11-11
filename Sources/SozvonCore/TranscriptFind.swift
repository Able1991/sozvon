// Find inside one transcript (⌘F on the Transcript tab). Search across calls is the sidebar's.

import Foundation

public enum TranscriptFind {
    public struct Match: Equatable, Sendable {
        /// The paragraph's number.
        public let line: Int
        /// Where in the paragraph's text.
        public let range: Range<String.Index>
    }

    /// The engine's end-of-paragraph mark for a line starred during the recording: not the words of the call.
    private static let star = " \u{2B50}"

    /// Every occurrence, in reading order. Case and diacritics don't count, so "счет" finds "Счёт".
    public static func matches(_ query: String, in lines: [String]) -> [Match] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var out: [Match] = []
        for (n, line) in lines.enumerated() {
            let end = line.hasSuffix(star) ? line.index(line.endIndex, offsetBy: -star.count) : line.endIndex
            var from = line.startIndex
            while from < end, let r = line.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: from..<end) {
                out.append(Match(line: n, range: r))
                from = r.upperBound
            }
        }
        return out
    }

    /// Next (+1) or Previous (-1), going round at the ends.
    public static func step(from index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }
}
