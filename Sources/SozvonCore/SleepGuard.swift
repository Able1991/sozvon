// Keeps the Mac from idle sleep while a call is recorded or a transcription is queued or running.

import Foundation

public final class SleepGuard {
    private let begin: (String) -> AnyObject
    private let end: (AnyObject) -> Void
    private let log: (String) -> Void
    private var token: AnyObject?
    private let lock = NSLock()

    /// `begin` takes the hold (the app uses `ProcessInfo.beginActivity`), `end` gives it back. `log` gets a line on take and release.
    public init(begin: @escaping (String) -> AnyObject, end: @escaping (AnyObject) -> Void,
                log: @escaping (String) -> Void = { _ in }) {
        self.begin = begin
        self.end = end
        self.log = log
    }

    public var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return token != nil
    }

    /// Take the hold when recording or work is pending and none is held; release when neither is. Safe to call on every state change.
    public func update(recording: Bool, hasWork: Bool) {
        lock.lock(); defer { lock.unlock() }
        let needed = recording || hasWork
        if needed, token == nil {
            token = begin(recording ? "Sozvon is recording a call" : "Sozvon is transcribing a call")
            log("sleep guard: taken (recording=\(recording), work=\(hasWork))")
        } else if !needed, let t = token {
            end(t)
            token = nil
            log("sleep guard: released")
        }
    }
}
