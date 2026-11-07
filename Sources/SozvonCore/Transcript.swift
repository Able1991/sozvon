// Transcript lines and edits: "[MM:SS] Name: text" (transcript.txt) and "**[MM:SS] Name:** text"
// (transcript.md), both written by the engine (pipeline/render.py). Pure text functions plus
// file edits for one call folder: renaming a speaker and fixing a misheard word.

import Foundation

/// One transcript paragraph: start (seconds from the start of the call), speaker label, text.
public struct TranscriptLine: Equatable, Hashable, Sendable {
    public var start: TimeInterval
    public var speaker: String
    public var text: String

    public init(start: TimeInterval, speaker: String, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }
}

public enum Transcript {
    /// "05:07" -> 307, "1:02:03" and "01:02:03" -> 3723. Anything else: nil.
    public static func timestamp(_ s: some StringProtocol) -> TimeInterval? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let nums = parts.compactMap { Int($0) }
        // Minutes and seconds after the first field are two digits (render.py pads them).
        guard nums.count == parts.count, parts.dropFirst().allSatisfy({ $0.count == 2 }),
              nums.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return TimeInterval(nums.reduce(0) { $0 * 60 + $1 })
    }

    /// A transcript line in either format, otherwise nil. `prefix` is everything before the text.
    public static func parse(_ raw: String) -> (line: TranscriptLine, prefix: String)? {
        var s = Substring(raw)
        let bold = s.hasPrefix("**[")
        if bold { s = s.dropFirst(2) }
        guard s.hasPrefix("["), let close = s.firstIndex(of: "]"),
              let start = timestamp(s[s.index(after: s.startIndex)..<close]) else { return nil }
        var rest = s[s.index(after: close)...]
        guard rest.hasPrefix(" ") else { return nil }
        rest = rest.dropFirst()
        let sep = bold ? ":** " : ": "
        let sepEnd = bold ? ":**" : ":"
        let speaker: Substring
        let text: Substring
        if let r = rest.range(of: sep) {
            speaker = rest[..<r.lowerBound]
            text = rest[r.upperBound...]
        } else if rest.hasSuffix(sepEnd) {
            speaker = rest.dropLast(sepEnd.count)
            text = ""
        } else {
            return nil
        }
        guard !speaker.isEmpty, !speaker.hasPrefix(" ") else { return nil }
        let prefix = String(raw.dropLast(text.count))
        return (TranscriptLine(start: start, speaker: String(speaker), text: String(text)), prefix)
    }

    public static func lines(_ text: String) -> [TranscriptLine] {
        text.components(separatedBy: "\n").compactMap { parse($0)?.line }
    }

    /// Index of the line being played at `time`: the last one that started at or before it.
    /// `starts` is in transcript order (non-decreasing). Before the first line: nil.
    public static func lineIndex(at time: TimeInterval, starts: [TimeInterval]) -> Int? {
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// A speaker label that keeps the format readable: trimmed, non-empty, no ":", "*", "[" or line breaks.
    public static func cleanSpeaker(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 80, !t.contains(where: { ":*[]\n\r\t".contains($0) }) else { return nil }
        return t
    }

    /// Rename a speaker everywhere in a transcript (either format), plus the participant list in the
    /// transcript.md header ("Duration: 05:00 · People: Anna, Me"). Other text is left as is.
    public static func renameSpeaker(_ text: String, from old: String, to new: String) -> String {
        var seenLine = false
        let out = text.components(separatedBy: "\n").map { raw -> String in
            if let (line, prefix) = parse(raw) {
                seenLine = true
                guard line.speaker == old else { return raw }
                let bold = prefix.hasPrefix("**")
                let ts = String(prefix.dropFirst(bold ? 2 : 0).prefix { $0 != "]" }) + "]"
                let head = (bold ? "**" : "") + ts + " " + new + (bold ? ":**" : ":")
                return line.text.isEmpty ? head : head + " " + line.text
            }
            return seenLine ? raw : renamePeople(raw, from: old, to: new)
        }
        return out.joined(separator: "\n")
    }

    /// "Длительность: 05:00 · Участники: Анна, Я" with `old` replaced in the list after the last label.
    static func renamePeople(_ raw: String, from old: String, to new: String) -> String {
        guard let dot = raw.range(of: " · ", options: .backwards),
              let first = raw.range(of: ": "), first.upperBound <= dot.lowerBound,
              timestamp(raw[first.upperBound..<dot.lowerBound]) != nil,
              let colon = raw.range(of: ": ", range: dot.upperBound..<raw.endIndex) else { return raw }
        let names = raw[colon.upperBound...].components(separatedBy: ", ")
        guard names.contains(old) else { return raw }
        var seen = Set<String>()
        let renamed = names.map { $0 == old ? new : $0 }.filter { seen.insert($0).inserted }
        return String(raw[..<colon.upperBound]) + renamed.joined(separator: ", ")
    }

    /// Swap two speakers everywhere (both mixed up, e.g. two Alexanders): every `a` line becomes `b` and back,
    /// and the two names swap places in the transcript.md participant list.
    public static func swapSpeakers(_ text: String, _ a: String, _ b: String) -> String {
        guard a != b else { return text }
        // Through a placeholder that can't be a speaker label (cleanSpeaker forbids ":").
        let tmp = "\u{1}swap:" + UUID().uuidString
        return renameSpeaker(renameSpeaker(renameSpeaker(text, from: a, to: tmp), from: b, to: a), from: tmp, to: b)
    }

    /// Give one line (the `occurrence`-th line equal to `target`) to another speaker; the participant list in
    /// the transcript.md header is rebuilt from the lines. -> the new transcript, or nil when there is no such line.
    public static func reassign(_ text: String, line target: TranscriptLine, occurrence: Int = 0, to new: String) -> String? {
        guard target.speaker != new, occurrence >= 0 else { return nil }
        var rows = text.components(separatedBy: "\n")
        var seen = 0
        var done = false
        for i in rows.indices {
            guard let (line, prefix) = parse(rows[i]), line == target else { continue }
            if seen < occurrence { seen += 1; continue }
            let bold = prefix.hasPrefix("**")
            let ts = String(prefix.dropFirst(bold ? 2 : 0).prefix { $0 != "]" }) + "]"
            let head = (bold ? "**" : "") + ts + " " + new + (bold ? ":**" : ":")
            rows[i] = line.text.isEmpty ? head : head + " " + line.text
            done = true
            break
        }
        guard done else { return nil }
        return syncPeople(rows.joined(separator: "\n"))
    }

    /// The "Duration: 05:00 · People: A, B" header line with the people list rebuilt from the speakers, in the
    /// order they first speak. Text without such a header (transcript.txt) is returned as is.
    static func syncPeople(_ text: String) -> String {
        var rows = text.components(separatedBy: "\n")
        var speakers: [String] = []
        for r in rows { if let (l, _) = parse(r), !speakers.contains(l.speaker) { speakers.append(l.speaker) } }
        for i in rows.indices {
            if parse(rows[i]) != nil { break }
            let raw = rows[i]
            guard let dot = raw.range(of: " · ", options: .backwards),
                  let first = raw.range(of: ": "), first.upperBound <= dot.lowerBound,
                  timestamp(raw[first.upperBound..<dot.lowerBound]) != nil,
                  let colon = raw.range(of: ": ", range: dot.upperBound..<raw.endIndex) else { continue }
            rows[i] = String(raw[..<colon.upperBound]) + speakers.joined(separator: ", ")
            break
        }
        return rows.joined(separator: "\n")
    }

    /// Renaming `old` to `new` merges two speakers: `new` already speaks in the call.
    public static func renameMerges(_ lines: [TranscriptLine], from old: String, to new: String) -> Bool {
        guard let n = cleanSpeaker(new), n != old else { return false }
        return lines.contains { $0.speaker == n }
    }

    /// `word` as a whole word or phrase, Unicode-aware like the engine's replacements: no letter, digit or
    /// "_" right before or after it ("кот" is not in "который").
    static func wholeWord(_ word: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: word)
                                 + #"(?![\p{L}\p{N}_])"#)
    }

    /// Whether `text` has `word` as a whole word.
    public static func containsWord(_ text: String, _ word: String) -> Bool {
        guard !word.isEmpty, let re = wholeWord(word) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// `text` with every whole-word `wrong` replaced by `right`, or nil when there is none.
    public static func replaceWord(_ text: String, _ wrong: String, with right: String) -> String? {
        guard containsWord(text, wrong), let re = wholeWord(wrong) else { return nil }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: right))
    }

    /// Replace the whole word `wrong` with `right` in the text of one line (its speaker label untouched):
    /// the `occurrence`-th line (from 0) equal to `line`, so a repeated line ("Да.") edits the one clicked.
    /// -> the new transcript, or nil when there is no such line or the line has no `wrong`.
    public static func fix(_ text: String, line target: TranscriptLine, occurrence: Int = 0,
                           wrong: String, right: String) -> String? {
        guard !wrong.isEmpty, wrong != right, occurrence >= 0 else { return nil }
        var rows = text.components(separatedBy: "\n")
        var seen = 0
        for i in rows.indices {
            guard let (line, prefix) = parse(rows[i]), line == target else { continue }
            if seen < occurrence { seen += 1; continue }
            guard let fixed = replaceWord(line.text, wrong, with: right) else { return nil }
            rows[i] = prefix + fixed
            return rows.joined(separator: "\n")
        }
        return nil
    }
}

