// Calls waiting for their description: "Later" in "What was the call about?" (call.json `info_pending`).
// The flag lives in call.json, so pending calls survive restarts. A reminder is a quiet nudge:
// only after Sozvon has been idle for 10 minutes, never during a recording, at most once an hour per call.

import Foundation

public struct PendingCall: Equatable, Sendable {
    public let dir: URL
    public let id: String
    /// Recording start (from the id), for "The call at 15:04".
    public let date: Date?

    public init(dir: URL, id: String, date: Date?) {
        self.dir = dir
        self.id = id
        self.date = date
    }
}

public enum PendingInfo {
    /// call.json field (contract section 4): optional, `true` only; absent means not pending.
    public static let key = "info_pending"

    /// Waiting for a description: the flag is set and the call has not been transcribed yet
    /// (a call transcribed some other way, MCP for example, is no longer pending even if the flag stayed).
    public static func isPending(_ c: [String: Any]) -> Bool {
        c[key] as? Bool == true && c["status"] as? String == CallStatus.recorded.rawValue
    }

    /// Pending calls in the folder, oldest first.
    public static func all(in root: URL) -> [PendingCall] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.filter { $0.hasDirectoryPath && CallFile.exists($0) }.compactMap { d -> PendingCall? in
            let c = CallFile.read(d)
            guard isPending(c) else { return nil }
            let id = (c["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? CallFile.id(of: d)
            return PendingCall(dir: d, id: id, date: Call.parseID(id))
        }
        .sorted {
            let a = $0.date ?? .distantPast, b = $1.date ?? .distantPast
            return a != b ? a < b : $0.id.compare($1.id, options: .numeric) == .orderedAscending
        }
    }
}

/// When to remind about pending calls. Pure: the caller passes the time and whether Sozvon is busy.
public struct ReminderPlanner: Sendable {
    /// Sozvon must be idle (no recording, no call prompt open) this long.
    public static let idleDelay: TimeInterval = 10 * 60
    /// The same call is reminded about at most this often.
    public static let repeatEvery: TimeInterval = 60 * 60

    /// Idle since (nil while busy).
    public private(set) var idleSince: Date?
    private var reminded: [String: Date] = [:]

    public init(now: Date = Date()) { idleSince = now }

    /// Sozvon's state changed. Busy (recording, starting, stopping, the call prompt open) resets the idle clock.
    public mutating func activity(busy: Bool, now: Date) {
        if busy { idleSince = nil } else if idleSince == nil { idleSince = now }
    }

    /// Calls to remind about now (oldest first) and remember the time. Empty while busy or not idle long enough.
    /// One notification is enough for all of them: the caller shows the oldest and the count.
    public mutating func due(_ pending: [PendingCall], now: Date, busy: Bool) -> [PendingCall] {
        activity(busy: busy, now: now)
        // Forget calls that are no longer pending.
        let ids = Set(pending.map(\.id))
        reminded = reminded.filter { ids.contains($0.key) }
        guard !busy, let since = idleSince, now.timeIntervalSince(since) >= Self.idleDelay else { return [] }
        let due = pending.filter { p in reminded[p.id].map { now.timeIntervalSince($0) >= Self.repeatEvery } ?? true }
        for p in due { reminded[p.id] = now }
        return due
    }
}
