// Whether the chosen summary assistant answers: `bin/check_assistant.py <name>` sends it a one-word request
// through the very command a summary uses (docs/CONTRACT.md), so "connected" never hides a CLI that is not
// logged in or cannot start.

import Foundation

public enum AssistantCheck: Equatable, Sendable {
    case running, ok, failed(String)

    /// The script's output lines and exit code -> the result. No `RESULT:` line (the engine broke): its last line.
    public static func parse(_ lines: [String], code: Int32) -> AssistantCheck {
        if let last = lines.last(where: { $0.hasPrefix("RESULT: ") }) {
            let rest = last.dropFirst("RESULT: ".count)
            if rest == "ok" || rest.hasPrefix("ok ") { return .ok }
            if rest.hasPrefix("error") { return .failed(rest.dropFirst("error".count).trimmingCharacters(in: .whitespaces)) }
        }
        return .failed(lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "")
    }
}
