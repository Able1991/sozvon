// Calendar event for a recording: its title, attendees and project fill the "What was the call about?" form.
// Pure matching; the app reads the events with EventKit (CalendarPrefill.swift).

import Foundation

public struct CalendarEvent: Equatable, Sendable {
    public struct Attendee: Equatable, Sendable {
        public var name: String
        public var email: String
        public var isMe: Bool
        public init(name: String, email: String = "", isMe: Bool = false) {
            self.name = name
            self.email = email
            self.isMe = isMe
        }
    }

    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var attendees: [Attendee]
    /// A Zoom, Meet, Teams or Telemost link in the URL, location or notes.
    public var hasCallLink: Bool

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false, attendees: [Attendee] = [],
                hasCallLink: Bool = false) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendees = attendees
        self.hasCallLink = hasCallLink
    }
}

public enum CalendarMatch {
    /// A recording may start this early before the meeting or this late after its end.
    public static let slack: TimeInterval = 15 * 60
    public static let callHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                                   "telemost.yandex", "whereby.com", "webex.com", "jitsi", "meet.jit.si", "skype.com"]

    public static func hasCallLink(_ texts: [String]) -> Bool {
        texts.contains { t in callHosts.contains { t.localizedCaseInsensitiveContains($0) } }
    }

    /// The event the recording most likely belongs to: not all-day, overlapping the recording start (with
    /// slack), preferring a call link, then attendees, then the start closest to the recording start.
    public static func best(_ events: [CalendarEvent], recordingStart t: Date) -> CalendarEvent? {
        let candidates = events.filter {
            !$0.isAllDay && $0.start.addingTimeInterval(-slack) <= t && t <= $0.end.addingTimeInterval(slack)
                && $0.end.timeIntervalSince($0.start) <= 8 * 3600
        }
        return candidates.min { a, b in
            func rank(_ e: CalendarEvent) -> (Int, Int, Double) {
                (e.hasCallLink ? 0 : 1, e.attendees.contains { !$0.isMe } ? 0 : 1, abs(e.start.timeIntervalSince(t)))
            }
            return rank(a) < rank(b)
        }
    }

    /// Attendee names without me (EventKit marks the current user): "Anna Petrova" as is, a bare email as its local part ("ivan.petrov").
    public static func people(_ e: CalendarEvent) -> [String] {
        var out: [String] = []
        for a in e.attendees where !a.isMe {
            var n = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if n.isEmpty || n.contains("@") {
                let mail = n.contains("@") ? n : a.email
                n = String(mail.split(separator: "@").first ?? "")
            }
            guard !n.isEmpty, !out.contains(n) else { continue }
            out.append(n)
        }
        return out
    }

    /// Project for the event: the project title in the event title wins, then the most attendees
    /// known in a project (first names compared). Nil when nothing matches.
    public static func project(for e: CalendarEvent, in projects: [Project]) -> Project? {
        let title = e.title.lowercased()
        if let p = projects.first(where: { p in
            [p.title, p.shortTitle].contains { t in t.count >= 3 && title.contains(t.lowercased()) }
        }) { return p }
        func first(_ s: String) -> String { s.split(separator: " ").first.map { $0.lowercased() } ?? "" }
        let names = Set(people(e).map(first)).subtracting([""])
        guard !names.isEmpty else { return nil }
        let scored = projects.map { p in (p, Set(p.people.map(first)).intersection(names).count) }
            .filter { $0.1 > 0 }
        return scored.max { $0.1 < $1.1 }?.0
    }

    /// Fill the form from the event: topic and participants only where they are empty; the project when
    /// the user has not typed anything during the recording (topic and names empty) and the event matches one.
    public static func fill(_ info: CallInfo, from e: CalendarEvent, projects: [Project]) -> CallInfo {
        var i = info
        let untouched = info.topic.trimmingCharacters(in: .whitespaces).isEmpty
            && info.names.trimmingCharacters(in: .whitespaces).isEmpty
        if i.topic.trimmingCharacters(in: .whitespaces).isEmpty { i.topic = e.title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if i.names.trimmingCharacters(in: .whitespaces).isEmpty { i.names = people(e).joined(separator: ", ") }
        if untouched, let p = project(for: e, in: projects) { i.profile = p.slug }
        return i
    }
}
