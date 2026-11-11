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
        /// Compatibility shim: the old name of `SOZVON_ME`. Can go in 0.3.0 (and with it the fallback in `init(env:)`).
        public static let legacyMe = "CALL_ME_NAME"
        public static let llm = "SOZVON_LLM"
        public static let language = "SOZVON_LANGUAGE"
        public static let langSwitch = "SOZVON_LANG_SWITCH"
        public static let model = "SOZVON_MODEL"
        public static let serverURL = "SOZVON_SERVER_URL"
        public static let serverPassword = "SOZVON_SERVER_PASSWORD"
        public static let syncVoices = "SOZVON_SYNC_VOICES"
        public static let syncAudio = "SOZVON_SYNC_AUDIO"
        public static let summaryLanguage = "SOZVON_SUMMARY_LANGUAGE"
    }
    public static let envVersion = 1

    public var name = ""
    public var assistant: Assistant = .none
    /// Call languages. Empty: detect any. Several: detect among them.
    public var languages: [SpeechLanguage] = [.ru]
    /// The language may switch mid-speech for one person: detect it for each phrase.
    public var languageSwitch = false
    public var model: WhisperModel = .turbo
    /// Own server (optional): address and password.
    public var serverURL = ""
    public var serverPassword = ""
    /// Voice prints go to the own server too (absent in .env: on).
    public var syncVoices = true
    /// Call audio goes to the own server too (absent in .env: on).
    public var syncAudio = true
    /// The summary's language; nil: the conversation's.
    public var summaryLanguage: SpeechLanguage?

    public init() {}

    /// From .env keys. `CALL_ME_NAME` is accepted as the old name of `SOZVON_ME`.
    /// No assistant set: `detect` picks the installed one.
    public init(env kv: [String: String], detect: () -> Assistant = Assistant.detect) {
        name = kv[Key.me] ?? kv[Key.legacyMe] ?? ""
        languages = SpeechLanguage.parse(kv[Key.language] ?? "ru")
        languageSwitch = kv[Key.langSwitch] == "1"
        model = kv[Key.model].flatMap(WhisperModel.init(rawValue:)) ?? .turbo
        assistant = kv[Key.llm].flatMap(Assistant.init(rawValue:)) ?? detect()
        serverURL = kv[Key.serverURL] ?? ""
        serverPassword = kv[Key.serverPassword] ?? ""
        syncVoices = kv[Key.syncVoices] != "0"
        syncAudio = kv[Key.syncAudio] != "0"
        summaryLanguage = kv[Key.summaryLanguage].flatMap(SpeechLanguage.init(rawValue:)).flatMap { $0 == .auto ? nil : $0 }
    }

    /// Keys managed by the app (old names are removed on write).
    public static let managedKeys: Set<String> = [Key.version, Key.me, Key.legacyMe, Key.llm, Key.language,
                                                  Key.langSwitch, Key.model, Key.serverURL,
                                                  Key.serverPassword, Key.syncVoices, Key.syncAudio, Key.summaryLanguage]

    public var pairs: [(String, String)] {
        var kv: [(String, String)] = [(Key.version, String(Self.envVersion))]
        let me = name.trimmingCharacters(in: .whitespaces)
        if !me.isEmpty { kv.append((Key.me, me)) }
        kv.append((Key.llm, assistant.rawValue))
        kv.append((Key.language, SpeechLanguage.serialize(languages)))
        kv.append((Key.langSwitch, languageSwitch ? "1" : "0"))
        kv.append((Key.model, model.rawValue))
        let url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty { kv.append((Key.serverURL, url)) }
        let password = serverPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !password.isEmpty { kv.append((Key.serverPassword, password)) }
        kv.append((Key.syncVoices, syncVoices ? "1" : "0"))
        kv.append((Key.syncAudio, syncAudio ? "1" : "0"))
        kv.append((Key.summaryLanguage, summaryLanguage?.rawValue ?? "auto"))
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
    @Published public var assistant: Assistant = .none
    @Published public var languages: [SpeechLanguage] = [.ru]
    @Published public var languageSwitch = false
    @Published public var model: WhisperModel = .turbo
    @Published public var serverURL = ""
    @Published public var serverPassword = ""
    @Published public var syncVoices = true
    @Published public var syncAudio = true
    @Published public var summaryLanguage: SpeechLanguage?

    private let url: URL

    public init(url: URL = Paths.env) {
        self.url = url
        load()
    }

    public var values: SettingsValues {
        var v = SettingsValues()
        v.name = name
        v.assistant = assistant
        v.languages = languages
        v.languageSwitch = languageSwitch
        v.model = model
        v.serverURL = serverURL
        v.serverPassword = serverPassword
        v.syncVoices = syncVoices
        v.syncAudio = syncAudio
        v.summaryLanguage = summaryLanguage
        return v
    }

    public func load() {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let v = SettingsValues(env: EnvFile.dictionary(text))
        name = v.name
        assistant = v.assistant
        languages = v.languages
        languageSwitch = v.languageSwitch
        model = v.model
        serverURL = v.serverURL
        serverPassword = v.serverPassword
        syncVoices = v.syncVoices
        syncAudio = v.syncAudio
        summaryLanguage = v.summaryLanguage
    }

    /// The own server is set up: a valid address and a password.
    public var hasServer: Bool { OwnServer.isConfigured(url: serverURL, password: serverPassword) }

    public func save() { try? write() }

    /// Save, reporting failure (Connect Cloudflare must not lose a password it just set on the server).
    public func write() throws {
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try PrivateFile.write(Data(values.render(over: old).utf8), to: url)
    }
}

/// UserDefaults keys that more than one place reads or writes. A key used in one place stays next to its owner.
public enum DefaultsKey {
    /// When a missing echo model was last fetched (EngineState.shouldRetryEchoModel).
    public static let echoModelTry = "echoModelTry"
    /// The profile chosen for the last call: the default of the next one.
    public static let lastProfile = "lastProfile"
    /// Where the setup wizard continues after the app restarted to apply a permission.
    public static let setupResumeStep = "setupResumeStep"
    /// The project filter of the Calls window.
    public static let callsProject = "callsProject"
}

/// "Warn About Silence": the notifications when you or the other side can't be heard even after the
/// automatic recapture. Off silences only those notifications; the recapture itself always runs.
public enum SilenceAlerts {
    public static let key = "silenceAlerts"

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    public static var enabled: Bool {
        get { isEnabled(in: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

extension SpeechLanguage {
    /// The call languages after clicking `lang` in a checklist: a real language toggles, "Detect automatically"
    /// clears the list (an empty list means any language). The result keeps the canonical order.
    public static func toggling(_ lang: SpeechLanguage, in list: [SpeechLanguage]) -> [SpeechLanguage] {
        guard lang != .auto else { return [] }
        let picked = list.contains(lang) ? list.filter { $0 != lang } : list + [lang]
        return real.filter { picked.contains($0) }
    }
}

/// The interface language chosen in Settings, stored as the app's `AppleLanguages` override.
public enum InterfaceLanguage {
    /// Languages the interface is translated to.
    public static let supported = ["ru", "en"]

    /// The Settings picker's tag for an `AppleLanguages` override: "ru" for ["ru-RU"], "" (as in the system)
    /// for no override or a language Sozvon isn't translated to.
    public static func tag(_ appleLanguages: [String]?) -> String {
        guard let first = appleLanguages?.first else { return "" }
        let code = String(first.prefix { $0 != "-" && $0 != "_" }).lowercased()
        return supported.contains(code) ? code : ""
    }
}
