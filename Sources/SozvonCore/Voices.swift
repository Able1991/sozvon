// Voice prints: records the engine keeps in `<data>/voices/<id>.json` (read-only here, the embedding is ignored)
// and the arguments for `bin/voice.py` (enroll, delete). The engine owns the files; the app only reads them.

import Foundation

/// One saved voice: who it is, which project it belongs to, how much speech it was built from.
public struct VoiceRecord: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// Project slug, "" for a voice shared across projects.
    public let profile: String
    /// The user's own sample (recorded in Settings).
    public let me: Bool
    /// Seconds of speech the print was built from.
    public let seconds: Double
    /// As the engine wrote it (ISO 8601).
    public let updatedAt: String

    public init(id: String, name: String, profile: String = "", me: Bool = false, seconds: Double = 0, updatedAt: String = "") {
        self.id = id
        self.name = name
        self.profile = profile
        self.me = me
        self.seconds = seconds
        self.updatedAt = updatedAt
    }

    /// From a record's JSON object. Nil without an id or a name.
    public init?(json o: [String: Any]) {
        guard let id = o["id"] as? String, !id.isEmpty, let name = o["name"] as? String else { return nil }
        self.init(id: id, name: name, profile: o["profile"] as? String ?? "", me: o["me"] as? Bool ?? false,
                  seconds: (o["seconds"] as? NSNumber)?.doubleValue ?? 0, updatedAt: o["updated_at"] as? String ?? "")
    }
}

public enum Voices {
    public static let script = "voice.py"

    public static var dir: URL { Paths.data.appendingPathComponent("voices") }

    /// Every readable record, sorted by name. Unreadable or foreign files are skipped.
    public static func all(in dir: URL = Voices.dir) -> [VoiceRecord] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.compactMap { n in
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(n)),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
            return VoiceRecord(json: o)
        }
        .sorted { a, b in
            let c = a.name.localizedStandardCompare(b.name)
            return c == .orderedSame ? a.id < b.id : c == .orderedAscending
        }
    }

    /// The user's own sample, if recorded.
    public static var me: VoiceRecord? { me(in: dir) }

    public static func me(in dir: URL) -> VoiceRecord? {
        all(in: dir).filter(\.me).max { $0.updatedAt < $1.updatedAt }
    }

    /// Voices saved for a project (not the user's own).
    public static func forProfile(_ slug: String, in dir: URL = Voices.dir) -> [VoiceRecord] {
        all(in: dir).filter { !$0.me && $0.profile == slug }
    }

    /// The project's voice for a person, matched by name ignoring case.
    public static func voice(named name: String, profile: String, in records: [VoiceRecord]) -> VoiceRecord? {
        let n = name.trimmingCharacters(in: .whitespaces)
        return records.first { !$0.me && $0.profile == profile && $0.name.caseInsensitiveCompare(n) == .orderedSame }
    }

    // MARK: voice.py arguments

    /// Own sample or any recording: `enroll --name N [--profile S] [--me] [--add] --file F`.
    /// `add`: one more sample merged into the voice print (another language); otherwise it replaces it.
    public static func enrollFile(name: String, profile: String = "", me: Bool, add: Bool = false, file: URL) -> [String] {
        var a = ["enroll", "--name", name]
        if !profile.isEmpty { a += ["--profile", profile] }
        if me { a.append("--me") }
        if add { a.append("--add") }
        return a + ["--file", file.path]
    }

    /// A speaker from a call's transcript: `enroll --name N [--profile S] --call DIR --speaker LABEL`.
    public static func enrollCall(name: String, profile: String = "", dir: URL, speaker: String) -> [String] {
        var a = ["enroll", "--name", name]
        if !profile.isEmpty { a += ["--profile", profile] }
        return a + ["--call", dir.path, "--speaker", speaker]
    }

    public static func delete(id: String) -> [String] { ["delete", "--id", id] }

    public static func deleteAll() -> [String] { ["delete", "--all"] }

    /// Named speakers of a call whose voice is not saved yet (for "Remember voices" after a correct transcript):
    /// not generic labels, not the user, and without a record in the call's project or without a project.
    public static func unsaved(speakers: [String], profile: String, records: [VoiceRecord], me: String) -> [String] {
        let names = namesToEnroll(speakers, me: me)
        return names.filter { n in
            !records.contains { !$0.me && ($0.profile == profile || $0.profile.isEmpty)
                && $0.name.caseInsensitiveCompare(n) == .orderedSame }
        }
    }

    // MARK: Which names get a voice print

    /// Labels the engine gives when it doesn't know who speaks ("Собеседник 2", "Speaker ?", "Я + собеседники"),
    /// and the user's own name ("Я", "Me", the name from Settings): the own voice comes from the sample in Settings.
    public static func isGenericLabel(_ name: String, me: String = "") -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return true }
        let own = me.trimmingCharacters(in: .whitespaces)
        if !own.isEmpty, n.caseInsensitiveCompare(own) == .orderedSame { return true }
        let lower = n.lowercased()
        if lower == "я" || lower == "me" { return true }  // l10n-ignore
        if lower.hasSuffix("+ собеседники") || lower.hasSuffix("+ others") { return true }  // l10n-ignore
        return lower.range(of: #"^(собеседник|спикер|speaker)([ _]*([0-9]+|\?|n))?$"#, options: .regularExpression) != nil  // l10n-ignore
    }

    /// Names worth enrolling after a rename: not generic, not the user, each once.
    public static func namesToEnroll(_ names: [String], me: String = "") -> [String] {
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !isGenericLabel($0, me: me) && seen.insert($0.lowercased()).inserted }
    }
}
