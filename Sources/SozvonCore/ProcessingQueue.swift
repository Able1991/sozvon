// Очередь расшифровок: какие папки сейчас обрабатываются и какие ждут обновления движка.

import Foundation

public struct ProcessingQueue: Sendable {
    public enum Admission: Equatable, Sendable {
        /// Запускать сейчас.
        case start
        /// Движок обновляется: запустится после обновления.
        case queued
        /// Эта папка уже расшифровывается или ждёт: второй запуск ломал вывод.
        case duplicate
    }

    public private(set) var active: Set<String> = []
    public private(set) var pending: [URL] = []
    /// Идёт обновление окружения движка: новые расшифровки ждут.
    public private(set) var engineUpdating = false

    public init() {}

    public var count: Int { active.count }
    public var isEmpty: Bool { active.isEmpty && pending.isEmpty }

    public func contains(_ dir: URL) -> Bool {
        active.contains(Self.key(dir)) || pending.contains { Self.key($0) == Self.key(dir) }
    }

    public mutating func admit(_ dir: URL) -> Admission {
        if contains(dir) { return .duplicate }
        if engineUpdating {
            pending.append(dir)
            return .queued
        }
        active.insert(Self.key(dir))
        return .start
    }

    /// Расшифровка закончилась (успешно или нет).
    public mutating func finish(_ dir: URL) {
        active.remove(Self.key(dir))
    }

    /// Обновление движка началось: новые расшифровки ждут.
    public mutating func beginEngineUpdate() -> Bool {
        guard !engineUpdating else { return false }
        engineUpdating = true
        return true
    }

    /// Обновление закончилось: вернуть ожидавшие папки (их нужно снова передать в admit).
    public mutating func endEngineUpdate() -> [URL] {
        engineUpdating = false
        defer { pending = [] }
        return pending
    }

    static func key(_ dir: URL) -> String { dir.standardizedFileURL.path }
}
