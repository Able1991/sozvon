// What happens around a call, beyond the "Record?" prompt (CallDetection.swift):
//   start: ask (the prompt), record by itself after a short countdown, or nothing;
//   end:   optionally stop the recording once no call app has held the microphone for a while.
// Both are the user's choice in Settings and off by default; every automatic start and stop is shown on the
// capsule with a way to cancel it.

import Foundation

/// What Sozvon does when a call app starts using the microphone.
public enum CallStartMode: String, CaseIterable, Sendable {
    /// "A call is on in Zoom. Record?" (default).
    case ask
    /// The same capsule with a countdown: it records when the countdown runs out, unless cancelled.
    case record
    /// Nothing.
    case off
}

public enum CallAutomation {
    public static let modeKey = "callStartMode"
    /// The old on/off switch "Offer to record when a call starts": off maps to `.off`.
    public static let legacyPromptKey = "callPrompt"
    public static let autoStopKey = "callAutoStop"

    /// Seconds between noticing the call (after CallDetector.debounce) and the automatic start.
    public static let startCountdown = 10
    /// Seconds without any call app on the microphone before the recording stops. Call apps let go of the
    /// microphone for a moment when they reconnect or switch devices: a short gap must not end the recording.
    public static let stopGrace = 30

    public static func mode(_ d: UserDefaults = .standard) -> CallStartMode {
        if let raw = d.string(forKey: modeKey), let m = CallStartMode(rawValue: raw) { return m }
        if d.object(forKey: legacyPromptKey) as? Bool == false { return .off }
        return .ask
    }

    public static func setMode(_ m: CallStartMode, _ d: UserDefaults = .standard) {
        d.set(m.rawValue, forKey: modeKey)
    }

    /// "Stop when the call ends" (off by default).
    public static func autoStop(_ d: UserDefaults = .standard) -> Bool {
        d.bool(forKey: autoStopKey)
    }

    public static func setAutoStop(_ on: Bool, _ d: UserDefaults = .standard) {
        d.set(on, forKey: autoStopKey)
    }
}

/// During one recording: notices that the call is over. Armed once a call app has held the microphone for
/// `armHold` seconds in a row during the recording (a recording of a meeting in the room is never stopped, and a
/// voice message during it doesn't count). The countdown runs while no call app holds the microphone and the other
/// side is silent: an app that releases the microphone on mute is still a call as long as someone is heard.
/// "Keep recording" cancels it until the next call.
public struct CallEndDetector: Equatable, Sendable {
    public static let armHold: TimeInterval = 15

    public private(set) var armed = false
    public private(set) var heldSince: Date?
    public private(set) var releasedAt: Date?
    public private(set) var kept = false

    public init() {}

    /// `inCall`: a call app holds the microphone now. `otherSideAudible`: the other side's track has sound now.
    /// Returns the seconds left until the recording should stop (0: stop now), or nil when there is no countdown.
    public mutating func update(inCall: Bool, otherSideAudible: Bool = false, now: Date,
                                grace: TimeInterval = TimeInterval(CallAutomation.stopGrace)) -> TimeInterval? {
        if inCall {
            let since = heldSince ?? now
            heldSince = since
            if now.timeIntervalSince(since) >= Self.armHold { armed = true; kept = false }
            releasedAt = nil
            return nil
        }
        // The source reports changes only: how long the app held the microphone is known when it lets go.
        if let since = heldSince, now.timeIntervalSince(since) >= Self.armHold { armed = true; kept = false }
        heldSince = nil
        guard armed, !kept, !otherSideAudible else { releasedAt = nil; return nil }
        let since = releasedAt ?? now
        releasedAt = since
        return max(0, grace - now.timeIntervalSince(since))
    }

    /// "Keep recording": no automatic stop until a call app takes the microphone again and lets it go.
    public mutating func keepRecording() {
        kept = true
        releasedAt = nil
    }
}
