// Transcription queue: at most one engine run at a time, the rest wait first in, first out. Nothing starts during a
// recording, while a call app holds the microphone (the caller says so with `held`) or during an engine update.
// call.json `queued_at` keeps the waiting calls across a restart (contract section 4).

import Foundation

public struct ProcessingQueue: Sendable {
    public enum Kind: Sendable {
        case transcribe
        /// A new summary from the existing transcript (`process_call.py --summary-only`).
        case summaryOnly
    }

    public struct Job: Equatable, Sendable {
        public let dir: URL
        public let kind: Kind

        public init(dir: URL, kind: Kind) {
            self.dir = dir
            self.kind = kind
        }

        public static func == (a: Job, b: Job) -> Bool { key(a.dir) == key(b.dir) && a.kind == b.kind }
    }

    public enum Admission: Equatable, Sendable {
        /// Waits for its turn (it may be started right away by `startNext`).
        case queued
        /// This folder is already being transcribed or is waiting: a second run broke the output.
        case duplicate
    }

    public private(set) var running: Job?
    public private(set) var waiting: [Job] = []
    /// An engine environment update is running: nothing starts.
    public private(set) var engineUpdating = false

    public init() {}

    public var isEmpty: Bool { running == nil && waiting.isEmpty }
    /// Nothing runs and something waits: worth asking whether a recording or a call holds the queue.
    public var canStartNext: Bool { running == nil && !engineUpdating && !waiting.isEmpty }

    public func contains(_ dir: URL) -> Bool {
        running.map { Self.key($0.dir) == Self.key(dir) } ?? false || isWaiting(dir)
    }

    public func isWaiting(_ dir: URL) -> Bool {
        waiting.contains { Self.key($0.dir) == Self.key(dir) }
    }

    public mutating func admit(_ dir: URL, kind: Kind = .transcribe) -> Admission {
        if contains(dir) { return .duplicate }
        waiting.append(Job(dir: dir, kind: kind))
        return .queued
    }

    /// The next job, moved to `running`. `held`: a recording is starting, running or being saved, its live voice
    /// match is finishing, or a call app holds the microphone: the transcription would load the Mac during the call.
    public mutating func startNext(held: Bool) -> Job? {
        guard canStartNext, !held else { return nil }
        let job = waiting.removeFirst()
        running = job
        return job
    }

    /// A run finished (successfully or not).
    public mutating func finish(_ dir: URL) {
        if let r = running, Self.key(r.dir) == Self.key(dir) { running = nil }
    }

    /// Take a waiting folder out of the queue. A running job stays: it is stopped only with the app.
    @discardableResult
    public mutating func remove(_ dir: URL) -> Bool {
        guard isWaiting(dir) else { return false }
        waiting.removeAll { Self.key($0.dir) == Self.key(dir) }
        return true
    }

    /// An engine update started: nothing starts until it ends.
    public mutating func beginEngineUpdate() -> Bool {
        guard !engineUpdating else { return false }
        engineUpdating = true
        return true
    }

    /// The update finished: the waiting jobs can go on.
    public mutating func endEngineUpdate() {
        engineUpdating = false
    }

    static func key(_ dir: URL) -> String { dir.standardizedFileURL.path }
}

/// The queue in call.json (contract section 4): `queued_at` while waiting, `queued_summary_only` for a summary run,
/// and `retries` for a run interrupted by a crash. All optional, local to this Mac, never synced.
extension CallFile {
    public static let queuedAtKey = "queued_at"
    public static let queuedSummaryOnlyKey = "queued_summary_only"
    public static let retriesKey = "retries"
    /// A run interrupted by a crash goes back in the queue this many times, then the call is `failed`.
    public static let maxRetries = 1

    private static func queuedAtString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        // With milliseconds: two calls queued in the same second keep their order.
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// When the call entered the queue; nil if it is not waiting or the field is broken.
    public static func queuedAt(_ c: [String: Any]) -> Date? {
        guard let s = c[queuedAtKey] as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// `at`: the call starts waiting; nil: it started or was taken out of the queue.
    @discardableResult
    public static func setQueued(_ dir: URL, at date: Date?, summaryOnly: Bool = false) -> Bool {
        update(dir) { c in
            c[queuedAtKey] = date.map(queuedAtString)
            c[queuedSummaryOnlyKey] = date != nil && summaryOnly ? true : nil
        }
    }

    /// The run ended by itself, or the user asked for a new one: the next interruption gets its retry again.
    @discardableResult
    public static func clearRetries(_ dir: URL) -> Bool {
        update(dir) { $0.removeValue(forKey: retriesKey) }
    }

    /// At launch (a second copy is ruled out by the lock): what goes back in the queue, in order. A call left
    /// `processing` by a crash is requeued `maxRetries` times, then marked `failed` as it always was, so a call
    /// that kills the app cannot do so forever. It goes first: it was already running.
    public static func recoverQueue(in root: URL, now: Date = Date()) -> [ProcessingQueue.Job] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var interrupted: [ProcessingQueue.Job] = []
        var waiting: [(at: Date, job: ProcessingQueue.Job)] = []
        for d in dirs.sorted(by: { $0.path < $1.path }) where d.hasDirectoryPath && exists(d) {
            let c = read(d)
            if c["status"] as? String == CallStatus.processing.rawValue {
                let retries = c[retriesKey] as? Int ?? 0
                guard retries < maxRetries else {
                    update(d) { x in
                        x["status"] = CallStatus.failed.rawValue
                        x.removeValue(forKey: queuedAtKey)
                        x.removeValue(forKey: queuedSummaryOnlyKey)
                    }
                    continue
                }
                // No longer `processing` while it waits, or a second crash before its turn would use up the retry.
                update(d) { x in
                    x[retriesKey] = retries + 1
                    x["status"] = CallStatus.recorded.rawValue
                    x[queuedAtKey] = queuedAtString(now)
                    x.removeValue(forKey: queuedSummaryOnlyKey)
                }
                interrupted.append(ProcessingQueue.Job(dir: d, kind: .transcribe))
            } else if let at = queuedAt(c) {
                waiting.append((at, ProcessingQueue.Job(dir: d, kind: c[queuedSummaryOnlyKey] as? Bool == true ? .summaryOnly : .transcribe)))
            }
        }
        // `sorted` is not stable: same instant, then the folder name.
        let ordered = waiting.sorted { $0.at != $1.at ? $0.at < $1.at : $0.job.dir.path < $1.job.dir.path }
        return interrupted + ordered.map(\.job)
    }
}
