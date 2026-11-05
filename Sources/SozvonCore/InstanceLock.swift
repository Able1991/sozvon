// Замки. Одна копия приложения на папку данных: две копии писали бы в одни звонки и запускали бы
// две установки движка. Замок flock на <data>/.lock держится, пока жив процесс (ядро снимает его само).

import Foundation

public final class InstanceLock: Sendable {
    public let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// Взять замок без ожидания. Занят другой копией (или не открыть файл): nil.
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

    /// Отпустить раньше конца процесса (для тестов).
    public func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Правка общего с движком JSON (profiles/<slug>.json, vocab.json): исключительный flock на соседнем
/// `<файл>.lock`, как jsonfile.locked в движке. Блокируется отдельный файл: атомарная запись подменяет
/// сам JSON новым inode. Не открылся файл замка: правим без него (как раньше), а не теряем правку.
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
