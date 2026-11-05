// Расчёты для записи без AVFoundation: заполнение пауз тишиной и слежение за сигналом.

import Foundation

/// Если поток звука прерывался (тишина в системе, захват отставал), в дорожку дописываются нули,
/// чтобы время дорожки совпадало с часами захвата и дорожки не разъезжались.
public enum GapFiller {
    /// Разрыв меньше этого (сек) не заполняем: обычный джиттер пакетов.
    public static let threshold = 0.25

    /// Сколько кадров тишины вставить перед пакетом с меткой `pts`.
    public static func silenceFrames(firstPTS: Double, framesWritten: Int64, sampleRate: Double, pts: Double) -> Int64 {
        guard sampleRate > 0 else { return 0 }
        let expected = firstPTS + Double(framesWritten) / sampleRate
        let gap = pts - expected
        guard gap > threshold else { return 0 }
        return Int64(gap * sampleRate)
    }

    /// Разбить тишину на куски не больше `maxChunk` кадров (буфер на секунду, а не на весь разрыв).
    public static func chunks(_ total: Int64, maxChunk: Int64) -> [Int64] {
        guard total > 0, maxChunk > 0 else { return [] }
        var out: [Int64] = []
        var left = total
        while left > 0 {
            let n = min(left, maxChunk)
            out.append(n)
            left -= n
        }
        return out
    }
}

/// Слежение за дорожками во время записи: уровни для панели, сколько секунд нет звука собеседников
/// и сколько секунд с микрофона не приходят пригодные пакеты.
public struct SignalMonitor: Sendable {
    /// Пакет старше этого (сек) считается пропавшим: уровень 0.
    public static let freshness = 1.5
    /// Ниже этого уровня системный звук считается тишиной.
    public static let silenceLevel: Float = 0.01

    public struct Reading: Equatable, Sendable {
        public var mic: Float
        public var system: Float
        /// Секунды цифровой тишины системного звука (захват мог отвалиться).
        public var systemSilent: Int
        /// Секунды без пригодных пакетов с микрофона (нет доступа, непонятный формат).
        public var micMissing: Int
    }

    private var silentSince: Date?
    private var micMissingSince: Date?

    public init() {}

    public mutating func update(now: Date, mic: (level: Float, last: Date?), system: (level: Float, last: Date?)) -> Reading {
        func fresh(_ last: Date?) -> Bool { last.map { now.timeIntervalSince($0) < Self.freshness } ?? false }
        let micLevel = fresh(mic.last) ? mic.level : 0
        let sysLevel = fresh(system.last) ? system.level : 0
        if sysLevel > Self.silenceLevel {
            silentSince = nil
        } else if silentSince == nil {
            silentSince = now
        }
        if fresh(mic.last) {
            micMissingSince = nil
        } else if micMissingSince == nil {
            micMissingSince = now
        }
        return Reading(mic: micLevel, system: sysLevel,
                       systemSilent: silentSince.map { Int(now.timeIntervalSince($0)) } ?? 0,
                       micMissing: micMissingSince.map { Int(now.timeIntervalSince($0)) } ?? 0)
    }
}
