// Trim a recording (cut its start and end): when it is not available and where the silence hint puts the handles.
// The cut itself is `bin/trim_call.py`; the app queues the transcription afterwards.

import Foundation

public enum TrimUnavailable: Equatable, Sendable {
    case busy, audioRemoved, noAudio, demo, tooShort

    /// Shown next to the disabled Trim action.
    public var reason: String {
        switch self {
        case .busy: return L("Звонок записывается или расшифровывается")
        case .audioRemoved: return L("Звук удалён по настройке «Автоудаление аудио»")
        case .noAudio: return L("Звука этого звонка нет на этом Mac")
        case .demo: return L("Это демонстрационный звонок")
        case .tooShort: return L("Звонок короче 30 секунд")
        }
    }
}

public enum Trim {
    /// call.json: the user dismissed the "quiet at the start or end" hint for this call.
    public static let hintDismissedKey = "trim_hint_dismissed"
    /// A call shorter than this cannot be trimmed.
    public static let minCallSeconds = 30.0
    /// Quiet at the start or end this long raises the hint.
    public static let hintSeconds = 60.0
    /// The trimmed range is at least this long (the engine's rule).
    public static let minRangeSeconds = 10.0
    /// The handles keep this much of the quiet around the speech.
    static let margin = 2.0

    /// Why Trim is off for a call, or nil. Precedence: busy, demo, audio removed, no audio, too short.
    public static func unavailable(call: [String: Any], hasAudio: Bool, busy: Bool) -> TrimUnavailable? {
        if busy { return .busy }
        if DemoCalls.isDemo(call) { return .demo }
        if call[AudioRetention.removedKey] != nil { return .audioRemoved }
        if !hasAudio { return .noAudio }
        let audio = AudioTimes((call["audio"] as? [String: Any]) ?? [:])
        if audio.duration < minCallSeconds { return .tooShort }
        return nil
    }

    /// Suggested range from the measured silence, or nil (dismissed, not measured, or both ends under a minute).
    public static func hint(call: [String: Any], duration: Double) -> (start: Double, end: Double)? {
        guard call[hintDismissedKey] as? Bool != true,
              let s = call["silence"] as? [String: Any] else { return nil }
        let head = (s["head"] as? NSNumber)?.doubleValue ?? 0
        let tail = (s["tail"] as? NSNumber)?.doubleValue ?? 0
        guard head >= hintSeconds || tail >= hintSeconds else { return nil }
        let start = head >= hintSeconds ? max(0, head - margin) : 0
        let end = tail >= hintSeconds ? min(duration, duration - tail + margin) : duration
        // Silence data that does not fit the call (or leaves under the minimum range) gives no hint.
        guard end - start >= minRangeSeconds else { return nil }
        return (start, end)
    }

    /// The quiet head and tail in whole minutes for the hint's text; 0 for an end under the hint threshold.
    public static func hintMinutes(call: [String: Any]) -> (head: Int, tail: Int) {
        let s = call["silence"] as? [String: Any] ?? [:]
        func minutes(_ key: String) -> Int {
            let v = (s[key] as? NSNumber)?.doubleValue ?? 0
            return v >= hintSeconds ? Int((v / 60).rounded()) : 0
        }
        return (minutes("head"), minutes("tail"))
    }
}

/// The silence hint of one call, as the call card shows it.
public struct TrimHint: Equatable, Sendable {
    public var start: Double
    public var end: Double
    /// Whole minutes of quiet at the start and at the end (0: that end is not part of the hint).
    public var headMinutes: Int
    public var tailMinutes: Int

    public init(start: Double, end: Double, headMinutes: Int, tailMinutes: Int) {
        self.start = start
        self.end = end
        self.headMinutes = headMinutes
        self.tailMinutes = tailMinutes
    }

    /// The hint of a call.json, or nil (see `Trim.hint`).
    public init?(call: [String: Any], duration: Double) {
        guard let h = Trim.hint(call: call, duration: duration) else { return nil }
        let m = Trim.hintMinutes(call: call)
        self.init(start: h.start, end: h.end, headMinutes: h.start > 0 ? m.head : 0, tailMinutes: h.end < duration ? m.tail : 0)
    }
}
