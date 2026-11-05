// Движок: Python в папке данных. Состояние установки, копирование кода из бандла,
// окружение и запуск скриптов по контракту (docs/CONTRACT.md).

import CryptoKit
import Foundation

/// Состояние движка в папке данных.
public enum EngineState: Equatable, Sendable {
    /// Нет окружения Python: нужна первая настройка.
    case notInstalled
    /// Окружение собрано под другой uv.lock (приложение обновилось): нужен повторный setup.
    case needsUpdate
    /// Выбранная модель не скачана.
    case modelMissing(WhisperModel)
    case ready

    /// Можно записывать и расшифровывать (обновление окружения идёт в фоне, расшифровки подождут).
    public var isUsable: Bool { self == .ready || self == .needsUpdate }

    public static func evaluate(data: URL, model: WhisperModel, isDevEngine: Bool) -> EngineState {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: data.appendingPathComponent(".venv/bin/python3").path) else { return .notInstalled }
        if !isDevEngine, let lock = try? Data(contentsOf: data.appendingPathComponent("uv.lock")) {
            let installed = (try? String(contentsOf: data.appendingPathComponent(".venv-lock"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if installed != lockHash(lock) { return .needsUpdate }
        }
        return model.isDownloaded(in: data) ? .ready : .modelMissing(model)
    }

    /// Как setup.sh: первые 16 hex sha256 от uv.lock.
    public static func lockHash(_ data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}

public enum Engine {
    /// Версия движка в этом приложении (хеш кода, считается при сборке в build.sh).
    public static var bundledVersion: String {
        (Paths.bundledEngine.flatMap { try? String(contentsOf: $0.appendingPathComponent("ENGINE_VERSION"), encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines))
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
    }

    /// «Не мешать работе»: расшифровка с пониженным приоритетом и 2 потоками на обычных ядрах.
    public static var gentle: Bool {
        get { UserDefaults.standard.object(forKey: "gentle") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "gentle") }
    }

    /// Язык сообщений движка и файлов расшифровки: ru или en.
    public static var uiLanguage: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true ? "en" : "ru"
    }

    /// Окружение каждого запуска движка (контракт, раздел 2).
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment,
                                   data: URL = Paths.data, calls: URL = Paths.calls,
                                   gentle: Bool = Engine.gentle, uiLanguage: String = Engine.uiLanguage,
                                   mcpToken: String? = MCP.token, pyannoteTar: URL? = Engine.bundledPyannote) -> [String: String] {
        var env = base
        env.removeValue(forKey: "WHISPER_MCP_DIR")  // старое имя: движок не должен взять чужую папку
        env["PATH"] = [data.appendingPathComponent(".venv/bin").path, "\(Paths.home.path)/.local/bin",
                       "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["SOZVON_DATA_DIR"] = data.path
        env["SOZVON_CALLS_DIR"] = calls.path
        env["SOZVON_UI_LANG"] = uiLanguage
        if gentle { env["SOZVON_THREADS"] = "2" } else { env.removeValue(forKey: "SOZVON_THREADS") }
        env["SOZVON_MCP_PORT"] = String(MCP.port)
        if let mcpToken { env["SOZVON_MCP_TOKEN"] = mcpToken }
        if let pyannoteTar { env["SOZVON_PYANNOTE_TAR"] = pyannoteTar.path }
        return env
    }

    public static var bundledPyannote: URL? {
        guard let u = Paths.bundledEngine?.appendingPathComponent(EngineSync.pyannoteTar),
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    /// Аргументы запуска скрипта движка: python напрямую или через taskpolicy («Не мешать работе»:
    /// класс utility уступает твоим программам; background душил и видеокарту, звонок шёл в 30 раз дольше).
    public static func command(_ script: URL, _ args: [String], gentle: Bool = Engine.gentle) -> (URL, [String]) {
        let taskpolicy = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        if gentle, FileManager.default.isExecutableFile(atPath: taskpolicy.path) {
            return (taskpolicy, ["-c", "utility", Paths.python.path, script.path] + args)
        }
        return (Paths.python, [script.path] + args)
    }

    /// Запустить скрипт движка (`bin/<имя>`) с окружением по контракту.
    @discardableResult
    public static func runScript(_ name: String, _ args: [String] = [], log: URL? = nil,
                                 onLine: ProcessRunner.LineHandler? = nil,
                                 done: @escaping ProcessRunner.DoneHandler) -> RunningProcess? {
        let (exe, argv) = command(Paths.engineScript(name), args)
        return ProcessRunner.run(exe, argv, environment: environment(), currentDirectory: Paths.data,
                                 log: log, onLine: onLine, done: done)
    }

    /// Установка или обновление окружения: setup.sh из папки данных (сначала свежий код из бандла).
    @discardableResult
    public static func setup(onLine: ProcessRunner.LineHandler? = nil,
                             done: @escaping @MainActor @Sendable (Bool) -> Void) -> RunningProcess? {
        _ = syncCode()
        return ProcessRunner.run(URL(fileURLWithPath: "/bin/bash"),
                                 [Paths.data.appendingPathComponent("setup.sh").path, Paths.data.path],
                                 environment: environment(), currentDirectory: Paths.data,
                                 log: Paths.setupLog, onLine: onLine) { done($0 == 0) }
    }

    /// Разложить код движка из бандла в папку данных (при первом запуске и после обновления приложения).
    @discardableResult
    public static func syncCode() -> Bool {
        guard !Paths.isDevEngine, let src = Paths.bundledEngine else { return true }
        try? FileManager.default.createDirectory(at: Paths.profiles, withIntermediateDirectories: true)
        return EngineSync.sync(from: src, to: Paths.data, version: bundledVersion)
    }

    // MARK: Последняя ошибка движка (для блока «Состояние движка» в настройках)

    public struct Failure: Equatable, Sendable {
        public let message: String
        public let date: Date
        public let log: URL?
    }

    public static var lastFailure: Failure? {
        let d = UserDefaults.standard
        guard let m = d.string(forKey: "engineLastError"), !m.isEmpty else { return nil }
        return Failure(message: m, date: Date(timeIntervalSince1970: d.double(forKey: "engineLastErrorAt")),
                       log: d.string(forKey: "engineLastErrorLog").map { URL(fileURLWithPath: $0) })
    }

    public static func recordFailure(_ message: String, log: URL?) {
        let d = UserDefaults.standard
        d.set(message, forKey: "engineLastError")
        d.set(Date().timeIntervalSince1970, forKey: "engineLastErrorAt")
        d.set(log?.path, forKey: "engineLastErrorLog")
    }
}

/// Копирование кода движка из бандла в папку данных.
public enum EngineSync {
    public static let versionFile = "ENGINE_VERSION"
    public static let stamp = ".engine-version"
    public static let pyannoteTar = "pyannote-models-v1.tar.gz"
    public static let defaultVocab = "vocab.default.json"

    /// Не код: эти имена в папке данных принадлежат установке и пользователю, их не трогаем никогда.
    public static let protected: Set<String> = [".venv", "models", "profiles", "voices", "hf-cache", "vocab.json",
                                                ".env", stamp, ".venv-lock", ".installed", ".no-diarization", ".mcp-token",
                                                ".lock", "vocab.json.lock"]
    /// Есть в бандле, но в папку данных не копируется (архив передаётся setup.sh через SOZVON_PYANNOTE_TAR,
    /// словарь по умолчанию становится vocab.json только при первой установке).
    public static let skipped: Set<String> = [pyannoteTar, defaultVocab]
    /// Модули старых установок в `<data>/scripts/`: в контракте 1 код живёт в sozvon_engine/ и bin/, scripts/ из бандла убран.
    public static let obsoleteScripts = ["voiceid.py", "transcribe.py", "diarize.py", "enginedir.py", "llm.py",
                                         "langid.py", "asr_onnx.py"]

    /// Скопировать всё дерево движка (с ENGINE_VERSION, вложенные папки целиком). Папки заменяются целиком (старые файлы не остаются),
    /// файлы перезаписываются. Метка версии пишется только при полном успехе, иначе в следующий
    /// запуск копирование повторится. vocab.default.json становится vocab.json, если словаря ещё нет.
    @discardableResult
    public static func sync(from src: URL, to dst: URL, version: String) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let vocab = dst.appendingPathComponent("vocab.json")
        let vocabSrc = src.appendingPathComponent(defaultVocab)
        // Под замком словаря движка: «нет файла, кладём свой» не должно затереть словарь, который движок как раз пишет.
        FileLock.with(vocab) {
            if !fm.fileExists(atPath: vocab.path), fm.fileExists(atPath: vocabSrc.path) {
                try? fm.copyItem(at: vocabSrc, to: vocab)
            }
        }
        let stampURL = dst.appendingPathComponent(stamp)
        if (try? String(contentsOf: stampURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == version {
            return true
        }
        guard let items = try? fm.contentsOfDirectory(atPath: src.path) else { return false }
        var ok = true
        for name in items.sorted() where !skipped.contains(name) && !protected.contains(name) {
            let to = dst.appendingPathComponent(name)
            // Копируем рядом и подменяем: при сбое старая версия остаётся целой.
            let tmp = dst.appendingPathComponent(".\(name).sync-tmp")
            try? fm.removeItem(at: tmp)
            do {
                try fm.copyItem(at: src.appendingPathComponent(name), to: tmp)
                if fm.fileExists(atPath: to.path) {
                    _ = try fm.replaceItemAt(to, withItemAt: tmp)
                } else {
                    try fm.moveItem(at: tmp, to: to)
                }
            } catch {
                try? fm.removeItem(at: tmp)
                ok = false
            }
        }
        if ok {
            let scripts = dst.appendingPathComponent("scripts")
            for f in obsoleteScripts { try? fm.removeItem(at: scripts.appendingPathComponent(f)) }
            try? version.write(to: stampURL, atomically: true, encoding: .utf8)
        }
        return ok
    }
}
