// Recording state: a single state machine instead of a set of flags.
//
//   idle ──begin──▶ starting ──started──▶ recording ──stop──▶ stopping ──finalized──▶ saved ──dismiss──▶ idle
//                      │                                                                │
//                      └──failed──▶ idle                     saved ──begin──▶ starting ─┘ (new recording while the prompt is open)

import Foundation

/// Recording in progress: folder, start time and what has already
/// been said about the call ("Project and Participants").
public struct RecordingSession: Equatable, Sendable {
    public let dir: URL
    public let startedAt: Date
    public var info: CallInfo

    public init(dir: URL, startedAt: Date, info: CallInfo) {
        self.dir = dir
        self.startedAt = startedAt
        self.info = info
    }

    /// "12:34" or "1:02:03" since the recording started.
    public func elapsed(at now: Date = Date()) -> String {
        Call.clock(max(0, Int(now.timeIntervalSince(startedAt))), empty: "0:00")
    }
}

public enum RecordingState: Sendable {
    case idle
    /// Waiting for permissions and capture start: a second start isn't allowed.
    case starting(dir: URL)
    case recording(RecordingSession)
    /// Capture is stopping and files are being closed. App quit and capture failure wait on this task.
    case stopping(RecordingSession, finalize: Task<Void, Never>)
    /// Recording saved, waiting for the "what was the call about" answer.
    case saved(dir: URL)

    public var isRecording: Bool { if case .recording = self { return true } else { return false } }
    public var isStarting: Bool { if case .starting = self { return true } else { return false } }
    public var isStopping: Bool { if case .stopping = self { return true } else { return false } }

    /// A new recording can start (from idle and from saved, like `RecordingMachine.begin`).
    public var canBegin: Bool {
        switch self {
        case .idle, .saved: return true
        default: return false
        }
    }

    /// Recording is running or not yet finalized on disk.
    public var isCapturing: Bool { isRecording || isStopping }

    public var session: RecordingSession? {
        switch self {
        case .recording(let s), .stopping(let s, _): return s
        default: return nil
        }
    }

    public var dir: URL? {
        switch self {
        case .idle: return nil
        case .starting(let d), .saved(let d): return d
        case .recording(let s), .stopping(let s, _): return s.dir
        }
    }

    public var finalizeTask: Task<Void, Never>? {
        if case .stopping(_, let t) = self { return t }
        return nil
    }

    /// Short state name (for logs and tests).
    public var name: String {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .stopping: return "stopping"
        case .saved: return "saved"
        }
    }
}

/// State transitions. Each method checks that the transition is allowed and returns false if not.
public struct RecordingMachine: Sendable {
    public private(set) var state: RecordingState = .idle

    public init() {}

    /// Begin starting a recording into a folder. Allowed from idle
    /// and from saved (the previous call's prompt is still open).
    @discardableResult
    public mutating func begin(_ dir: URL) -> Bool {
        switch state {
        case .idle, .saved: state = .starting(dir: dir); return true
        default: return false
        }
    }

    /// Capture started.
    @discardableResult
    public mutating func started(_ session: RecordingSession) -> Bool {
        guard case .starting(let dir) = state, dir == session.dir else { return false }
        state = .recording(session)
        return true
    }

    /// Start failed (no permissions, capture error).
    @discardableResult
    public mutating func startFailed() -> Bool {
        guard state.isStarting else { return false }
        state = .idle
        return true
    }

    /// Change the call details during recording.
    @discardableResult
    public mutating func updateInfo(_ info: CallInfo) -> Bool {
        guard case .recording(var s) = state else { return false }
        s.info = info
        state = .recording(s)
        return true
    }

    /// Stop: the `finalize` task finishes writing the files from here. Returns the session.
    @discardableResult
    public mutating func stop(finalize: Task<Void, Never>) -> RecordingSession? {
        guard case .recording(let s) = state else { return nil }
        state = .stopping(s, finalize: finalize)
        return s
    }

    /// Files closed, call.json written.
    @discardableResult
    public mutating func finalized() -> Bool {
        guard case .stopping(let s, _) = state else { return false }
        state = .saved(dir: s.dir)
        return true
    }

    /// The call prompt was answered (or declined). If a new recording has already started, change nothing.
    @discardableResult
    public mutating func dismissSaved(_ dir: URL) -> Bool {
        guard case .saved(let d) = state, d == dir else { return false }
        state = .idle
        return true
    }
}
