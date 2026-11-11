// Where the calls live: ~/Documents/Calls unless the user picked another folder (the setup assistant or
// Settings > General). A new folder can take the calls along: on the same disk each call folder is renamed;
// on another disk it is copied, the copy is compared with the original, and only then the original goes to
// the Trash. Nothing moves when any name is already taken in the new folder.

import Foundation

public enum CallsFolder {
    /// The same key `Paths.calls` reads (and demos set with `defaults write … callsDir`).
    public static let defaultsKey = "callsDir"

    public static var defaultURL: URL { Paths.home.appendingPathComponent("Documents/Calls") }

    /// The folder the user picked, nil for the default.
    public static func chosen(_ defaults: UserDefaults = .standard) -> URL? {
        guard let p = defaults.string(forKey: defaultsKey), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }

    /// nil: back to the default.
    public static func choose(_ url: URL?, _ defaults: UserDefaults = .standard) {
        if let url { defaults.set(url.path, forKey: defaultsKey) } else { defaults.removeObject(forKey: defaultsKey) }
    }

    public enum Problem: Equatable, Sendable {
        /// The folder in use now.
        case same
        /// Inside the current calls folder: it would look like a call.
        case inside
        /// The current calls folder is inside it: the calls would sit next to their own copies.
        case contains
        /// The engine's own folder or inside it (models, environment): reinstalling the engine would take the calls.
        case engineData
    }

    public static func problem(from old: URL, to new: URL, data: URL) -> Problem? {
        let o = old.standardizedFileURL.resolvingSymlinksInPath().path
        let n = new.standardizedFileURL.resolvingSymlinksInPath().path
        let d = data.standardizedFileURL.resolvingSymlinksInPath().path
        if n == o { return .same }
        if n == d || n.hasPrefix(d + "/") { return .engineData }
        if n.hasPrefix(o + "/") { return .inside }
        if o.hasPrefix(n + "/") { return .contains }
        return nil
    }

    /// Call folders in `root`: folders with a call.json or a recording. Other files and folders are not ours.
    public static func calls(in root: URL) -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        return items.filter { dir in
            guard dir.hasDirectoryPath else { return false }
            if fm.fileExists(atPath: dir.appendingPathComponent("call.json").path) { return true }
            let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            return files.contains { $0.hasSuffix(".m4a") }
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public enum MoveError: Error, Equatable {
        /// These call folder names already exist in the new folder.
        case taken([String])
        /// A copy on the other disk does not match its original (the original stays).
        case copyMismatch(String)
    }

    /// Both folders on one volume: a rename moves a call instantly and cannot leave half a copy.
    public static func onSameVolume(_ a: URL, _ b: URL) -> Bool {
        func volume(_ u: URL) -> NSObject? {
            var url = u
            while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url = url.deletingLastPathComponent() }
            return (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let x = volume(a), let y = volume(b) else { return false }
        return x.isEqual(y)
    }

    /// Move every call folder from `old` into `new` (created if missing). -> how many moved.
    /// `trash` removes an original after its copy checked out (another disk only). `progress(done, total)`.
    @discardableResult
    public static func move(from old: URL, to new: URL, sameVolume: Bool? = nil,
                            trash: (URL) throws -> Void, progress: (Int, Int) -> Void) throws -> Int {
        let fm = FileManager.default
        let items = calls(in: old)
        let taken = items.map(\.lastPathComponent).filter { fm.fileExists(atPath: new.appendingPathComponent($0).path) }
        if !taken.isEmpty { throw MoveError.taken(taken) }
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        let rename = sameVolume ?? onSameVolume(old, new)
        progress(0, items.count)
        for (i, src) in items.enumerated() {
            let dst = new.appendingPathComponent(src.lastPathComponent)
            if rename {
                try fm.moveItem(at: src, to: dst)
            } else {
                try fm.copyItem(at: src, to: dst)
                guard footprint(src) == footprint(dst) else {
                    try? fm.removeItem(at: dst)
                    throw MoveError.copyMismatch(src.lastPathComponent)
                }
                try trash(src)
            }
            progress(i + 1, items.count)
        }
        return items.count
    }

    /// Relative path and size of every file under `dir`: equal for an exact copy.
    static func footprint(_ dir: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        let base = dir.standardizedFileURL.path
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let u = walker?.nextObject() as? URL {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { continue }
            out[String(u.standardizedFileURL.path.dropFirst(base.count))] = v?.fileSize ?? -1
        }
        return out
    }
}
