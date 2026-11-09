// call.json `warnings` (contract section 4): steps that failed on the engine's last run although the call
// is `done`. Optional; the engine removes the field when a later run has none. Sync never sends it.

import Foundation

public struct CallWarning: Equatable, Sendable {
    public enum Step: String, Sendable { case summary, names }
    public let step: Step
    /// One line from the engine; empty when it gave none.
    public let error: String
}

public enum CallWarnings {
    public static let key = "warnings"

    /// Warnings of known steps, in file order. A broken field or entry is skipped, never an error.
    public static func list(_ c: [String: Any]) -> [CallWarning] {
        guard let raw = c[key] as? [Any] else { return [] }
        return raw.compactMap { item -> CallWarning? in
            guard let o = item as? [String: Any], let s = o["step"] as? String,
                  let step = CallWarning.Step(rawValue: s) else { return nil }
            return CallWarning(step: step, error: (o["error"] as? String) ?? "")
        }
    }

    /// Why the summary failed on the last run (one line), nil when it did not. Empty reason: "".
    public static func summary(_ c: [String: Any]) -> String? {
        list(c).first { $0.step == .summary }.map { $0.error.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    }
}
