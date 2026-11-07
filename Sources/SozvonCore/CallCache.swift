// Caches for the "Calls" window: summary and transcript texts for search, and folder sizes.
// Reloaded only when a file changes (path and modification time). Don't call from the main thread.

import Foundation
import os

/// Lowercased search texts keyed by (path, mtime), so search doesn't read every file on each keystroke.
public final class CallTextCache: Sendable {
    public static let shared = CallTextCache()

    private struct Entry { let mtime: Date; let text: String }
    private let entries = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    public init() {}

    /// Lowercased file text; no file: nil.
    public func text(_ url: URL) -> String? {
        let path = url.path
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
            entries.withLock { $0[path] = nil }
            return nil
        }
        if let e = entries.withLock({ $0[path] }), e.mtime == mtime { return e.text }
        guard let t = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lower = t.lowercased()
        entries.withLock { $0[path] = Entry(mtime: mtime, text: lower) }
        return lower
    }

    /// Ids of calls whose files contain `query` (already lowercased). Stops on task cancellation.
    public func matching(_ query: String, in files: [(id: String, urls: [URL])]) -> Set<String> {
        var out: Set<String> = []
        for f in files {
            if Task.isCancelled { break }
            if f.urls.contains(where: { text($0)?.contains(query) == true }) { out.insert(f.id) }
        }
        return out
    }

    /// Forget files that are no longer in the list (deleted calls).
    public func retain(_ paths: Set<String>) {
        entries.withLock { $0 = $0.filter { paths.contains($0.key) } }
    }
}

/// Call folder size keyed by (path, folder mtime). An atomic file write (temp file plus rename)
/// changes the folder mtime, so finished calls aren't recomputed on every open.
public final class FolderSizeCache: Sendable {
    public static let shared = FolderSizeCache()

    private struct Entry { let mtime: Date; let bytes: Int64 }
    private let entries = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    public init() {}

    public func size(_ dir: URL) -> Int64 {
        let path = dir.path
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
        if let e = entries.withLock({ $0[path] }), e.mtime == mtime { return e.bytes }
        let bytes = Call.folderSize(dir)
        entries.withLock { $0[path] = Entry(mtime: mtime, bytes: bytes) }
        return bytes
    }
}
