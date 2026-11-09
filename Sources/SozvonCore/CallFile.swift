// Call folder: call.json (schema 1, contract section 4), the "what was the call about" answers, folder name.

import Foundation

public enum CallFileError: Error, Equatable {
    /// call.json exists but is not a JSON object: left for the user, never overwritten.
    case corrupt
}

/// What the user said about the call before transcription (call.json fields).
public struct CallInfo: Equatable, Sendable {
    public var profile: String
    /// The participants the user typed, comma-separated (call.json `names`). The list derived from the transcript
    /// is call.json `participants` (CallParticipants), never written here.
    public var names: String
    public var topic: String
    public var terms: String
    public var summary: Bool
    public var languages: [SpeechLanguage]
    /// The user alone, thinking out loud (call.json `kind`): one speaker and its own kind of summary.
    public var reflection = false

    public init(profile: String = "", names: String = "", topic: String = "", terms: String = "",
                summary: Bool = true, languages: [SpeechLanguage] = [.ru]) {
        self.profile = profile
        self.names = names
        self.topic = topic
        self.terms = terms
        self.summary = summary
        self.languages = languages
    }
}

/// Track offsets and durations on the shared capture clock (call.json → audio).
public struct AudioTimes: Equatable, Sendable {
    public var micStart: Double?
    public var systemStart: Double?
    public var micSeconds: Double = 0
    public var systemSeconds: Double = 0

    public init(micStart: Double? = nil, systemStart: Double? = nil, micSeconds: Double = 0, systemSeconds: Double = 0) {
        self.micStart = micStart
        self.systemStart = systemStart
        self.micSeconds = micSeconds
        self.systemSeconds = systemSeconds
    }

    public var dictionary: [String: Double] {
        var d: [String: Double] = [:]
        if let micStart { d["mic_start"] = micStart; d["mic_seconds"] = micSeconds }
        if let systemStart { d["system_start"] = systemStart; d["system_seconds"] = systemSeconds }
        return d
    }

    public init(_ d: [String: Any]) {
        micStart = d["mic_start"] as? Double
        systemStart = d["system_start"] as? Double
        micSeconds = d["mic_seconds"] as? Double ?? 0
        systemSeconds = d["system_seconds"] as? Double ?? 0
    }

    public var duration: Double { max(micSeconds, systemSeconds) }
}

public enum CallStatus: String, Sendable {
    case recorded, processing, done, failed
}

/// call.json: metadata and the permanent call id. Written atomically (temp file plus replace),
/// preserving fields the engine added, under the `call.json.lock` flock the engine takes too.
public enum CallFile {
    public static let schema = 1
    public static let name = "call.json"
    public static let lockName = "call.json.lock"

    /// Call id from the folder name (for folders without an id in
    /// call.json): "2026-11-04 15-01" or "2026-11-04 15-01-2".
    public static func id(of dir: URL) -> String { CallFolder.id(fromName: dir.lastPathComponent) }

    /// Permanent id: from call.json, otherwise from the folder name.
    public static func callID(_ dir: URL) -> String {
        if let id = read(dir)["id"] as? String, !id.isEmpty { return id }
        return id(of: dir)
    }

