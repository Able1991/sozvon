// A call for the "Calls" list: everything about it comes from call.json. The folder name is parsed
// only for old calls without call.json, and only for display.

import Foundation

public struct Call: Identifiable, Sendable {
    public let url: URL
    public var id: String { url.path }
    /// Permanent call id: "2026-11-04 15-01" (a second recording in the same minute is "2026-11-04 15-01-2").
    public var callID: String
    public var date: Date?
    /// Topic, otherwise project, otherwise "Call".
    public var title: String
    public var project: String
    public var topic: String
    public var languages: [SpeechLanguage]
    /// Who took part, comma-separated: call.json `participants`, else the typed `names` (CallParticipants.list).
    public var people: String
    /// call.json `participants` as stored; nil for a call that has none yet (the card derives them in memory).
    public var participants: [String]?
    public var duration: TimeInterval
    public var bytes: Int64
    public var hasTranscript: Bool
    public var hasSummary: Bool
    public var hasAudio: Bool
    public var info: CallInfo
    public var status: CallStatus?
    /// Notes from call.json, oldest first.
    public var notes: [CallNote] = []
    /// Recorded and waiting for "What was the call about?" ("Later").
    public var infoPending = false
    /// Old call without call.json: project and topic are guessed from the folder name.
    public var isLegacy: Bool

    public var transcriptURL: URL { url.appendingPathComponent("transcript.md") }
    public var summaryURL: URL { url.appendingPathComponent("summary.md") }
    public var logURL: URL { url.appendingPathComponent("process.log") }

