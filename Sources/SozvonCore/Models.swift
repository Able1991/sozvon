// User choices: summary assistant, speech recognition model, call languages.

import Foundation

public enum Assistant: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, cursor, opencode, zcode, none
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .opencode: return "OpenCode"
        case .zcode: return "ZCode"
        case .none: return L("Только локально")
        }
    }
    public var subtitle: String {
        switch self {
        case .claude: return L("Саммари и поиск проектов, в том числе вопросы открытым сессиям. Текст уходит в Anthropic.")
        case .codex: return L("Саммари и поиск проектов по прошлым сессиям. Текст уходит в OpenAI.")
        case .cursor: return L("Саммари и поиск проектов по прошлым чатам Cursor. Текст уходит в Cursor и к выбранной там модели.")
        case .opencode: return L("Саммари и поиск проектов. Текст уходит к провайдеру, выбранному в OpenCode.")
        case .zcode: return L("Саммари и поиск проектов. Текст уходит в Z.AI.")
        case .none: return L("Без саммари. Ничего не покидает Mac.")
        }
    }
    public var symbol: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .opencode: return "terminal"
        case .zcode: return "wand.and.stars"
        case .none: return "lock.shield.fill"
        }
    }
    /// Who receives the summary text.
    public var vendor: String {
        switch self {
        case .claude: return "Anthropic"
        case .codex: return "OpenAI"
        case .cursor: return "Cursor"
        case .opencode: return "OpenCode"
        case .zcode: return "Z.AI"
        case .none: return ""
        }
    }
    public var cli: String? {
        switch self {
        case .claude, .codex: return rawValue
        case .cursor: return "cursor-agent"
        case .opencode: return "opencode"
        case .zcode: return "zcode"
        case .none: return nil
        }
    }

    /// Where to look for the assistant's CLI.
    public static let searchDirs = ["\(Paths.home.path)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    /// The ZCode CLI ships inside the app; this is the second place to look when there is no `zcode` on PATH.
    public static let zcodeApps = ["/Applications", "\(Paths.home.path)/Applications"]

    /// Full path to the CLI, if it's installed.
    public var cliPath: String? {
        guard let cli else { return nil }
        if let onPath = Self.searchDirs.map({ "\($0)/\(cli)" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return onPath
        }
        if self == .zcode {
            return Self.zcodeApps.map { "\($0)/ZCode.app/Contents/Resources/glm/zcode.cjs" }
                .first { FileManager.default.isReadableFile(atPath: $0) }
        }
        return nil
    }

    /// Screenshots (the preview build's --all-assistants): every assistant shows as installed and connected,
    /// without running or reading any real CLI or config.
    nonisolated(unsafe) public static var previewInstalled = false

    public var isAvailable: Bool { Self.previewInstalled || cli == nil || cliPath != nil }

    /// Terminal command that installs the CLI where `searchDirs` finds it (~/.local/bin or Homebrew). An npm install
    /// under nvm lands elsewhere, and its node isn't on an app's PATH: these are the installers to suggest.
    public var installCommand: String? {
        switch self {
        case .claude: return "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: return "brew install --cask codex"
        case .cursor: return "curl https://cursor.com/install -fsS | bash"
        case .opencode: return "brew install opencode"
        case .zcode: return "brew install --cask zcode"
        case .none: return nil
        }
    }

    /// Default assistant: the first installed of Claude Code, Codex, Cursor, OpenCode, ZCode.
    public static func detect() -> Assistant {
        [Assistant.claude, .codex, .cursor, .opencode, .zcode].first { $0.isAvailable } ?? .none
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
        case .large: return L("Самая большая Whisper, примерно в 2 раза медленнее Turbo.")
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
    /// Whisper detects languages; the onnx models (GigaAM, Parakeet) can't.
    public var isWhisper: Bool { supportsPrompt }

    /// The model for Russian tracks, as the engine decides it (models.ru_model): only after a Whisper main model,
    /// whose language detection sorts the tracks, and only GigaAM or Parakeet.
    public static func ruModel(main: WhisperModel, ru: WhisperModel?) -> WhisperModel? {
        guard let ru, ru != main, main.isWhisper, !ru.isWhisper else { return nil }
        return ru
    }

    /// Which model "Auto" means for a call in `languages` ([] = any): Russian only goes to the Russian model,
    /// several languages are sorted per track (`nil`: by language), no Russian stays on the main one.
    public static func auto(languages: [SpeechLanguage], main: WhisperModel, ru: WhisperModel?) -> WhisperModel? {
        guard let ru = ruModel(main: main, ru: ru) else { return main }
        if languages == [.ru] { return ru }
        if !languages.isEmpty && !languages.contains(.ru) { return main }
        return nil
    }

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
