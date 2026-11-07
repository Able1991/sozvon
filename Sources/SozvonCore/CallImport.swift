// Importing an existing recording as a call: which files are accepted, which date names the folder,
// and the call.json of a one-track call. The audio conversion itself (AVFoundation) lives in the app.

import Foundation

public enum CallImport {
    /// Audio and video files the Calls window accepts (by extension, ignoring case): what AVFoundation opens.
    public static let extensions: Set<String> = ["m4a", "mp3", "wav", "mp4", "mov", "aac", "flac"]
    /// Common recording formats macOS can't read (no ffmpeg in the app): refused with a hint to convert.
    public static let unreadable: Set<String> = ["webm", "ogg", "opus", "oga", "mkv"]

    public static func isSupported(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
    public static func isUnreadable(_ url: URL) -> Bool { unreadable.contains(url.pathExtension.lowercased()) }

    /// When the recording was made: the date written in the file (`recorded`, from its metadata), else the file's
    /// creation date (for a downloaded file that is the download), else its modification date, else now.
    public static func date(of url: URL, recorded: Date? = nil) -> Date {
        if let recorded { return recorded }
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return v?.creationDate ?? v?.contentModificationDate ?? Date()
    }

    /// A creation date from the file's metadata, if it is plausible: QuickTime's empty date is 1904-01-01
    /// and some recorders write 1970; a date in the future is a wrong clock.
    public static func plausible(_ d: Date?, now: Date = Date()) -> Date? {
        guard let d, d > Date(timeIntervalSince1970: 946_684_800), d < now.addingTimeInterval(86_400) else { return nil }  // after 2000
        return d
    }

    /// Metadata date strings: "2026-11-04T15:01:02Z", "2026-11-04T15:01:02+0300", "2026-11-04 15:01:02", "2026-11-04".
    public static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: t) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: t) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    /// A new call folder named by the recording's date ("2026-11-04 15-01", "-2" for a second one that minute).
    public static func createFolder(for file: URL, recorded: Date? = nil, in root: URL = Paths.calls) throws -> URL {
        try CallFolder.create(in: root, at: date(of: file, recorded: recorded))
    }

    /// Hidden temp file of an import in progress (AudioImport writes `.import-<uuid>.m4a`, then renames it).
    public static let tempPrefix = ".import-"

    /// What a crash during an import left behind, to move to the Trash on launch: call folders that hold
    /// nothing but call.json without a status (and its lock, .DS_Store, import temp files), and import temp
    /// files anywhere in a call folder; all older than `maxAge`, so an import or recording starting right
    /// now is never touched. A folder with audio, a transcript or a status is a real call and stays.
    public static func leftovers(in root: URL = Paths.calls, now: Date = Date(), maxAge: TimeInterval = 3600) -> [URL] {
        let fm = FileManager.default
        func old(_ u: URL) -> Bool {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            return now.timeIntervalSince(m) >= maxAge
        }
        var out: [URL] = []
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in dirs.sorted(by: { $0.path < $1.path }) where dir.hasDirectoryPath {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            let temps = names.filter { $0.hasPrefix(tempPrefix) }.map { dir.appendingPathComponent($0) }
            let rest = Set(names).subtracting(temps.map(\.lastPathComponent))
            let bare = names.contains(CallFile.name)
                && rest.isSubset(of: [CallFile.name, CallFile.lockName, ".DS_Store"])
                && CallFile.read(dir)["status"] == nil
            if bare {
                if old(dir.appendingPathComponent(CallFile.name)) && temps.allSatisfy(old) { out.append(dir) }
            } else {
                out += temps.filter(old)
            }
        }
        return out
    }

    /// The imported audio is the system track (system.m4a, the other side) at offset 0, status `recorded`:
    /// the engine treats it as a call with one track (pipeline/tracks.py track_files, delays).
    @discardableResult
    public static func finish(_ dir: URL, recordedAt: Date, seconds: Double) -> Bool {
        CallFile.recordStopped(dir, startedAt: recordedAt, audio: AudioTimes(systemStart: 0, systemSeconds: seconds))
    }
}
