// Кеши окна «Звонки»: тексты саммари и расшифровок для поиска и размеры папок.
// Перечитываются только при смене файла (путь и время изменения). Вызывать не с главного потока.

import Foundation
import os

/// Тексты для поиска в нижнем регистре по (путь, mtime): поиск не читает все файлы на каждое нажатие.
public final class CallTextCache: Sendable {
    public static let shared = CallTextCache()

    private struct Entry { let mtime: Date; let text: String }
    private let entries = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    public init() {}

    /// Текст файла в нижнем регистре; нет файла: nil.
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

    /// id звонков, в файлах которых есть `query` (уже в нижнем регистре). Прерывается отменой задачи.
    public func matching(_ query: String, in files: [(id: String, urls: [URL])]) -> Set<String> {
        var out: Set<String> = []
        for f in files {
            if Task.isCancelled { break }
            if f.urls.contains(where: { text($0)?.contains(query) == true }) { out.insert(f.id) }
        }
        return out
    }

    /// Забыть файлы, которых больше нет в списке (удалённые звонки).
    public func retain(_ paths: Set<String>) {
        entries.withLock { $0 = $0.filter { paths.contains($0.key) } }
    }
}

/// Размер папки звонка по (путь, mtime папки). Атомарная запись файла (временный и rename)
/// меняет mtime папки, поэтому готовые звонки не пересчитываются при каждом открытии.
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