/// Track start offsets for playback, the same rule as the engine (pipeline/tracks.py `delays`):
/// each track starts this many seconds after the earliest one. Transcript times are on this timeline.
public struct TrackOffsets: Equatable, Sendable {
    public var mic: Double
    public var system: Double

    public init(_ a: AudioTimes) {
        let starts = [a.micStart, a.systemStart].compactMap { $0 }
        let t0 = starts.min() ?? 0
        mic = (a.micStart ?? t0) - t0
        system = (a.systemStart ?? t0) - t0
    }

    /// From call.json `audio`, otherwise meta.json (old calls), like the engine's calls.audio_meta.
    public static func times(of dir: URL) -> AudioTimes {
        if let a = CallFile.read(dir)["audio"] as? [String: Any], !a.isEmpty { return AudioTimes(a) }
        if let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return AudioTimes(o) }
        return AudioTimes()
    }
}

public enum TranscriptEditError: Error, Equatable {
    case badName, notFound, busy
}

/// Edits of a call's transcript.md and transcript.txt. Written atomically (temp file plus rename): the search
/// index and the Calls window pick them up by mtime, and server sync re-sends the call because its content
/// hash covers transcript.txt and call.json. summary.md is not regenerated.
public enum TranscriptEdit {
    public static let files = ["transcript.md", "transcript.txt"]

