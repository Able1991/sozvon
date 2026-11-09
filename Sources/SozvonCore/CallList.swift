// Rules of the Calls window's list: the project / reflections filter and the day groups.

import Foundation

public enum CallFilter {
    /// The filter's choice for reflections instead of a project: a tag no project slug can have.
    public static let reflections = "\u{0}reflections"

    /// In the filter's project (or reflections). Not meant for the empty filter, which shows everything.
    public static func matches(_ c: Call, filter: String) -> Bool {
        filter == reflections ? c.info.reflection : c.info.profile == filter
    }

    /// In the filtered project, or the live call (shown under "Now" whatever the filter).
    public static func isShown(_ c: Call, filter: String, isLive: Bool) -> Bool {
        filter.isEmpty || matches(c, filter: filter) || isLive
    }

    /// The calls of the filtered project (all calls without a filter).
    public static func apply(_ calls: [Call], filter: String) -> [Call] {
        filter.isEmpty ? calls : calls.filter { matches($0, filter: filter) }
    }
}

public enum CallDays {
    public struct Labels {
        public var today: String
        public var yesterday: String
        public var undated: String
        /// The title of any other day, e.g. "November 5, 2026".
        public var format: (Date) -> String

        public init(today: String, yesterday: String, undated: String, format: @escaping (Date) -> String) {
            self.today = today
            self.yesterday = yesterday
            self.undated = undated
            self.format = format
        }
    }

    /// Groups by day in the order of first appearance: "Today", "Yesterday", the date; no date: its own group.
    public static func group(_ calls: [Call], now: Date, calendar: Calendar, labels: Labels) -> [(String, [Call])] {
        var out: [(String, [Call])] = []
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        for c in calls {
            let key: String
            if let d = c.date {
                if calendar.isDate(d, inSameDayAs: now) { key = labels.today }
                else if let yesterday, calendar.isDate(d, inSameDayAs: yesterday) { key = labels.yesterday }
                else { key = labels.format(d) }
            } else {
                key = labels.undated
            }
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1.append(c) } else { out.append((key, [c])) }
        }
        return out
    }
}
