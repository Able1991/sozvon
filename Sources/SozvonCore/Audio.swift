// Recording math without AVFoundation: filling gaps with silence and monitoring the signal.

import Foundation

/// If the audio stream was interrupted (system silence, capture lagging), zeros are appended to the track
/// so its timeline matches the capture clock and the tracks stay in sync.
public enum GapFiller {
    /// Gaps shorter than this (seconds) aren't filled: that's normal packet jitter.
    public static let threshold = 0.25

    /// How many frames of silence to insert before the packet with timestamp `pts`.
    public static func silenceFrames(firstPTS: Double, framesWritten: Int64, sampleRate: Double, pts: Double) -> Int64 {
        guard sampleRate > 0 else { return 0 }
        let expected = firstPTS + Double(framesWritten) / sampleRate
        let gap = pts - expected
        guard gap > threshold else { return 0 }
        return Int64(gap * sampleRate)
    }

    /// Split silence into chunks of at most `maxChunk` frames (a one-second buffer, not one for the whole gap).
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

/// Track monitoring during recording: levels for the panel, how many seconds the other side has been silent,
/// and how many seconds the microphone hasn't delivered usable packets.
public struct SignalMonitor: Sendable {
    /// A packet older than this (seconds) counts as missing: level 0.
    public static let freshness = 1.5
    /// System audio below this level counts as silence.
    public static let silenceLevel: Float = 0.01

    public struct Reading: Equatable, Sendable {
        public var mic: Float
        public var system: Float
        /// Seconds of digital silence in system audio (capture may have dropped).
        public var systemSilent: Int
        /// Seconds without usable microphone packets (no access, unsupported format).
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
