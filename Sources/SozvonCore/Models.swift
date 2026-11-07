// User choices: summary assistant, speech recognition model, call languages.

import Foundation

public enum Assistant: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, cursor, none
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .none: return L("Только локально")
        }
    }
    public var subtitle: String {
        switch self {
        case .claude: return L("Саммари и поиск проектов, в том числе вопросы открытым сессиям. Текст уходит в Anthropic.")
        case .codex: return L("Саммари и поиск проектов по прошлым сессиям. Текст уходит в OpenAI.")
        case .cursor: return L("Саммари и поиск проектов по прошлым чатам Cursor. Текст уходит в Cursor и к выбранной там модели.")
        case .none: return L("Без саммари. Ничего не покидает Mac.")
        }
    }
    public var symbol: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .none: return "lock.shield.fill"
        }
    }
    /// Who receives the summary text.
    public var vendor: String {
        switch self {
        case .claude: return "Anthropic"
        case .codex: return "OpenAI"
        case .cursor: return "Cursor"
        case .none: return ""
        }
    }
    public var cli: String? {
        switch self {
        case .claude, .codex: return rawValue
        case .cursor: return "cursor-agent"
        case .none: return nil
        }
    }

    /// Where to look for the assistant's CLI.
    public static let searchDirs = ["\(Paths.home.path)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    /// Full path to the CLI, if it's installed.
    public var cliPath: String? {
        guard let cli else { return nil }
        return Self.searchDirs.map { "\($0)/\(cli)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var isAvailable: Bool { cli == nil || cliPath != nil }

    /// Default assistant: the first installed of Claude Code, Codex, Cursor.
    public static func detect() -> Assistant {
        [Assistant.claude, .codex, .cursor].first { $0.isAvailable } ?? .none
    }
}

/// Speech recognition model. Keys match engine/models.json (contract: SOZVON_MODEL).
public enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case turbo, large = "large-v3", small, gigaam, parakeet
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .turbo: return "Whisper Turbo"
        case .large: return "Whisper Large v3"
        case .small: return "Whisper Small"
        case .gigaam: return "GigaAM v3"
        case .parakeet: return "Parakeet v3"
        }
    }
    public var dir: String {
        switch self {
        case .turbo: return "whisper-large-v3-turbo"
        case .large: return "whisper-large-v3"
        case .small: return "whisper-small"
        case .gigaam: return "gigaam-v3-onnx"
        case .parakeet: return "parakeet-tdt-0.6b-v3-onnx"
        }
    }
    public var size: String {
        switch self {
        case .turbo: return L("1,6 ГБ")
        case .large: return L("3,1 ГБ")
        case .small: return L("0,5 ГБ")
        case .gigaam: return L("0,2 ГБ")
        case .parakeet: return L("0,7 ГБ")
        }
    }
    public var subtitle: String {
        switch self {
        case .turbo: return L("Быстро и точно. Час звонка за 3-4 минуты на M1.")
        case .large: return L("Самая точная, примерно в 2 раза медленнее Turbo.")
        case .small: return L("Лёгкая: для Mac с 8 ГБ памяти и экономии места. Точность ниже.")
        case .gigaam: return L("Только русский, от Сбера. Лёгкая и быстрая, но без словаря проектов.")
        case .parakeet: return L("25 европейских языков, от NVIDIA. Очень быстрая, но без словаря проектов.")
        }
    }
    public var symbol: String {
        switch self {
        case .turbo: return "hare.fill"
        case .large: return "scope"
        case .small: return "leaf.fill"
        case .gigaam: return "character.book.closed.fill"
        case .parakeet: return "bolt.fill"
        }
    }
    /// Models without Whisper prompting: project terms don't work, only auto-replacements.
    public var supportsPrompt: Bool { self != .gigaam && self != .parakeet }

    public var isDownloaded: Bool { isDownloaded(in: Paths.data) }

    /// Whether the model is fully downloaded. The installer sets the .complete marker per models.json;
    /// for old installs without the marker we check the weight files themselves.
    public func isDownloaded(in data: URL) -> Bool {
        let fm = FileManager.default
        let models = data.appendingPathComponent("models")
        let d = models.appendingPathComponent(dir)
        let vad = models.appendingPathComponent("silero-vad-onnx")
        let hasVAD = fm.fileExists(atPath: vad.appendingPathComponent(".complete").path)
            || fm.fileExists(atPath: vad.appendingPathComponent("silero_vad.onnx").path)
        if fm.fileExists(atPath: d.appendingPathComponent(".complete").path) {
            return supportsPrompt || hasVAD
        }
        if !supportsPrompt {
            let enc = self == .gigaam ? "v3_e2e_rnnt_encoder.int8.onnx" : "encoder-model.int8.onnx"
            return fm.fileExists(atPath: d.appendingPathComponent(enc).path) && hasVAD
        }
        return ["weights.safetensors", "weights.npz"].contains {
            fm.fileExists(atPath: d.appendingPathComponent($0).path)
        }
    }
}

/// Spoken language of the call.
public enum SpeechLanguage: String, CaseIterable, Identifiable, Sendable {
    case ru, en, uk, de, es, auto
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ru: return L("Русский")
        case .en: return "English"
        case .uk: return L("Українська")
        case .de: return "Deutsch"
        case .es: return "Español"
        case .auto: return L("Определять сам")
        }
    }

    /// Actual languages (without "Detect automatically").
    public static var real: [SpeechLanguage] { allCases.filter { $0 != .auto } }

    /// "ru,en" -> [.ru, .en]; "auto" or empty -> [] (any language).
    public static func parse(_ s: String) -> [SpeechLanguage] {
        s.split(separator: ",").compactMap { SpeechLanguage(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != .auto }
    }

    public static func serialize(_ list: [SpeechLanguage]) -> String {
        list.isEmpty ? "auto" : list.map(\.rawValue).joined(separator: ",")
    }

    /// "Russian + English" or "Detect automatically".
    public static func summary(_ list: [SpeechLanguage]) -> String {
        list.isEmpty ? L("Определять сам") : list.map(\.title).joined(separator: " + ")
    }
}
