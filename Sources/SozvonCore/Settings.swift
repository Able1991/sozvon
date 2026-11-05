// User settings in the engine's .env (contract, section 2).

import Combine
import Foundation

/// A `KEY=value` file, line by line. Foreign keys and comments are kept as is.
/// Values are written in double quotes with escaping: the engine's python-dotenv reads
/// `SOZVON_ME=Ivan #2` without quotes as "Ivan" (to it everything after " #" is a comment).
public enum EnvFile {
    /// Key-value pairs without comments or blank lines. Quotes are stripped, like python-dotenv does.
    public static func parse(_ text: String) -> [(String, String)] {
        text.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { return nil }
            return (String(l[..<eq]).trimmingCharacters(in: .whitespaces), value(String(l[l.index(after: eq)...])))
        }
    }

    /// The value after "=": "double-quoted" (with \\, \", \n, \t), 'single-quoted' (literal) or bare
    /// (up to " #", trimmed).
    static func value(_ raw: String) -> String {
        let v = raw.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") {
            var out = ""
            var escaped = false
            for ch in v.dropFirst() {
                if escaped {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "\\", "\"", "'": out.append(ch)
                    default: out.append("\\"); out.append(ch)
                    }
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    return out
                } else {
                    out.append(ch)
                }
            }
            return out
        }
        if v.hasPrefix("'"), let end = v.dropFirst().firstIndex(of: "'") {
            return String(v[v.index(after: v.startIndex)..<end])
        }
        if let r = v.range(of: " #") { return String(v[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return v
    }

    /// Double-quoted value: \\, " and newlines are escaped.
    public static func quote(_ v: String) -> String {
        var out = "\""
        for ch in v {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    public static func dictionary(_ text: String) -> [String: String] {
        Dictionary(parse(text), uniquingKeysWith: { _, b in b })
    }

    /// Remove lines with keys from `remove` and from `set`, append `set` at the end (quoted).
    public static func merge(_ text: String, set: [(String, String)], remove: Set<String> = []) -> String {
        let drop = remove.union(set.map(\.0))
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        lines.removeAll { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { return false }
            return drop.contains(String(l[..<eq]).trimmingCharacters(in: .whitespaces))
        }
        lines += set.map { "\($0.0)=\(quote($0.1))" }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Setting values and their .env keys. A pure model: read from a dictionary, written as pairs.
public struct SettingsValues: Equatable, Sendable {
    public enum Key {
        public static let version = "SOZVON_ENV_VERSION"
        public static let me = "SOZVON_ME"
        public static let legacyMe = "CALL_ME_NAME"
        public static let llm = "SOZVON_LLM"
        public static let language = "SOZVON_LANGUAGE"
        public static let langSwitch = "SOZVON_LANG_SWITCH"
        public static let model = "SOZVON_MODEL"
        public static let hfToken = "HF_TOKEN"
    }
    public static let envVersion = 1

    public var name = ""
    public var hfToken = ""
    public var assistant: Assistant = .none
    /// Call languages. Empty: detect any. Several: detect among them.
    public var languages: [SpeechLanguage] = [.ru]
    /// The language may switch mid-speech for one person: detect it for each phrase.
    public var languageSwitch = false
    public var model: WhisperModel = .turbo

    public init() {}

    /// From .env keys. `CALL_ME_NAME` is accepted as the old name of `SOZVON_ME`.
    /// No assistant set: `detect` picks the installed one.
    public init(env kv: [String: String], detect: () -> Assistant = Assistant.detect) {
        name = kv[Key.me] ?? kv[Key.legacyMe] ?? ""
        hfToken = kv[Key.hfToken] ?? ""
        languages = SpeechLanguage.parse(kv[Key.language] ?? "ru")
        languageSwitch = kv[Key.langSwitch] == "1"
        model = kv[Key.model].flatMap(WhisperModel.init(rawValue:)) ?? .turbo
        assistant = kv[Key.llm].flatMap(Assistant.init(rawValue:)) ?? detect()
    }

    /// Keys managed by the app (old names are removed on write).
    public static let managedKeys: Set<String> = [Key.version, Key.me, Key.legacyMe, Key.llm, Key.language,
                                                  Key.langSwitch, Key.model, Key.hfToken]

    public var pairs: [(String, String)] {
        var kv: [(String, String)] = [(Key.version, String(Self.envVersion))]
        let me = name.trimmingCharacters(in: .whitespaces)
        if !me.isEmpty { kv.append((Key.me, me)) }
        let token = hfToken.trimmingCharacters(in: .whitespaces)
        if !token.isEmpty { kv.append((Key.hfToken, token)) }
        kv.append((Key.llm, assistant.rawValue))
        kv.append((Key.language, SpeechLanguage.serialize(languages)))
        kv.append((Key.langSwitch, languageSwitch ? "1" : "0"))
        kv.append((Key.model, model.rawValue))
        return kv
    }

    /// New .env text: our keys replaced, foreign ones kept.
    public func render(over text: String) -> String {
        EnvFile.merge(text, set: pairs, remove: Self.managedKeys)
    }
}

/// Settings for the windows: changed in the UI, saved to .env with mode 600.
@MainActor
public final class Settings: ObservableObject {
    public static let shared = Settings()

    @Published public var name = ""
    @Published public var hfToken = ""
    @Published public var assistant: Assistant = .none
    @Published public var languages: [SpeechLanguage] = [.ru]
    @Published public var languageSwitch = false
    @Published public var model: WhisperModel = .turbo

    private let url: URL

    public init(url: URL = Paths.env) {
        self.url = url
        load()
    }

    public var values: SettingsValues {
        var v = SettingsValues()
        v.name = name
        v.hfToken = hfToken
        v.assistant = assistant
        v.languages = languages
        v.languageSwitch = languageSwitch
        v.model = model
        return v
    }

    public func load() {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let v = SettingsValues(env: EnvFile.dictionary(text))
        name = v.name
        hfToken = v.hfToken
        assistant = v.assistant
        languages = v.languages
        languageSwitch = v.languageSwitch
        model = v.model
    }

    public func save() {
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? PrivateFile.write(Data(values.render(over: old).utf8), to: url)
    }
}
