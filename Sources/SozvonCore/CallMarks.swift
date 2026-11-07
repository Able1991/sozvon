// "Important" marks made during a recording (panel button, menu, global shortcut).
// call.json → "marks": seconds from the start of the call, on the transcript's timeline (contract, section 4).

import Foundation

public enum CallMarks {
    public static let key = "marks"
    /// Two presses closer than this are one mark (a double click, a held shortcut).
    public static let minGap = 5.0

    /// Capture clock times of the presses → seconds from the call start. The call starts at the earlier
    /// track (the engine's t0, `tracks.delays`); a press before any audio counts as second 0.
    public static func offsets(_ hostTimes: [Double], audio: AudioTimes) -> [Double] {
        let starts = [audio.micStart, audio.systemStart].compactMap { $0 }
        guard let t0 = starts.min() else { return [] }
        var out: [Double] = []
        for t in hostTimes.sorted() {
            let s = (max(0, t - t0) * 10).rounded() / 10
            if let last = out.last, s - last < minGap { continue }
            out.append(s)
        }
        return out
    }

    public static func read(_ c: [String: Any]) -> [Double] {
        ((c[key] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }.filter { $0 >= 0 }.sorted()
    }

    /// Write the marks (nothing when there are none).
    @discardableResult
    public static func write(_ dir: URL, _ marks: [Double]) -> Bool {
        guard !marks.isEmpty else { return true }
        return CallFile.update(dir) { $0[key] = marks }
    }
}

/// "Keep audio": after N days a finished call keeps its transcript and summary, its tracks are deleted.
public enum AudioRetention {
    public static let defaultsKey = "keepAudioDays"
    /// Choices in Settings; 0 = forever.
    public static let choices = [0, 7, 15, 30, 60]
    public static let tracks = ["mic.m4a", "system.m4a"]
    /// The engine's cleaned microphone for listening (echo removed, raised), next to the original.
    public static let cleanMic = "mic.clean.m4a"
    /// call.json: when the tracks were removed (the Calls window explains why there is no player).
    public static let removedKey = "audio_removed_at"

    /// Calls whose audio may go: done, with a transcript, started more than `days` days ago, not busy.
    public static func expired(in root: URL, days: Int, now: Date = Date(), busy: Set<URL> = []) -> [URL] {
        guard days > 0 else { return [] }
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let iso = ISO8601DateFormatter()
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let busyPaths = Set(busy.map(\.standardizedFileURL.path))
        return dirs.filter { d in
            guard d.hasDirectoryPath, !d.lastPathComponent.hasPrefix("."),
                  !busyPaths.contains(d.standardizedFileURL.path) else { return false }
            let c = CallFile.read(d)
            guard c["status"] as? String == CallStatus.done.rawValue,
                  fm.fileExists(atPath: d.appendingPathComponent("transcript.txt").path),
                  let created = (c["created_at"] as? String).flatMap(iso.date(from:)), created < cutoff
            else { return false }
            return tracks.contains { fm.fileExists(atPath: d.appendingPathComponent($0).path) }
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Delete the tracks of one call and note it in call.json. Returns the bytes freed.
    @discardableResult
    public static func removeAudio(_ dir: URL, now: Date = Date()) -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        for t in tracks + [cleanMic] {
            let f = dir.appendingPathComponent(t)
            let size = (try? fm.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.int64Value ?? 0
            if (try? fm.removeItem(at: f)) != nil { freed += size }
        }
        if freed > 0 { CallFile.update(dir) { $0[removedKey] = ISO8601DateFormatter().string(from: now) } }
        return freed
    }
}
