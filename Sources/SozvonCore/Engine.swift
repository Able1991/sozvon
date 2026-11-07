// Engine: Python in the data folder. Install state, copying code from the bundle,
// the environment, and running scripts per the contract (docs/CONTRACT.md).

import CryptoKit
import Foundation

/// Engine state in the data folder.
public enum EngineState: Equatable, Sendable {
    /// No Python environment: first-run setup is needed.
    case notInstalled
    /// The environment was built for a different uv.lock (the app was updated): setup must run again.
    case needsUpdate
    /// The selected model isn't downloaded.
    case modelMissing(WhisperModel)
    case ready

    /// Ready to record and transcribe (an environment update runs in the background, transcriptions will wait).
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

    /// Same as setup.sh: the first 16 hex chars of the sha256 of uv.lock.
    public static func lockHash(_ data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}

public enum Engine {
    /// Engine version bundled in this app (a code hash, computed at build time in build.sh).
    public static var bundledVersion: String {
        (Paths.bundledEngine.flatMap { try? String(contentsOf: $0.appendingPathComponent("ENGINE_VERSION"), encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines))
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
    }

    /// "Don't get in the way": transcription at lower priority with 2 threads on regular cores.
    public static var gentle: Bool {
        get { UserDefaults.standard.object(forKey: "gentle") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "gentle") }
    }

    /// Language of engine messages and transcript files: ru or en.
    public static var uiLanguage: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true ? "en" : "ru"
    }

    /// Environment for every engine run (contract, section 2).
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment,
                                   data: URL = Paths.data, calls: URL = Paths.calls,
                                   gentle: Bool = Engine.gentle, uiLanguage: String = Engine.uiLanguage,
                                   mcpToken: String? = MCP.token, pyannoteTar: URL? = Engine.bundledPyannote) -> [String: String] {
        var env = base
        env.removeValue(forKey: "WHISPER_MCP_DIR")  // old name: the engine must not pick up a foreign folder
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

    /// Launch arguments for an engine script: python directly or through taskpolicy ("Don't get in the way":
    /// the utility class yields to your apps; background also throttled the GPU, and a call took 30 times longer).
    public static func command(_ script: URL, _ args: [String], gentle: Bool = Engine.gentle) -> (URL, [String]) {
        let taskpolicy = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        if gentle, FileManager.default.isExecutableFile(atPath: taskpolicy.path) {
            return (taskpolicy, ["-c", "utility", Paths.python.path, script.path] + args)
        }
        return (Paths.python, [script.path] + args)
    }

    /// Run an engine script (`bin/<name>`) with the contract environment.
    @discardableResult
    public static func runScript(_ name: String, _ args: [String] = [], log: URL? = nil, appendLog: Bool = false,
                                 onLine: ProcessRunner.LineHandler? = nil,
                                 done: @escaping ProcessRunner.DoneHandler) -> RunningProcess? {
        let (exe, argv) = command(Paths.engineScript(name), args)
        return ProcessRunner.run(exe, argv, environment: environment(), currentDirectory: Paths.data,
                                 log: log, appendLog: appendLog, onLine: onLine, done: done)
    }

    /// Install or update the environment: setup.sh from the data folder (fresh code from the bundle first).
    @discardableResult
    public static func setup(onLine: ProcessRunner.LineHandler? = nil,
                             done: @escaping @MainActor @Sendable (Bool) -> Void) -> RunningProcess? {
        _ = syncCode()
        return ProcessRunner.run(URL(fileURLWithPath: "/bin/bash"),
                                 [Paths.data.appendingPathComponent("setup.sh").path, Paths.data.path],
                                 environment: environment(), currentDirectory: Paths.data,
                                 log: Paths.setupLog, onLine: onLine) { done($0 == 0) }
    }

    /// Lay out the engine code from the bundle into the data folder (on first launch and after an app update).
    @discardableResult
    public static func syncCode() -> Bool {
        guard !Paths.isDevEngine, let src = Paths.bundledEngine else { return true }
        try? FileManager.default.createDirectory(at: Paths.profiles, withIntermediateDirectories: true)
        return EngineSync.sync(from: src, to: Paths.data, version: bundledVersion)
    }

    // MARK: Last engine error (for the "Engine status" section in Settings)

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

/// Copying the engine code from the bundle into the data folder.
public enum EngineSync {
    public static let stamp = ".engine-version"
    public static let pyannoteTar = "pyannote-models-v1.tar.gz"
    public static let defaultVocab = "vocab.default.json"

    /// Not code: these names in the data folder belong to the install and the user, never touch them.
    public static let protected: Set<String> = [".venv", "models", "profiles", "voices", "hf-cache", "vocab.json",
                                                ".env", stamp, ".venv-lock", ".installed", ".no-diarization", ".mcp-token",
                                                ".lock", "vocab.json.lock", "index.db", "index.db.lock"]
    /// Present in the bundle but not copied into the data folder
    /// (the archive is passed to setup.sh via SOZVON_PYANNOTE_TAR,
    /// the default dictionary becomes vocab.json only on first install).
    public static let skipped: Set<String> = [pyannoteTar, defaultVocab]
    /// Modules of old installs in `<data>/scripts/`: in contract 1 the code lives
    /// in sozvon_engine/ and bin/, and scripts/ was removed from the bundle.
    public static let obsoleteScripts = ["voiceid.py", "transcribe.py", "diarize.py", "enginedir.py", "llm.py",
                                         "langid.py", "asr_onnx.py"]

    /// Copy the whole engine tree (including ENGINE_VERSION and entire subfolders).
    /// Folders are replaced wholesale (no stale files remain), files are overwritten. The version stamp
    /// is written only on full success, otherwise the copy is retried on the next launch.
    /// vocab.default.json becomes vocab.json if there is no dictionary yet.
    @discardableResult
    public static func sync(from src: URL, to dst: URL, version: String) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let vocab = dst.appendingPathComponent("vocab.json")
        let vocabSrc = src.appendingPathComponent(defaultVocab)
        // Under the engine's dictionary lock: "no file, put ours" must
        // not clobber a dictionary the engine is writing right now. No lock: no copy (the next launch tries again).
        try? FileLock.with(vocab) {
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
            // Copy alongside, then swap: on failure the old version stays intact.
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
