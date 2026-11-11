// The app's own log files (recorder.log, the header lines of mcp.log): whole lines appended at the end.

import Foundation

public enum AppLog {
    // One writer at a time in this process: lines come from the capture queue and the main thread.
    private static let lock = NSLock()

    /// Append `text` to the file at `url`, creating the file and its folder when missing. Safe from any thread.
    /// O_APPEND puts every write at the current end, so another process writing the same file (the MCP server
    /// and its mcp.log) is not overwritten either. A log that can't be written is not an error for the caller.
    public static func append(_ text: String, to url: URL) {
        lock.lock()
        defer { lock.unlock() }
        var fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        if fd < 0 && errno == ENOENT {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        }
        guard fd >= 0 else { return }
        writeAll(fd, Data(text.utf8))
        close(fd)
    }
}

/// Write all of `data` to a file descriptor, going on after a short write or EINTR. False when a write failed.
@discardableResult
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { buf in
        var off = 0
        while off < buf.count {
            let n = write(fd, buf.baseAddress! + off, buf.count - off)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}