    /// Rename a speaker label in both files and in call.json `names`. -> whether anything changed.
    @discardableResult
    public static func renameSpeaker(in dir: URL, from old: String, to newName: String) throws -> Bool {
        guard let new = Transcript.cleanSpeaker(newName) else { throw TranscriptEditError.badName }
        guard new != old else { return false }
        var changed = false
        for f in files {
            let url = dir.appendingPathComponent(f)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let out = Transcript.renameSpeaker(text, from: old, to: new)
            if out != text {
                try out.write(to: url, atomically: true, encoding: .utf8)
                changed = true
            }
        }
        guard changed else { throw TranscriptEditError.notFound }
        if CallFile.exists(dir) {
            try CallFile.edit(dir) { c in
                guard let names = c["names"] as? [String], names.contains(old) else { return false }
                var seen = Set<String>()
                c["names"] = names.map { $0 == old ? new : $0 }.filter { seen.insert($0).inserted }
                return true
            }
        }
        return true
    }

    /// Swap two speakers in both files and in call.json `names` (their order there). -> whether anything changed.
    @discardableResult
    public static func swapSpeakers(in dir: URL, _ a: String, _ b: String) throws -> Bool {
        guard a != b else { return false }
        var changed = false
        for f in files {
            let url = dir.appendingPathComponent(f)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let out = Transcript.swapSpeakers(text, a, b)
            if out != text {
                try out.write(to: url, atomically: true, encoding: .utf8)
                changed = true
            }
        }
        guard changed else { throw TranscriptEditError.notFound }
        if CallFile.exists(dir) {
            try CallFile.edit(dir) { c in
                guard let names = c["names"] as? [String], names.contains(a) || names.contains(b) else { return false }
                c["names"] = names.map { $0 == a ? b : $0 == b ? a : $0 }
                return true
            }
        }
        return true
    }

