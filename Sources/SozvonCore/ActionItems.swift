// Action items from a call summary ("## Задачи" / "## Action Items": "- [ ] who: what, due date"),
// whose they are, and a due date when the text names a clear day relative to the call date.
// Pure functions: the Calls window turns the chosen items into reminders (EventKit).

import Foundation

public struct ActionItem: Equatable, Sendable {
    /// "Anna" from "Anna: send the contract, Friday"; empty when the line names nobody.
    public var owner: String
    /// Everything after the owner: "send the contract, Friday".
    public var task: String
    public var done: Bool

    public init(owner: String, task: String, done: Bool = false) {
        self.owner = owner
        self.task = task
        self.done = done
    }
}

public enum ActionItems {
    // l10n-ignore-start
    /// Section titles the engine's summary prompt uses (pipeline/summary.py), ignoring case.
    static let headings: Set<String> = ["задачи", "action items", "tasks"]
    /// Owner words that mean the user, besides the name from Settings.
    static let selfWords: Set<String> = ["я", "вы", "you", "me"]
    // l10n-ignore-end

    /// Items of the action items section, in order. Other sections are ignored.
    public static func parse(_ summary: String) -> [ActionItem] {
        var inside = false
        var out: [ActionItem] = []
        for raw in summary.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased()
                inside = headings.contains(title)
                continue
            }
            guard inside else { continue }
            if line == "---" { inside = false; continue }
            guard let item = item(line) else { continue }
            out.append(item)
        }
        return out
    }

    /// "- [ ] Anna: send it" / "- [x] …" / "- …" / "* …" -> an item; other lines: nil.
    static func item(_ line: String) -> ActionItem? {
        var s = Substring(line)
        guard s.hasPrefix("- ") || s.hasPrefix("* ") else { return nil }
        s = s.dropFirst(2).drop { $0 == " " }
        var done = false
        if s.hasPrefix("[ ]") || s.hasPrefix("[x]") || s.hasPrefix("[X]") {
            done = !s.hasPrefix("[ ]")
            s = s.dropFirst(3).drop { $0 == " " }
        }
        let text = s.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let colon = text.firstIndex(of: ":") {
            let owner = text[..<colon].replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
            var after = text[text.index(after: colon)...]
            if after.hasPrefix("**") { after = after.dropFirst(2) }  // "**Anna:** task"
            let task = after.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            if isOwner(owner, followedBy: after), !task.isEmpty {
                return ActionItem(owner: owner, task: task, done: done)
            }
        }
        return ActionItem(owner: "", task: text.replacingOccurrences(of: "**", with: ""), done: done)
    }

    /// An owner is a name or a few names before ": ", not a sentence or a link that happens to contain a colon
    /// ("Проверить https://x.y", "Встреча в 10:30"): at most 4 words, no digits, no "/", "@" or domain
    /// ("site.ru"), and a space after the colon.
    static func isOwner(_ owner: String, followedBy rest: Substring) -> Bool {
        guard rest.first == " " || rest.first == "\t" else { return false }
        guard !owner.isEmpty, owner.count <= 60, owner.split(whereSeparator: \.isWhitespace).count <= 4 else { return false }
        guard !owner.contains(where: { $0.isNumber || $0 == "/" || $0 == "@" }) else { return false }
        return owner.range(of: #"\.\p{L}{2,}"#, options: .regularExpression) == nil
    }

    /// Whether the owner is the user: their name from Settings (or its first word), or "Вы"/"You"/"Я"/"Me".
    /// "Anna, Boris" and "Anna и Boris" count when one of them is the user.
    public static func isMine(_ owner: String, me: String) -> Bool {
        let me = me.trimmingCharacters(in: .whitespaces).lowercased()
        let meFirst = me.split(separator: " ").first.map(String.init) ?? ""
        let parts = owner.lowercased()
            .replacingOccurrences(of: " и ", with: ",").replacingOccurrences(of: " and ", with: ",")  // l10n-ignore
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0 == "&" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.contains { p in
            if selfWords.contains(p) { return true }
            guard !me.isEmpty else { return false }
            let first = p.split(separator: " ").first.map(String.init) ?? p
            return p == me || first == meFirst
        }
    }
}

