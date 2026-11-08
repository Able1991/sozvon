// After a recording: the project and the participants from what Sozvon already knows (the meeting in the
// calendar and the voices heard during the call, LiveVoices), and whether that is sure enough for "What was the
// call about?" to go ahead by itself after a countdown.

import Foundation

/// Someone the live voice match heard during the recording.
public struct HeardVoice: Equatable, Sendable {
    public let name: String
    /// The project of their voice print ("" for any project).
    public let profile: String
    public let seconds: Double
    /// The same voice is saved under another name too: the project holds, the name may not.
    public let unsure: Bool
    public init(name: String, profile: String = "", seconds: Double = 0, unsure: Bool = false) {
        self.name = name
        self.profile = profile
        self.seconds = seconds
        self.unsure = unsure
    }
}

public enum CallGuess {
    /// Seconds the form waits before transcribing by itself.
    public static let formCountdown = 10
    public static let skipFormKey = "skipCallInfoWhenSure"

    /// Settings: when the project and the participants are known, the form transcribes by itself after a countdown
    /// (on by default).
    public static func skipForm(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: skipFormKey) as? Bool ?? true
    }

    public static func setSkipForm(_ on: Bool, _ d: UserDefaults = .standard) {
        d.set(on, forKey: skipFormKey)
    }

    /// Heard this long, a voice is enough to transcribe without asking (below it, it is only a hint in the form).
    public static let sureSeconds: Double = 30
    /// A recording may start this long before the meeting and still be that meeting, for transcribing without asking.
    public static let sureEarly: TimeInterval = 5 * 60

    /// Fill only what the user left empty: the calendar first (CalendarMatch.fill), then the voices heard join
    /// the participants and, without a project yet, give it (the project most of their speech belongs to).
    /// `defaultProfile`: the last used project the form starts with. It says nothing about this call: it stays
    /// only when nothing better is known and never makes the guess sure.
    /// `sure`: a project and participants, backed by the user, the meeting going on at `startedAt` or a voice
    /// heard for a while, and nothing contradicts.
    public static func fill(_ info: CallInfo, defaultProfile: String = "", startedAt: Date, event: CalendarEvent?,
                            heard: [HeardVoice], projects: [Project]) -> (info: CallInfo, sure: Bool) {
        var base = info
        if base.profile == defaultProfile { base.profile = "" }
        let typedProfile = base.profile
        let typedNames = !base.names.trimmingCharacters(in: .whitespaces).isEmpty
        let typedAnything = typedNames || !typedProfile.isEmpty || !base.topic.trimmingCharacters(in: .whitespaces).isEmpty

        var i = event.map { CalendarMatch.fill(base, from: $0, projects: projects) } ?? base
        if !typedProfile.isEmpty { i.profile = typedProfile }  // chosen during the call: not the calendar's to change
        let fromCalendar = typedProfile.isEmpty ? i.profile : ""

        if !typedNames {
            var names = split(i.names)
            for v in heard where !v.unsure && !names.contains(where: { same($0, v.name) }) { names.append(v.name) }
            i.names = names.joined(separator: ", ")
        }
        // The voices' project, by seconds of speech; only projects that exist.
        var weight: [String: Double] = [:]
        for v in heard where !v.profile.isEmpty && projects.contains(where: { $0.slug == v.profile }) {
            weight[v.profile, default: 0] += v.seconds
        }
        let voiced = weight.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        if i.profile.isEmpty, !typedAnything, let voiced { i.profile = voiced }

        let conflict = !fromCalendar.isEmpty && voiced != nil && voiced != fromCalendar
        let meetingNow = event.map { startedAt >= $0.start.addingTimeInterval(-sureEarly) && startedAt <= $0.end } ?? false
        let voiceHeard = heard.contains { !$0.unsure && $0.seconds >= sureSeconds }
        let sure = !i.profile.isEmpty && projects.contains(where: { $0.slug == i.profile })
            && !split(i.names).isEmpty && (meetingNow || voiceHeard || typedAnything) && !conflict
        if i.profile.isEmpty { i.profile = defaultProfile }  // the form's usual default
        return (i, sure)
    }

    static func split(_ names: String) -> [String] {
        names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The same person under two spellings: equal ignoring case, or one is the other's first name
    /// ("Анна" and "Анна Петрова").
    static func same(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        if x == y { return true }
        let fx = x.split(separator: " ").first.map(String.init) ?? x
        let fy = y.split(separator: " ").first.map(String.init) ?? y
        return (fx == y || fy == x)
    }
}
