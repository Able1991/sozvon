// The trim panel's state machine: where the handles are, how they move by the keys, and what Cancel and Escape do
// in each phase. The panel (Sources/Sozvon/TrimPanel.swift) only draws it and feeds it events.

import Foundation

public enum TrimHandle: Hashable, Sendable { case start, end }

/// A key the trim panel handles itself while it has the keyboard.
public enum TrimKey: Equatable, Sendable { case left, right, escape }

/// What Cancel or Escape did.
public enum TrimCancelResult: Equatable, Sendable {
    /// The panel closes and the player bar comes back.
    case close
    /// The confirmation went away: the handles can be moved again.
    case backToEditing
    /// Nothing to cancel (the engine is cutting).
    case none
}

/// What a key did.
public enum TrimKeyResult: Equatable, Sendable {
    /// A handle moved (the panel lets the player follow it).
    case moved(TrimHandle)
    case cancel(TrimCancelResult)
    /// Not the panel's key in this phase: it goes on to the rest of the window.
    case ignored
}

/// Trim mode of one call card: where the handles are and how far the user got.
public struct TrimState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case editing, confirming, working }

    public var start: Double
    public var end: Double
    public var phase = Phase.editing

    /// A handle moves this far per arrow key, ten times as far with Shift.
    public static let keyStep = 1.0
    public static let shiftKeyStep = 10.0

    /// The handles of a call `duration` long: the silence hint's, or the whole call.
    public init(duration: Double, hint: TrimHint?) {
        start = hint?.start ?? 0
        end = hint?.end ?? duration
    }

    public init(start: Double, end: Double, phase: Phase = .editing) {
        self.start = start
        self.end = end
        self.phase = phase
    }

    public func value(_ h: TrimHandle) -> Double { h == .start ? start : end }

    /// Puts a handle at `t`: within the call, and at least the engine's minimum range from the other handle.
    public mutating func set(_ h: TrimHandle, to t: Double, duration: Double) {
        let gap = Trim.minRangeSeconds
        switch h {
        case .start: start = min(max(0, t), max(0, end - gap))
        case .end: end = max(min(duration, t), min(duration, start + gap))
        }
    }

    /// Cancel or Escape: the confirmation goes back to editing, editing closes the panel, the cut can't be stopped.
    public mutating func cancel() -> TrimCancelResult {
        switch phase {
        case .editing: return .close
        case .confirming:
            phase = .editing
            return .backToEditing
        case .working: return .none
        }
    }

    /// An arrow moves `handle` (the one the user last took) by a second, or ten with Shift, while editing;
    /// Escape cancels.
    public mutating func key(_ k: TrimKey, shift: Bool, handle: TrimHandle, duration: Double) -> TrimKeyResult {
        switch k {
        case .escape:
            let r = cancel()
            return r == .none ? .ignored : .cancel(r)
        case .left, .right:
            guard phase == .editing else { return .ignored }
            let step = shift ? Self.shiftKeyStep : Self.keyStep
            set(handle, to: value(handle) + (k == .left ? -step : step), duration: duration)
            return .moved(handle)
        }
    }
}
