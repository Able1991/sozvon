// Transcription queue: which folders are being processed now and which are waiting for an engine update.

import Foundation

public struct ProcessingQueue: Sendable {
    public enum Admission: Equatable, Sendable {
        /// Run now.
        case start
        /// The engine is updating: will run after the update.
        case queued
        /// This folder is already being transcribed or is waiting: a second run broke the output.
        case duplicate
    }

    public private(set) var active: Set<String> = []
    public private(set) var pending: [URL] = []
    /// An engine environment update is running: new transcriptions wait.
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

    /// A transcription finished (successfully or not).
    public mutating func finish(_ dir: URL) {
        active.remove(Self.key(dir))
    }

    /// An engine update started: new transcriptions wait.
    public mutating func beginEngineUpdate() -> Bool {
        guard !engineUpdating else { return false }
        engineUpdating = true
        return true
    }

    /// The update finished: return the waiting folders (they must be passed to admit again).
    public mutating func endEngineUpdate() -> [URL] {
        engineUpdating = false
        defer { pending = [] }
        return pending
    }

    static func key(_ dir: URL) -> String { dir.standardizedFileURL.path }
}
