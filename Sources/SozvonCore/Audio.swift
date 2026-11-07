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
    /// System audio below this meter level (about -50 dB) counts as silence.
    public static let silenceLevel: Float = 0.01

    public struct Reading: Equatable, Sendable {
        public var mic: Float
        public var system: Float
        /// Seconds system audio has been below `silenceLevel` or missing: the other side is quiet, or their
        /// sound doesn't reach this Mac.
        public var systemSilent: Int
        /// Seconds without usable microphone packets (no access, unsupported format).
        public var micMissing: Int
        /// Seconds the microphone gave nothing usable: no packets or digital zeros (a dead device,
        /// a headset that switched profiles). A quiet room is never digital zero.
        public var micSilent: Int = 0
    }

    private var silentSince: Date?
    private var micMissingSince: Date?
    private var micSilentSince: Date?

    public init() {}

    /// `micZero`: the latest microphone packet was digital silence.
    public mutating func update(now: Date, mic: (level: Float, last: Date?), system: (level: Float, last: Date?),
                                micZero: Bool = false) -> Reading {
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
        if fresh(mic.last) && !micZero {
            micSilentSince = nil
        } else if micSilentSince == nil {
            micSilentSince = now
        }
        func secs(_ d: Date?) -> Int { d.map { Int(now.timeIntervalSince($0)) } ?? 0 }
        return Reading(mic: micLevel, system: sysLevel, systemSilent: secs(silentSince),
                       micMissing: secs(micMissingSince), micSilent: secs(micSilentSince))
    }
}

/// One audio source that went quiet mid-recording: after `restartAfter` seconds of silence capture it again
/// (once, quietly); if it is still silent at `tellAfter`, tell the user (capsule and notification).
/// Sound coming back starts over.
///
/// The other side (`patient`) is often quiet for minutes in a normal call: they listen while you present, or
/// they are muted. Once they have been heard in this recording, their silence is told only after
/// `listeningAfter`; before that (never heard since the start) the call audio most likely doesn't reach this Mac.
public struct SilenceWatch: Sendable, Equatable {
    public enum Action: Equatable, Sendable { case none, restart, tell }

    public static let restartAfter = 120
    /// Told half a minute after the recapture didn't help: "over two minutes" in Settings.
    public static let tellAfterRestart = 30
    public static let listeningAfter = 300
    /// Updates (10 a second) with sound before the source counts as heard: a few seconds of speech,
    /// not a notification chime.
    public static let heardAfterUpdates = 30

    private let patient: Bool
    private var soundUpdates = 0
    private var restarted = false
    private var told = false

    public init(patient: Bool = false) { self.patient = patient }

    /// The source has been heard in this recording (only tracked for the patient watch).
    public var heard: Bool { soundUpdates >= Self.heardAfterUpdates }

    /// Seconds of silence after which the user is told.
    public var tellAfter: Int {
        patient && heard ? Self.listeningAfter : Self.restartAfter + Self.tellAfterRestart
    }

    /// `silent`: seconds this source has been quiet (0 = sound now); `sound`: it has sound right now.
    public mutating func update(silent: Int, sound: Bool = false) -> Action {
        if sound, soundUpdates < Self.heardAfterUpdates { soundUpdates += 1 }
        guard silent > 0 else {
            restarted = false
            told = false
            return .none
        }
        if !restarted {
            guard silent >= Self.restartAfter else { return .none }
            restarted = true
            return .restart
        }
        guard !told, silent >= tellAfter else { return .none }
        told = true
        return .tell
    }

    /// The capsule shows the warning from the same moment the notification is posted.
    public func warns(silent: Int) -> Bool { silent >= tellAfter }
}

/// The microphone works but the user is very quiet (a low input volume, the Mac far away): after `after` seconds
/// of recording with no level above `loud`, say so once. A quiet track is raised before recognition anyway
/// (engine tracks.boost), but the source sound is better fixed during the call.
public struct QuietMicWatch: Sendable, Equatable {
    /// Meter level (0...1 on -50...0 dB) that normal speech reaches: about -40 dB.
    public static let loud: Float = 0.2
    public static let after = 180

    private var loudSeen = false
    private var told = false

    public init() {}

    /// `level`: the mic meter now (0 without fresh packets), `seconds`: recording time. -> true once, when it is time to tell.
    public mutating func update(level: Float, seconds: Int) -> Bool {
        if level >= Self.loud { loudSeen = true }
        guard !told, !loudSeen, seconds >= Self.after else { return false }
        told = true
        return true
    }
}

/// System audio arrives as digital zeros from a capture that started: nothing plays on this Mac (the call
/// hasn't connected yet, the other side is silent), or the capture went deaf (a FaceTime call moved the audio).
/// After `after` seconds of zeros a new process tap is built; if zeros go on, another one, each try waiting
/// twice as long, up to `maxPause`, so a call where nothing plays doesn't rebuild the capture every few
/// seconds. Zeros alone never move system audio to ScreenCaptureKit: it can't hear FaceTime, and a working
/// tap gives zeros whenever nothing plays. ScreenCaptureKit stands in only when a tap can't start (Recorder).
/// Sound starts over.
public struct ZeroWatch: Sendable, Equatable {
    public enum Action: Equatable, Sendable { case none, newTap }

    public static let after = 8.0
    public static let firstPause = 15.0
    public static let maxPause = 300.0

    private var zeroSince: Date?
    private var lastTry: Date?
    private var pause = firstPause

    public init() {}

    /// `zero`: the latest system packet is fresh and digital silence.
    public mutating func update(now: Date, zero: Bool) -> Action {
        guard zero else {
            self = ZeroWatch()
            return .none
        }
        let since = zeroSince ?? now
        zeroSince = since
        guard now.timeIntervalSince(since) >= Self.after else { return .none }
        guard let last = lastTry else {
            lastTry = now
            return .newTap
        }
        guard now.timeIntervalSince(last) >= pause else { return .none }
        lastTry = now
        pause = min(pause * 2, Self.maxPause)
        return .newTap
    }
}

/// Signal level scales for one packet's RMS (0...1 of full scale).
public enum Levels {
    static func db(_ rms: Float) -> Float { 20 * log10(max(rms, 1e-6)) }

    /// The meter used by the warnings and the quiet-mic check: -50...0 dB as 0...1.
    public static func meter(_ rms: Float) -> Float { max(0, min(1, (db(rms) + 50) / 50)) }

    /// The capsule's waveform: -75...-25 dB as 0...1, so a quiet mic (a low input volume) still shows,
    /// independent of the warning thresholds.
    public static func display(_ rms: Float) -> Float { max(0, min(1, (db(rms) + 75) / 50)) }

    /// Below -80 dB: digital silence (a dead device, nothing playing). A quiet room is never this low.
    public static func isDigitalSilence(_ rms: Float) -> Bool { rms < 1e-4 }
}
