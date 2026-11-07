// "What was the call about?" filled from the calendar: the meeting at the time of the recording gives the topic,
// the participants and, when it matches one, the project (CalendarMatch). Calendar access is asked the first
// time the form opens after a recording; nothing leaves the Mac.

import EventKit
import Foundation
import SozvonCore

@MainActor
enum CalendarPrefill {
    static let key = "calendarPrefill"
    private static let store = EKEventStore()

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var denied: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        return s == .denied || s == .restricted
    }

    /// Ask for access if it was never asked. Returns whether events can be read.
    static func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined: return (try? await store.requestFullAccessToEvents()) ?? false
        default: return false
        }
    }

    /// The form for a recording that started at `startedAt`, with what the calendar knows.
    static func fill(_ info: CallInfo, startedAt: Date) async -> CallInfo {
        guard enabled, await requestAccess(), let e = event(at: startedAt) else { return info }
        return CalendarMatch.fill(info, from: e, projects: Project.all())
    }

    static func event(at date: Date) -> CalendarEvent? {
        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-8 * 3600),
                                                 end: date.addingTimeInterval(3600), calendars: nil)
        let events = store.events(matching: predicate).compactMap { e -> CalendarEvent? in
            guard e.status != .canceled,
                  e.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined else { return nil }
            let attendees = (e.attendees ?? []).map { a in
                CalendarEvent.Attendee(name: a.name ?? "", email: a.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
                                       isMe: a.isCurrentUser)
            }
            return CalendarEvent(title: e.title ?? "", start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                                 attendees: attendees,
                                 hasCallLink: CalendarMatch.hasCallLink([e.url?.absoluteString, e.location, e.notes].compactMap { $0 }))
        }
        return CalendarMatch.best(events, recordingStart: date)
    }
}
