// Transcription result: the exit code and the `RESULT:` line (contract, section 5).

import Foundation

public enum RunOutcome: Equatable, Sendable {
    /// 0: done.
    case ok
    /// 2: no audio on any track, or invalid input.
    case noAudio(String)
    /// 3: the engine is broken (import, environment).
    case engineBroken(String)
    /// 4: the model isn't downloaded.
    case modelMissing(String)
    /// 5: ffmpeg couldn't read the recording.
    case damaged(String)
    /// 1 and everything else (including a process killed by a signal or one that failed to start).
    case failed(code: Int32, message: String)

    public var isOK: Bool { self == .ok }

    public var message: String {
        switch self {
        case .ok: return ""
        case .noAudio(let m), .engineBroken(let m), .modelMissing(let m), .damaged(let m): return m
        case .failed(_, let m): return m
        }
    }

    /// Protocol line: `RESULT: ok [value]` or `RESULT: error <code> <message>`. Anything else: nil.
    public struct ResultLine: Equatable, Sendable {
        public let ok: Bool
        public let code: Int32?
        public let message: String
    }

    public static func parseLine(_ line: String) -> ResultLine? {
        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard l.hasPrefix("RESULT:") else { return nil }
        let rest = l.dropFirst("RESULT:".count).trimmingCharacters(in: .whitespaces)
        if rest == "ok" { return ResultLine(ok: true, code: 0, message: "") }
        // `RESULT: ok <value>` (voice.py reports the record id): the value goes to `message`.
        if rest.hasPrefix("ok ") {
            return ResultLine(ok: true, code: 0, message: rest.dropFirst(3).trimmingCharacters(in: .whitespaces))
        }
        guard rest.hasPrefix("error") else { return nil }
        let tail = rest.dropFirst("error".count).trimmingCharacters(in: .whitespaces)
        let parts = tail.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if let first = parts.first, let code = Int32(first) {
            return ResultLine(ok: false, code: code, message: parts.count > 1 ? String(parts[1]) : "")
        }
        return ResultLine(ok: false, code: nil, message: tail)
    }

    /// Result from the exit code, the RESULT line (if any) and the last output line.
    /// The exit code wins; the RESULT code refines a generic exit code 1 (or a 0 with RESULT error).
    public static func parse(exitCode: Int32, result: ResultLine?, lastLine: String? = nil) -> RunOutcome {
        var code = exitCode
        if let r = result, !r.ok, let rc = r.code, rc != 0, code == 0 || code == 1 { code = rc }
        if code == 0, let r = result, !r.ok { code = 1 }
        if code == 0 { return .ok }
        let message = (result?.message).flatMap { $0.isEmpty ? nil : $0 }
            ?? lastLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch code {
        case 2: return .noAudio(message)
        case 3: return .engineBroken(message)
        case 4: return .modelMissing(message)
        case 5: return .damaged(message)
        default: return .failed(code: code, message: message)
        }
    }

    /// Same, over all output lines: finds the last RESULT line.
    public static func parse(exitCode: Int32, lines: [String]) -> RunOutcome {
        let result = lines.reversed().lazy.compactMap(parseLine).first
        let last = lines.reversed().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return parse(exitCode: exitCode, result: result, lastLine: last)
    }
}
