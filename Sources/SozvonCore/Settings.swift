// Настройки пользователя в .env движка (контракт, раздел 2).

import Combine
import Foundation

/// Файл `KEY=value` построчно. Чужие ключи и комментарии сохраняются как есть.
/// Значения пишутся в двойных кавычках с экранированием: python-dotenv движка читает
/// `SOZVON_ME=Иван #2` без кавычек как «Иван» (всё после « #» для него комментарий).
public enum EnvFile {
    /// Пары ключ-значение без комментариев и пустых строк. Кавычки снимаются, как у python-dotenv.
    public static func parse(_ text: String) -> [(String, String)] {
        text.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { return nil }
            return (String(l[..<eq]).trimmingCharacters(in: .whitespaces), value(String(l[l.index(after: eq)...])))
        }
    }

    /// Значение после «=»: "в двойных" (с \\, \", \n, \t), 'в одинарных' (как есть) или голое
    /// (до « #», без пробелов по краям).
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

    /// Значение в двойных кавычках: \\, " и переводы строк экранируются.
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

    /// Убрать строки с ключами из `remove` и с ключами из `set`, дописать `set` в конец (в кавычках).
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

/// Значения настроек и их ключи в .env. Чистая модель: читается из словаря и пишется в пары.
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
    /// Языки звонков. Пусто: определять любой. Несколько: определять среди них.
    public var languages: [SpeechLanguage] = [.ru]
    /// Язык может меняться посреди речи одного человека: определять его для каждой фразы.
    public var languageSwitch = false
    public var model: WhisperModel = .turbo

    public init() {}

    /// Из ключей .env. `CALL_ME_NAME` принимается как старое имя `SOZVON_ME`.
    /// Помощник не задан: `detect` выбирает установленный.
    public init(env kv: [String: String], detect: () -> Assistant = Assistant.detect) {
        name = kv[Key.me] ?? kv[Key.legacyMe] ?? ""
        hfToken = kv[Key.hfToken] ?? ""
        languages = SpeechLanguage.parse(kv[Key.language] ?? "ru")
        languageSwitch = kv[Key.langSwitch] == "1"
        model = kv[Key.model].flatMap(WhisperModel.init(rawValue:)) ?? .turbo
        assistant = kv[Key.llm].flatMap(Assistant.init(rawValue:)) ?? detect()
    }

    /// Ключи, которыми управляет приложение (старые имена убираются при записи).
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

    /// Новый текст .env: свои ключи заменены, чужие сохранены.
    public func render(over text: String) -> String {
        EnvFile.merge(text, set: pairs, remove: Self.managedKeys)
    }
}

/// Настройки для окон: меняются в интерфейсе, сохраняются в .env с правами 600.
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
