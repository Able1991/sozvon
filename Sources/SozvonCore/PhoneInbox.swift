// Recordings from the phone: a folder (iCloud Drive or any other) the user saves voice memos into. Sozvon imports
// each new audio file and transcribes it. This is the UI-free part: which files are ready and where they go after.

import Foundation

public enum PhoneInbox {
    public static let pathKey = "phoneInboxPath"
    /// Inside the watched folder: imported files stay here, nothing is deleted.
    public static let doneFolder = "Imported"
    /// Files that could not be imported, so they are not tried again and again.
    public static let failedFolder = "Failed"
    /// A file changed more recently than this may still be arriving.
    public static let settle: TimeInterval = 10

    public static var folder: URL? {
        get {
            guard let p = UserDefaults.standard.string(forKey: pathKey), !p.isEmpty else { return nil }
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: pathKey) }
    }

    public struct Scan: Equatable, Sendable {
        /// Complete audio files, oldest first.
        public var ready: [URL] = []
        /// iCloud placeholders (".name.m4a.icloud") of audio files: to be downloaded first.
        public var notDownloaded: [URL] = []
    }

    public static func scan(_ dir: URL, now: Date = Date()) -> Scan {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        var out = Scan()
        var dated: [(URL, Date)] = []
        for u in items {
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true else { continue }
            let name = u.lastPathComponent
            if name.hasPrefix(".") {
                if let real = realFile(ofPlaceholder: u), CallImport.isSupported(real) { out.notDownloaded.append(u) }
                continue
            }
            guard CallImport.isSupported(u) else { continue }
            let changed = v?.contentModificationDate ?? now
            if now.timeIntervalSince(changed) >= settle { dated.append((u, changed)) }
        }
        out.ready = dated.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.lastPathComponent < $1.0.lastPathComponent }.map(\.0)
        out.notDownloaded.sort { $0.lastPathComponent < $1.lastPathComponent }
        return out
    }

    /// The docs on recording in one tap with the iPhone shortcut, in the interface language.
    public static func shortcutDocsURL(language: String = Engine.uiLanguage) -> URL {
        URL(string: "https://able1991.github.io/sozvon/docs.html#\(language == "en" ? "en-" : "")phone-shortcut")!
    }

    /// ".Note.m4a.icloud" -> "Note.m4a" beside it; nil for anything else.
    public static func realFile(ofPlaceholder u: URL) -> URL? {
        let n = u.lastPathComponent
        guard n.hasPrefix("."), n.hasSuffix(".icloud"), n.count > ".icloud".count + 1 else { return nil }
        return u.deletingLastPathComponent().appendingPathComponent(String(n.dropFirst().dropLast(".icloud".count)))
    }

    /// Into a subfolder of its folder (or of `root`), never over another file ("a.m4a", then "a 2.m4a"). -> where it went.
    @discardableResult
    public static func moveAside(_ file: URL, to folder: String, in root: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let dir = (root ?? file.deletingLastPathComponent()).appendingPathComponent(folder, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
        var target = dir.appendingPathComponent(file.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(stem) \(n)").appendingPathExtension(ext)
            n += 1
        }
        try fm.moveItem(at: file, to: target)
        return target
    }

    /// The call's topic: the name the user gave the memo; a default name or a bare date says nothing.
    public static func topic(of file: URL) -> String {
        let name = file.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespaces)
        let generic = #"^(?i:new recording|новая запись|think out loud)( \d+)?$"#  // l10n-ignore
        if name.range(of: generic, options: .regularExpression) != nil { return "" }
        if name.allSatisfy({ $0.isNumber || " -_.:".contains($0) }) { return "" }
        return name
    }
}