    public static func exists(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    public static func read(_ dir: URL) -> [String: Any] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    @discardableResult
    public static func update(_ dir: URL, _ change: (inout [String: Any]) -> Void) -> Bool {
        (try? edit(dir, strict: false) { c -> Bool in
            change(&c)
            return true
        }) ?? false
    }

    /// Read-modify-write under the lock. `change` returns whether to write; a throw writes nothing.
    /// `strict`: an existing call.json that is not a JSON object is never replaced (CallFileError.corrupt);
    /// otherwise it is treated as empty, as `update` always did.
    @discardableResult
    public static func edit(_ dir: URL, strict: Bool = true, _ change: (inout [String: Any]) throws -> Bool) throws -> Bool {
        let file = dir.appendingPathComponent(name)
        // FileLock creates missing folders: never bring back a call folder that is gone (moved to the Trash).
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try FileLock.with(file) {
            var c: [String: Any] = [:]
            if let d = try? Data(contentsOf: file) {
                if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { c = o }
                else if strict { throw CallFileError.corrupt }
            }
            guard try change(&c) else { return false }
            let data = try JSONSerialization.data(withJSONObject: c, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
            return true
        }
    }

    /// On recording stop: schema, id, start time, tracks, "recorded" status.
    @discardableResult
    public static func recordStopped(_ dir: URL, startedAt: Date, audio: AudioTimes) -> Bool {
        update(dir) { c in
            c["schema"] = schema
            // The id was assigned when the folder was created
            // (CallFolder.create): don't overwrite it by parsing the name.
            if (c["id"] as? String)?.isEmpty ?? true { c["id"] = id(of: dir) }
            c["created_at"] = ISO8601DateFormatter().string(from: startedAt)
            c["audio"] = audio.dictionary
            c["status"] = CallStatus.recorded.rawValue
        }
    }

    /// Everything written right after a recording stops: status and audio times, the answers. False if any write
    /// failed (full disk, folder gone): the caller must tell the user. The audio files are never touched.
    @discardableResult
    public static func saveStopped(_ dir: URL, startedAt: Date, audio: AudioTimes, info: CallInfo) -> Bool {
        let stopped = recordStopped(dir, startedAt: startedAt, audio: audio)
        let answers = writeInfo(dir, info)
        return stopped && answers
    }

    /// Answers from the "What was the call about" window: the engine reads them from call.json, not from arguments.
    @discardableResult
    public static func writeInfo(_ dir: URL, _ i: CallInfo) -> Bool {
        update(dir) { c in
            if (c["id"] as? String)?.isEmpty ?? true { c["id"] = id(of: dir) }
            apply(i, to: &c)
        }
    }

    public static func apply(_ i: CallInfo, to c: inout [String: Any]) {
        c["schema"] = schema
        c["profile"] = i.profile
        c["names"] = splitList(i.names)
        c["topic"] = i.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        c["terms"] = i.terms.trimmingCharacters(in: .whitespacesAndNewlines)
        c["languages"] = SpeechLanguage.serialize(i.languages)
        c["summary"] = i.summary
        c["kind"] = i.reflection ? "reflection" : nil
    }

    @discardableResult
    public static func setStatus(_ dir: URL, _ s: CallStatus) -> Bool {
        update(dir) { $0["status"] = s.rawValue }
    }

    /// A run stopped or died: `failed`, unless the engine had already finished the call (`done`), as it has during the
    /// optional listening file at the end of a run.
    @discardableResult
    public static func setFailedUnlessDone(_ dir: URL) -> Bool {
        update(dir) { c in
            if c["status"] as? String != CallStatus.done.rawValue { c["status"] = CallStatus.failed.rawValue }
        }
    }

    /// "Later" in the call prompt: the call waits for its description (`info_pending: true`, contract section 4).
    /// `false` removes the field: the call was transcribed or the user chose not to.
    @discardableResult
    public static func setInfoPending(_ dir: URL, _ pending: Bool) -> Bool {
        update(dir) { c in
            if pending { c[PendingInfo.key] = true } else { c.removeValue(forKey: PendingInfo.key) }
        }
    }

    /// Answers from call.json. A missing field gets the default value (`fallback`).
    public static func info(_ c: [String: Any], fallback: CallInfo = CallInfo()) -> CallInfo {
        var i = fallback
        if let p = c["profile"] as? String { i.profile = p }
        if let n = c["names"] as? [String] { i.names = n.joined(separator: ", ") }
        else if let n = c["names"] as? String { i.names = n }
        if let t = c["topic"] as? String { i.topic = t }
        if let t = c["terms"] as? String { i.terms = t }
        if let l = c["languages"] as? String { i.languages = SpeechLanguage.parse(l) }
        if let s = c["summary"] as? Bool { i.summary = s }
        i.reflection = c["kind"] as? String == "reflection"
        return i
    }
}

/// Folder for a new recording. Two recordings in the same minute must not share a folder: the second one's
/// tracks overwrote the first, and a failed start deleted someone else's folder. So the second recording's id
/// gets a suffix, "2026-11-04 15-01-2" (the third "-3", and so on). The first recording of a minute keeps the
/// old format, so old folders and their ids don't change. The
/// id is written to call.json as soon as the folder is created.
public enum CallFolder {
    /// "2026-11-04 15-01" in local time.
    public static func baseID(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// Id from the start of the folder name: a "yyyy-MM-dd HH-mm" date and an optional "-N" suffix,
    /// followed by the end of the name or a space. Not a date: the first 16 characters, as before.
    public static func id(fromName name: String) -> String {
        let c = Array(name)
        guard c.count >= 16, Call.parseID(name) != nil else { return String(name.prefix(16)) }
        var end = 16
        if c.count > 17, c[16] == "-" {
            var j = 17
            while j < c.count, c[j].isASCII, c[j].isNumber { j += 1 }
            if j > 17, j == c.count || c[j] == " " { end = j }
        }
        return String(c[0..<end])
    }

    /// Ids of all calls in the folder (from call.json, otherwise from the name).
    public static func ids(in root: URL) -> Set<String> {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return Set(dirs.filter(\.hasDirectoryPath).map { CallFile.callID($0) })
    }

    /// Create a folder with a new id and call.json (schema, id, start time). Doesn't accept an existing
    /// folder: mkdir without intermediate directories fails, and then we try the next suffix.
    public static func create(in root: URL, at date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = baseID(for: date)
        let taken = ids(in: root)
        for n in 1...999 {
            let id = n == 1 ? base : "\(base)-\(n)"
            if taken.contains(id) { continue }
            let dir = root.appendingPathComponent(id, isDirectory: true)
            guard mkdir(dir.path, 0o755) == 0 else {
                if errno == EEXIST { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let ok = CallFile.update(dir) { c in
                c["schema"] = CallFile.schema
                c["id"] = id
                c["created_at"] = ISO8601DateFormatter().string(from: date)
            }
            guard ok else {
                discardIfUnused(dir)
                throw POSIXError(.EIO)
            }
            return dir
        }
        throw POSIXError(.EEXIST)
    }

    /// Recording didn't start: remove the just-created folder if it contains nothing but call.json.
    /// A folder with tracks or foreign files is left alone. Returns whether it was removed.
    @discardableResult
    public static func discardIfUnused(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path),
              items.allSatisfy({ $0 == CallFile.name || $0 == CallFile.lockName || $0 == ".DS_Store" }) else { return false }
        for i in items { try? fm.removeItem(at: dir.appendingPathComponent(i)) }
        return rmdir(dir.path) == 0
    }
}

/// Call folder name: "2026-11-04 15-01 · Acme · launch · Anna, Ivan". The start (the id) never changes,
/// so a repeated rename takes only the date from the old name.
/// No "/", ":" or "\" (they break paths and Finder), no newlines, at most 120 characters.
/// `people`: who took part (CallParticipants.list of call.json); nil uses the typed names of `i`.
public func callDirName(_ current: String, _ i: CallInfo, projectTitle: String?, people: [String]? = nil) -> String {
    var parts = [CallFolder.id(fromName: current)]
    if let t = projectTitle?.trimmingCharacters(in: .whitespaces), !t.isEmpty { parts.append(t) }
    let topic = i.topic.trimmingCharacters(in: .whitespacesAndNewlines)
    if !topic.isEmpty { parts.append(topic) }
    // Five or six participants don't fit: three names and "+N", the full list is in call.json.
    let names = shortPeople((people ?? splitList(i.names)).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, max: 3)
    if !names.isEmpty { parts.append(names) }
    let bad = CharacterSet(charactersIn: "/:\\")
    let joined = parts.joined(separator: " · ")
        .components(separatedBy: bad).joined(separator: "-")
        .components(separatedBy: .newlines).joined(separator: " ")
        .replacingOccurrences(of: "\t", with: " ")
    var name = String(joined.prefix(120))
    // Truncation may have left a dangling "… ·" separator.
    while let last = name.last, last == " " || last == "·" { name.removeLast() }
    return name
}

/// Same, using the project list (name by slug from `i.profile`).
public func callDirName(_ current: String, _ i: CallInfo, projects: [Project], people: [String]? = nil) -> String {
    callDirName(current, i, projectTitle: projects.first { $0.slug == i.profile }?.shortTitle, people: people)
}
