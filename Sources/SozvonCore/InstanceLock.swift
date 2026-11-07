// Locks. One app instance per data folder: two copies would write to the same calls and start
// two engine installs. A flock on <data>/.lock is held while the process lives (the kernel releases it).

import Foundation

public final class InstanceLock: Sendable {
    public let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// Take the lock without waiting. Held by another copy (or the file can't be opened): nil.
    public static func acquire(in data: URL) -> InstanceLock? {
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let fd = open(data.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return InstanceLock(fd: fd)
    }

    /// Release before the process ends (for tests).
    public func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Editing JSON shared with the engine (profiles/<slug>.json, vocab.json): an exclusive flock on a sibling
/// `<file>.lock`, like jsonfile.locked in the engine. A separate file is locked because an atomic write replaces
/// the JSON itself with a new inode. If the lock file can't be opened, nothing runs: an edit without the lock
/// could overwrite what the engine is writing at the same moment.
public enum FileLock {
    public struct Unavailable: Error, LocalizedError, Equatable {
        public let path: String
        public let code: Int32
        public var errorDescription: String? { L("Не открыть файл блокировки %@: %@", path, String(cString: strerror(code))) }
    }

    public static func lockURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".lock")
    }

    public static func with<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = lockURL(for: url).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Unavailable(path: path, code: errno) }
        while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return try body()
    }
}