    /// Give one line to another speaker in both files (`occurrence` as in Transcript.fix). A new name reaches
    /// call.json `names` through CallParticipants.update. -> whether anything changed.
    @discardableResult
    public static func reassignLine(in dir: URL, line: TranscriptLine, occurrence: Int = 0, to newName: String) throws -> Bool {
        guard let new = Transcript.cleanSpeaker(newName) else { throw TranscriptEditError.badName }
        guard new != line.speaker else { return false }
        var changed = false
        for f in files {
            let url = dir.appendingPathComponent(f)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let out = Transcript.reassign(text, line: line, occurrence: occurrence, to: new) else { continue }
            try out.write(to: url, atomically: true, encoding: .utf8)
            changed = true
        }
        guard changed else { throw TranscriptEditError.notFound }
        return true
    }

    /// Fix a word or phrase in one line of both files (`occurrence`: which of the equal lines, see Transcript.fix).
    /// -> whether anything changed.
    @discardableResult
    public static func fixWord(in dir: URL, line: TranscriptLine, occurrence: Int = 0, wrong: String, right: String) throws -> Bool {
        let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrong.isEmpty, !right.isEmpty, !right.contains("\n") else { throw TranscriptEditError.badName }
        var changed = false
        for f in files {
            let url = dir.appendingPathComponent(f)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let out = Transcript.fix(text, line: line, occurrence: occurrence, wrong: wrong, right: right) else { continue }
            try out.write(to: url, atomically: true, encoding: .utf8)
            changed = true
        }
        guard changed else { throw TranscriptEditError.notFound }
        return true
    }
}

/// Auto-replacements the engine applies to new transcripts ("wrong" -> "right", whole words, ignoring case):
/// `replacements` in profiles/<slug>.json or in the shared vocab.json. Same rules as the engine's
/// vocab.set_replacement: an entry with the same left side (ignoring case) gets the new right side.
/// Read-modify-write under the `<file>.lock` flock the engine and MCP take; atomic write.
public enum ReplacementStore {
    public enum Failure: Error, Equatable { case empty, noProject, corrupt }

    public static func vocabURL(data: URL = Paths.data) -> URL { data.appendingPathComponent("vocab.json") }

    public static func projectURL(_ slug: String, profiles: URL = Paths.profiles) -> URL? {
        Project.isValidSlug(slug) ? profiles.appendingPathComponent("\(slug).json") : nil
    }

    /// Add to a project (must exist) or, with an empty slug, to the shared vocabulary (created if missing).
    public static func add(wrong: String, right: String, project slug: String,
                           data: URL = Paths.data, profiles: URL = Paths.profiles) throws {
        if slug.isEmpty {
            try add(wrong: wrong, right: right, to: vocabURL(data: data), create: true)
        } else {
            guard let url = projectURL(slug, profiles: profiles) else { throw Failure.noProject }
            try add(wrong: wrong, right: right, to: url, create: false)
        }
    }

    public static func add(wrong: String, right: String, to url: URL, create: Bool) throws {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty else { throw Failure.empty }
        try FileLock.with(url) {
            var o: [String: Any] = [:]
            if let d = try? Data(contentsOf: url) {
                guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw Failure.corrupt }
                o = obj
            } else if !create {
                throw Failure.noProject
            }
            o["schema"] = 1
            o["replacements"] = set(o["replacements"] as? [Any] ?? [], wrong: w, right: r)
            let data = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
        }
    }

    /// vocab.set_replacement: overwrite the first entry with the same left side, drop later duplicates, else append.
    static func set(_ existing: [Any], wrong: String, right: String) -> [Any] {
        func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
        var out: [Any] = []
        var found = false
        for p in existing {
            if let pair = p as? [String], pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty, key(pair[0]) == key(wrong) {
                if !found { out.append([wrong, right]); found = true }
                continue
            }
            out.append(p)
        }
        if !found { out.append([wrong, right]) }
        return out
    }
}