/// A due date from the task text, relative to the call date: only clear days ("tomorrow", "Friday",
/// "Nov 10", "завтра", "в пятницу", "10 ноября"). Anything vaguer gives nil: better no date than a wrong one.
public enum DueDate {
    // l10n-ignore-start
    static let ruMonths = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа",
                           "сентября", "октября", "ноября", "декабря"]
    static let enMonths: [(String, Int)] = [
        ("january", 1), ("february", 2), ("march", 3), ("april", 4), ("may", 5), ("june", 6), ("july", 7),
        ("august", 8), ("september", 9), ("october", 10), ("november", 11), ("december", 12),
        ("jan", 1), ("feb", 2), ("mar", 3), ("apr", 4), ("jun", 6), ("jul", 7), ("aug", 8), ("sept", 9),
        ("sep", 9), ("oct", 10), ("nov", 11), ("dec", 12),
    ]
    /// Calendar weekday numbers (1 is Sunday) by word, in every case form a deadline uses.
    static let weekdays: [String: Int] = [
        "понедельник": 2, "понедельника": 2, "понедельнику": 2,
        "вторник": 3, "вторника": 3, "вторнику": 3,
        "среда": 4, "среду": 4, "среды": 4, "среде": 4,
        "четверг": 5, "четверга": 5, "четвергу": 5,
        "пятница": 6, "пятницу": 6, "пятницы": 6, "пятнице": 6,
        "суббота": 7, "субботу": 7, "субботы": 7, "субботе": 7,
        "воскресенье": 1, "воскресенья": 1, "воскресенью": 1,
        "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7, "sunday": 1,
    ]
    static let relative: [(String, Int)] = [("послезавтра", 2), ("завтра", 1), ("сегодня", 0),
                                            ("tomorrow", 1), ("today", 0), ("tonight", 0)]
    // l10n-ignore-end

    /// Year, month and day of the due date, or nil.
    public static func parse(_ text: String, callDate: Date, calendar: Calendar = .current) -> DateComponents? {
        let s = text.lowercased()
        let day = calendar.startOfDay(for: callDate)
        if let d = explicit(s, day: day, calendar: calendar) { return d }
        let words = s.split(whereSeparator: { !$0.isLetter }).map(String.init)
        if s.contains("day after tomorrow") { return shift(day, 2, calendar) }  // l10n-ignore
        for (w, n) in relative where words.contains(w) { return shift(day, n, calendar) }
        for w in words {
            guard let target = weekdays[w] else { continue }
            let now = calendar.component(.weekday, from: day)
            let ahead = (target - now + 7) % 7
            return shift(day, ahead == 0 ? 7 : ahead, calendar)
        }
        return nil
    }

    private static func shift(_ day: Date, _ n: Int, _ cal: Calendar) -> DateComponents? {
        cal.date(byAdding: .day, value: n, to: day).map { cal.dateComponents([.year, .month, .day], from: $0) }
    }

    /// "10 ноября", "Nov 10", "November 10th, 2027", "10 Nov", "10th of November".
    private static func explicit(_ s: String, day: Date, calendar: Calendar) -> DateComponents? {
        let en = enMonths.map(\.0).joined(separator: "|")
        let patterns: [(String, (([String]) -> (Int, Int, Int?)?))] = [
            (#"(?<![\p{L}\d])(\d{1,2})\s+("# + ruMonths.joined(separator: "|") + #")(?:\s+(\d{4}))?"#, { g in
                guard let d = Int(g[1]), let m = ruMonths.firstIndex(of: g[2]) else { return nil }
                return (d, m + 1, Int(g[3]))
            }),
            (#"(?<![\p{L}\d])("# + en + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?![\p{L}\d])(?:,?\s+(\d{4}))?"#, { g in
                guard let m = enMonths.first(where: { $0.0 == g[1] })?.1, let d = Int(g[2]) else { return nil }
                return (d, m, Int(g[3]))
            }),
            (#"(?<![\p{L}\d])(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?("# + en + #")(?![\p{L}])(?:,?\s+(\d{4}))?"#, { g in
                guard let d = Int(g[1]), let m = enMonths.first(where: { $0.0 == g[2] })?.1 else { return nil }
                return (d, m, Int(g[3]))
            }),
        ]
        for (pattern, build) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let match = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
            let groups = (0..<match.numberOfRanges).map { i -> String in
                Range(match.range(at: i), in: s).map { String(s[$0]) } ?? ""
            }
            guard let (d, m, y) = build(groups) else { continue }
            let year = y ?? calendar.component(.year, from: day)
            guard var date = valid(year, m, d, calendar) else { continue }
            // No year and already past on the call date: next year ("January 10" said in December).
            if y == nil, date < day, let next = valid(year + 1, m, d, calendar) { date = next }
            return calendar.dateComponents([.year, .month, .day], from: date)
        }
        return nil
    }

    private static func valid(_ y: Int, _ m: Int, _ d: Int, _ cal: Calendar) -> Date? {
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)),
              cal.component(.day, from: date) == d, cal.component(.month, from: date) == m else { return nil }
        return date
    }
}

/// "To Reminders" pressed again: a task already sent from this call is not added twice. A reminder is the
/// same when it is not completed, has the same title (ignoring case and surrounding spaces) and points to
/// this call: its URL is the call's, or its notes carry the call's line ("Звонок в Sozvon: <folder>").
public enum ReminderMatch {
    public struct Existing: Equatable, Sendable {
        public var title: String
        public var notes: String?
        public var url: URL?
        public init(title: String, notes: String?, url: URL?) {
            self.title = title
            self.notes = notes
            self.url = url
        }
    }

    static func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// `links`: what identifies the call in a reminder's notes; `urls`: the call's URLs (folder, summary).
    public static func contains(_ existing: [Existing], title: String, links: [String], urls: [URL]) -> Bool {
        let t = norm(title)
        let marks = links.filter { !$0.isEmpty }
        return existing.contains { e in
            guard norm(e.title) == t else { return false }
            if let u = e.url, urls.contains(where: { $0.standardizedFileURL == u.standardizedFileURL }) { return true }
            let notes = e.notes ?? ""
            return marks.contains { notes.contains($0) }
        }
    }
}