    /// "2026-11-04 15-01" -> a date in the current time zone; otherwise nil.
    public static func parseID(_ s: String) -> Date? {
        let s = String(s.prefix(16))
        let c = s.unicodeScalars.map { Character($0) }
        guard c.count == 16, c[4] == "-", c[7] == "-", c[10] == " ", c[13] == "-" else { return nil }
        func num(_ r: Range<Int>) -> Int? { Int(String(c[r])) }
        guard let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10), let h = num(11..<13), let mi = num(14..<16),
              (1...12).contains(mo), (1...31).contains(d), (0...23).contains(h), (0...59).contains(mi) else { return nil }
        return Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))
    }

    /// Load a call folder. `projects`: short names by slug.
    /// `withSize`: compute the folder size (walks every file, via FolderSizeCache); without it `bytes` = 0.
    public static func load(_ url: URL, projects: [String: String] = [:], defaults: CallInfo = CallInfo(),
                            withSize: Bool = false) -> Call? {
        let fm = FileManager.default
        let name = url.lastPathComponent
        func has(_ f: String) -> Bool { fm.fileExists(atPath: url.appendingPathComponent(f).path) }
        let legacy = !has(CallFile.name)

        var call = Call(url: url, callID: CallFolder.id(fromName: name), date: nil, title: "", project: "", topic: "",
                        languages: [], people: "", duration: 0, bytes: 0,
                        hasTranscript: has("transcript.md"), hasSummary: has("summary.md"),
                        hasAudio: has("mic.m4a") || has("system.m4a"), info: defaults, status: nil, isLegacy: legacy)

        if !legacy {
            let c = CallFile.read(url)
            if let id = c["id"] as? String, !id.isEmpty { call.callID = id }
            call.date = parseID(call.callID)
                ?? (c["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            call.info = CallFile.info(c, fallback: defaults)
            call.status = (c["status"] as? String).flatMap(CallStatus.init(rawValue:))
            call.notes = CallNotes.list(c)
            call.infoPending = PendingInfo.isPending(c)
            call.duration = AudioTimes((c["audio"] as? [String: Any]) ?? [:]).duration
            call.languages = (c["languages"] as? String).map(SpeechLanguage.parse) ?? []
            call.topic = call.info.topic.isEmpty ? call.info.terms : call.info.topic
            // A project this Mac doesn't have (a call restored from the server): the title the server sent.
            let remoteTitle = (c["project_title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            call.project = call.info.profile.isEmpty ? "" : (projects[call.info.profile] ?? remoteTitle ?? call.info.profile)
            call.participants = CallParticipants.stored(c)
            call.people = (call.participants ?? splitList(call.info.names)).joined(separator: ", ")
        } else {
            // Before contract 1: "date · project · topic · people" in the folder name, duration in meta.json.
            call.date = parseID(name)
            guard call.date != nil || has("meta.json") else { return nil }
            if let d = try? Data(contentsOf: url.appendingPathComponent("meta.json")),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                call.duration = AudioTimes(o).duration
            }
            let parts = Array(name.components(separatedBy: " · ").dropFirst())
            call.project = parts.count >= 2 ? parts[0] : ""
            call.topic = parts.count >= 2 ? parts[1] : (parts.count == 1 ? parts[0] : "")
            call.people = parts.count >= 3 ? parts[2...].joined(separator: " · ") : ""
            call.info.names = call.people
        }
        call.title = !call.topic.isEmpty ? call.topic : (!call.project.isEmpty ? call.project : L("Звонок"))
        if withSize { call.bytes = FolderSizeCache.shared.size(url) }
        return call
    }

    static func folderSize(_ url: URL) -> Int64 {
        var bytes: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e { bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return bytes
    }

    /// All calls in the folder, newest first. Folder sizes only with `withSizes` (it walks every file).
    public static func all(in dir: URL = Paths.calls, projects: [String: String] = [:],
                           defaults: CallInfo = CallInfo(), withSizes: Bool = false) -> [Call] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.filter { $0.hasDirectoryPath }
            .compactMap { load($0, projects: projects, defaults: defaults, withSize: withSizes) }
            .sorted {
                let a = $0.date ?? .distantPast, b = $1.date ?? .distantPast
                // Two recordings in the same minute: "…15-01-2" is newer than "…15-01".
                return a != b ? a > b : $0.callID.compare($1.callID, options: .numeric) == .orderedDescending
            }
    }

    /// "37 MB", "1.2 GB": size of the whole call folder.
    public var sizeText: String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : ""
    }

    public var durationText: String { Call.clock(Int(duration)) }

    /// "12:34" or "1:02:03"; empty for zero.
    public static func clock(_ t: Int, empty: String = "") -> String {
        guard t > 0 else { return empty }
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Who took part in a call. call.json keeps two lists: `names`, only what the user typed (the engine reads them as
/// certain), and `participants`, derived from the transcript by the engine at `done` and after `--summary-only`, and
/// by the app after a transcript edit. Derived names are never written to `names`: the assistant's guesses would come
/// back as certain on the next transcription. Everything that shows or searches participants reads `participants`,
/// falling back to `names` for calls made before the field existed.
public enum CallParticipants {
    public static let key = "participants"

    /// The engine's names.participants rule (both run Tests/Fixtures/participants.json): every speaker that names a
    /// person in the order they first speak, then the typed names that never spoke, in their order. Each name once
    /// (ignoring case, extra spaces squeezed), never the user or a generic label (Voices.isGenericLabel). A typed
    /// single first name that is the first word of exactly one speaking name ("Anna", "Anna Petrova") is that person.
    public static func derived(_ typed: [String], speakers: [String], me: String) -> [String] {
        func squeeze(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var out: [String] = [], seen = Set<String>()
        for raw in speakers + typed {
            let n = squeeze(raw)
            guard !Voices.isGenericLabel(n, me: me), seen.insert(n.lowercased()).inserted else { continue }
            out.append(n)
        }
        let spoken = Set(speakers.map { squeeze($0).lowercased() })
        func folded(_ n: String) -> Bool {
            let low = n.lowercased()
            guard !spoken.contains(low), !n.contains(" ") else { return false }
            return out.filter { spoken.contains($0.lowercased()) && $0.lowercased().split(separator: " ").first.map(String.init) == low }
                .count == 1
        }
        return out.filter { !folded($0) }
    }

    /// The typed names of a call.json (a list, or the old comma-separated string).
    public static func typed(_ c: [String: Any]) -> [String] {
        c["names"] as? [String] ?? splitList(c["names"] as? String ?? "")
    }

    /// The stored derived list, nil when the call has none yet (made before the field existed, or not transcribed).
    public static func stored(_ c: [String: Any]) -> [String]? { c[key] as? [String] }

    /// Who took part, as stored: `participants`, else the typed `names`.
    public static func list(_ c: [String: Any]) -> [String] { stored(c) ?? typed(c) }

    /// The speakers of the call's transcript (transcript.txt, else transcript.md), in transcript order.
    public static func speakers(in dir: URL) -> [String] {
        for name in TranscriptEdit.files.reversed() {
            if let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) {
                return Transcript.lines(text).map(\.speaker)
            }
        }
        return []
    }

    /// After a user edit of the transcript: `participants` recomputed from it (people whose lines all went to someone
    /// else are gone). `names` is never touched. A call without call.json (an old one) is left alone; a corrupt
    /// call.json is never replaced (CallFileError.corrupt). -> whether call.json changed.
    @discardableResult
    public static func update(in dir: URL, me: String) throws -> Bool {
        guard CallFile.exists(dir) else { return false }
        let speakers = speakers(in: dir)
        guard !speakers.isEmpty else { return false }
        return try CallFile.edit(dir) { c in
            let all = derived(typed(c), speakers: speakers, me: me)
            guard stored(c) != all else { return false }
            c[key] = all
            return true
        }
    }
}
