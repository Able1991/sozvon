import Foundation

/// Tracks whether writes to a recording file succeed and reports only changes, so a failing disk
/// produces one event instead of one per audio buffer.
public struct WriteHealth {
    public enum Event: Equatable {
        case failed(full: Bool)
        case recovered
    }

    private var failing = false

    public init() {}

    /// Feed every write result. Returns an event on the first failure and on the first success after one.
    public mutating func record(error: Error?) -> Event? {
        if let error {
            guard !failing else { return nil }
            failing = true
            return .failed(full: Self.isDiskFull(error))
        }
        guard failing else { return nil }
        failing = false
        return .recovered
    }

    /// The error means there is no space left on the volume.
    public static func isDiskFull(_ error: Error) -> Bool {
        let e = error as NSError
        return (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC))
            || (e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError)
    }
}

public enum DiskSpace {
    /// Under `DiagnosticChecks.criticalDisk` free. Unknown free space is not a warning.
    public static func lowSpace(freeBytes: Int64?) -> Bool {
        guard let freeBytes else { return false }
        return freeBytes < DiagnosticChecks.criticalDisk
    }

    /// Free bytes for important usage on the volume holding `url`, nil when it can't be read.
    public static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
