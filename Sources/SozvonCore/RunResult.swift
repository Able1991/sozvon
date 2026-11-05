// Итог расшифровки: код завершения и строка `RESULT:` (контракт, раздел 5).

import Foundation

public enum RunOutcome: Equatable, Sendable {
    /// 0: готово.
    case ok
    /// 2: нет звука ни на одной дорожке или неверный ввод.
    case noAudio(String)
    /// 3: движок сломан (импорт, окружение).
    case engineBroken(String)
    /// 4: модель не скачана.
    case modelMissing(String)
    /// 5: ffmpeg не смог прочитать запись.
    case damaged(String)
    /// 1 и всё прочее (в том числе процесс убит сигналом или не запустился).
    case failed(code: Int32, message: String)

    public var isOK: Bool { self == .ok }

    public var message: String {
        switch self {
        case .ok: return ""
        case .noAudio(let m), .engineBroken(let m), .modelMissing(let m), .damaged(let m): return m
        case .failed(_, let m): return m
        }
    }

    /// Строка протокола: `RESULT: ok` или `RESULT: error <код> <сообщение>`. Не она: nil.
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
        guard rest.hasPrefix("error") else { return nil }
        let tail = rest.dropFirst("error".count).trimmingCharacters(in: .whitespaces)
        let parts = tail.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if let first = parts.first, let code = Int32(first) {
            return ResultLine(ok: false, code: code, message: parts.count > 1 ? String(parts[1]) : "")
        }
        return ResultLine(ok: false, code: nil, message: tail)
    }

    /// Итог по коду завершения, строке RESULT (если была) и последней строке вывода.
    /// Код завершения главнее; код из RESULT уточняет общий код 1 (или 0 с RESULT error).
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

    /// То же по всем строкам вывода: ищет последнюю строку RESULT.
    public static func parse(exitCode: Int32, lines: [String]) -> RunOutcome {
        let result = lines.reversed().lazy.compactMap(parseLine).first
        let last = lines.reversed().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return parse(exitCode: exitCode, result: result, lastLine: last)
    }
}
