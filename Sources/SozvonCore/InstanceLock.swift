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
/// the JSON itself with a new inode. If the lock file can't be
/// opened, edit without it (as before) rather than lose the edit.
public enum FileLock {
    public static func lockURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".lock")
    }

    public static func with<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL(for: url).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if fd >= 0 {
            while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
        }
        defer {
            if fd >= 0 {
                flock(fd, LOCK_UN)
                close(fd)
            }
        }
        return try body()
    }
}
