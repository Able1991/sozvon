import Foundation
import XCTest
@testable import SozvonCore

final class EngineStateTests: TempDirTestCase {
    func testWhatKeepsATranscriptionWaiting() {
        XCTAssertEqual(EngineState.notInstalled.waitReason, .engine)
        XCTAssertEqual(EngineState.modelMissing(.turbo).waitReason, .model)
        XCTAssertNil(EngineState.ready.waitReason)
        XCTAssertNil(EngineState.needsUpdate.waitReason, "the update runs by itself and has its own notice")
    }

    private func makePython() throws {
        let py = data.appendingPathComponent(".venv/bin/python3")
        try write("#!/bin/sh\n", py)
        chmod(py.path, 0o755)
    }

    private func makeModel(_ m: WhisperModel) throws {
        try write("", data.appendingPathComponent("models/\(m.dir)/.complete"))
    }

    func testNotInstalledWithoutVenv() {
        XCTAssertEqual(EngineState.evaluate(data: data, model: .turbo, isDevEngine: false), .notInstalled,
                       "no venv and no model: not installed")
    }

    func testModelMissingAndReady() throws {
        try makePython()
        XCTAssertEqual(EngineState.evaluate(data: data, model: .turbo, isDevEngine: false), .modelMissing(.turbo))
        try makeModel(.turbo)
        XCTAssertEqual(EngineState.evaluate(data: data, model: .turbo, isDevEngine: false), .ready)
        XCTAssertEqual(EngineState.evaluate(data: data, model: .gigaam, isDevEngine: false), .modelMissing(.gigaam))
    }

    func testOnnxModelNeedsVAD() throws {
        try makePython()
        try makeModel(.parakeet)
        XCTAssertEqual(EngineState.evaluate(data: data, model: .parakeet, isDevEngine: false), .modelMissing(.parakeet))
        try write("", data.appendingPathComponent("models/silero-vad-onnx/.complete"))
        XCTAssertEqual(EngineState.evaluate(data: data, model: .parakeet, isDevEngine: false), .ready)
    }

    func testNeedsUpdateWhenLockChanged() throws {
        try makePython()
        try makeModel(.turbo)
        try write("lock v2", data.appendingPathComponent("uv.lock"))
        try write("0000000000000000\n", data.appendingPathComponent(".venv-lock"))
        XCTAssertEqual(EngineState.evaluate(data: data, model: .turbo, isDevEngine: false), .needsUpdate)
        XCTAssertTrue(EngineState.needsUpdate.isUsable)
        XCTAssertEqual(EngineState.evaluate(data: data, model: .turbo, isDevEngine: true), .ready, "a custom engine is not updated")
        try write(EngineState.lockHash(Data("lock v2".utf8)) + "\n", data.appendingPathComponent(".venv-lock"))
        XCTAssertEqual(EngineState.evaluate(data: data, model: .turbo, isDevEngine: false), .ready)
    }

    /// evaluate runs on the main thread on every state change and render: once the files are known it must not
    /// read or hash them again, and it must still notice every change to them.
    func testLockFilesAreReadOncePerChange() throws {
        try makePython()
        try makeModel(.turbo)
        let lock = data.appendingPathComponent("uv.lock"), installed = data.appendingPathComponent(".venv-lock")
        try write("lock v1", lock)
        try write(EngineState.lockHash(Data("lock v1".utf8)) + "\n", installed)
        let state = { EngineState.evaluate(data: self.data, model: .turbo, isDevEngine: false) }
        XCTAssertEqual(state(), .ready)
        let loads = FileMemo.shared.loads
        for _ in 0..<5 { XCTAssertEqual(state(), .ready) }
        XCTAssertEqual(FileMemo.shared.loads, loads, "unchanged files are not read again")

        try write("lock v2", lock)  // same size, new content
        XCTAssertEqual(state(), .needsUpdate, "a new uv.lock is noticed")
        XCTAssertEqual(FileMemo.shared.loads, loads + 1, "only the changed file is read")
        try write(EngineState.lockHash(Data("lock v2".utf8)) + "\n", installed)
        XCTAssertEqual(state(), .ready, "a new .venv-lock is noticed")
        // Written in place, as setup.sh does (no new file, same size).
        let h = try FileHandle(forWritingTo: installed)
        try h.write(contentsOf: Data("0000000000000000\n".utf8))
        try h.close()
        XCTAssertEqual(state(), .needsUpdate, "an in-place rewrite is noticed")
        try FileManager.default.removeItem(at: installed)
        XCTAssertEqual(state(), .needsUpdate, "no .venv-lock: the environment is not for this uv.lock")
        try FileManager.default.removeItem(at: lock)
        XCTAssertEqual(state(), .ready, "no uv.lock: nothing to compare with")
    }

    func testFileMemoForgetsAMissingFile() throws {
        let f = tmp.appendingPathComponent("memo.txt")
        let memo = FileMemo()
        XCTAssertNil(memo.value(f) { _ in "x" })
        try write("a", f)
        XCTAssertEqual(memo.value(f) { String(decoding: $0, as: UTF8.self) }, "a")
        XCTAssertEqual(memo.value(f) { _ in "never called" }, "a")
        XCTAssertEqual(memo.loads, 1)
        try FileManager.default.removeItem(at: f)
        XCTAssertNil(memo.value(f) { _ in "x" })
        try write("b", f)
        XCTAssertEqual(memo.value(f) { String(decoding: $0, as: UTF8.self) }, "b")
    }

    func testEchoModelMissingUntilItsCompleteMarkerExists() throws {
        XCTAssertFalse(EngineState.echoModelMissing(data: data, isDevEngine: false), "the engine is not installed: the first install downloads everything itself")
        try makePython()
        XCTAssertTrue(EngineState.echoModelMissing(data: data, isDevEngine: false))
        XCTAssertFalse(EngineState.echoModelMissing(data: data, isDevEngine: true), "nothing is fetched for a custom engine")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(EngineState.shouldRetryEchoModel(data: data, isDevEngine: false, lastTry: nil, now: t0), "not tried yet")
        XCTAssertFalse(EngineState.shouldRetryEchoModel(data: data, isDevEngine: false, lastTry: t0 - 3600, now: t0), "an hour ago: not downloaded on every launch")
        XCTAssertTrue(EngineState.shouldRetryEchoModel(data: data, isDevEngine: false, lastTry: t0 - 86400, now: t0), "again a day later")
        XCTAssertTrue(EngineState.shouldRetryEchoModel(data: data, isDevEngine: false, lastTry: t0 + 3600, now: t0), "the clock was set back")
        XCTAssertFalse(EngineState.shouldRetryEchoModel(data: data, isDevEngine: true, lastTry: nil, now: t0))
        try write("", data.appendingPathComponent("models/\(EngineState.echoModelDir)/.complete"))
        XCTAssertFalse(EngineState.echoModelMissing(data: data, isDevEngine: false))
    }

    func testEchoModelFolderMatchesTheManifest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("engine/models.json"))) as? [String: Any]
        let aec = json?["aec"] as? [String: Any]
        XCTAssertEqual(aec?["dir"] as? String, EngineState.echoModelDir)
    }

    func testEnvironmentFollowsContract() {
        let env = Engine.environment(base: ["HOME": "/h", "SOZVON_THREADS": "8", "WHISPER_MCP_DIR": "/old"], data: data, calls: calls, gentle: false,
                                     uiLanguage: "en", mcpToken: "t", pyannoteTar: URL(fileURLWithPath: "/b/p.tar.gz"))
        XCTAssertEqual(env["SOZVON_DATA_DIR"], data.path)
        XCTAssertNil(env["WHISPER_MCP_DIR"], "the old name is no longer passed")
        XCTAssertEqual(env["SOZVON_CALLS_DIR"], calls.path)
        XCTAssertEqual(env["SOZVON_UI_LANG"], "en")
        XCTAssertNil(env["SOZVON_THREADS"], "without \"Don't get in the way\" threads are not limited")
        XCTAssertEqual(env["SOZVON_MCP_PORT"], "47816")
        XCTAssertEqual(env["SOZVON_MCP_TOKEN"], "t")
        XCTAssertEqual(env["SOZVON_PYANNOTE_TAR"], "/b/p.tar.gz")
        XCTAssertEqual(env["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(env["HOME"], "/h")
        XCTAssertTrue(env["PATH"]?.hasPrefix(data.appendingPathComponent(".venv/bin").path) == true)
        let gentle = Engine.environment(base: [:], data: data, calls: calls, gentle: true, uiLanguage: "ru", mcpToken: nil, pyannoteTar: nil)
        XCTAssertEqual(gentle["SOZVON_THREADS"], "2")
        XCTAssertNil(gentle["SOZVON_MCP_TOKEN"])
    }

    func testCommandUsesTaskpolicyWhenGentle() {
        let script = data.appendingPathComponent("bin/process_call.py")
        let (exe, args) = Engine.command(script, ["/calls/x"], gentle: true)
        XCTAssertEqual(exe.path, "/usr/sbin/taskpolicy")
        XCTAssertEqual(args, ["-c", "utility", Paths.python.path, script.path, "/calls/x"])
        let (exe2, args2) = Engine.command(script, ["/calls/x"], gentle: false)
        XCTAssertEqual(exe2.path, Paths.python.path)
        XCTAssertEqual(args2, [script.path, "/calls/x"])
    }
}

final class EngineSyncTests: TempDirTestCase {
    var bundle: URL { tmp.appendingPathComponent("bundle/engine") }

    private func makeBundle() throws {
        try write("server", bundle.appendingPathComponent("server.py"))
        try write("setup", bundle.appendingPathComponent("setup.sh"))
        try write("main", bundle.appendingPathComponent("bin/process_call.py"))
        try write("lib", bundle.appendingPathComponent("sozvon_engine/__init__.py"))
        try write("deep", bundle.appendingPathComponent("sozvon_engine/pipeline/run.py"))
        try write("{\"schema\": 1}", bundle.appendingPathComponent("vocab.default.json"))
        try write("abc", bundle.appendingPathComponent("ENGINE_VERSION"))
        try write("tar", bundle.appendingPathComponent("pyannote-models-v1.tar.gz"))
    }

    func testCopiesWholeTreeAndStamps() throws {
        try makeBundle()
        try write("user", data.appendingPathComponent("profiles/acme.json"))
        try write("venv", data.appendingPathComponent(".venv/marker"))
        try write("stale", data.appendingPathComponent("sozvon_engine/old.py"))
        XCTAssertTrue(EngineSync.sync(from: bundle, to: data, version: "v1"))
        let fm = FileManager.default
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("bin/process_call.py"), encoding: .utf8), "main")
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("sozvon_engine/__init__.py"), encoding: .utf8), "lib")
        XCTAssertFalse(fm.fileExists(atPath: data.appendingPathComponent("sozvon_engine/old.py").path), "the folder is replaced as a whole")
        XCTAssertTrue(fm.fileExists(atPath: data.appendingPathComponent("server.py").path))
        XCTAssertFalse(fm.fileExists(atPath: data.appendingPathComponent("pyannote-models-v1.tar.gz").path), "the archive is not copied")
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("ENGINE_VERSION"), encoding: .utf8), "abc",
                       "the engine reads its own version")
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("sozvon_engine/pipeline/run.py"), encoding: .utf8),
                       "deep", "nested folders are copied whole")
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("vocab.json"), encoding: .utf8), "{\"schema\": 1}")
        XCTAssertTrue(fm.fileExists(atPath: data.appendingPathComponent("profiles/acme.json").path), "projects are untouched")
        XCTAssertTrue(fm.fileExists(atPath: data.appendingPathComponent(".venv/marker").path), "the environment is untouched")
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent(".engine-version"), encoding: .utf8), "v1")
        let leftovers = try fm.contentsOfDirectory(atPath: data.path).filter { $0.hasSuffix(".sync-tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testObsoleteScriptsRemovedWithoutBundledScriptsDir() throws {
        try makeBundle()
        try write("old", data.appendingPathComponent("scripts/voiceid.py"))
        try write("old", data.appendingPathComponent("scripts/langid.py"))
        try write("mine", data.appendingPathComponent("scripts/custom.py"))
        XCTAssertTrue(EngineSync.sync(from: bundle, to: data, version: "v1"))
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: data.appendingPathComponent("scripts/voiceid.py").path))
        XCTAssertFalse(fm.fileExists(atPath: data.appendingPathComponent("scripts/langid.py").path))
        XCTAssertTrue(fm.fileExists(atPath: data.appendingPathComponent("scripts/custom.py").path), "what is not ours is left alone")
    }

    func testVocabNotOverwrittenAndSameVersionSkipped() throws {
        try makeBundle()
        try write("mine", data.appendingPathComponent("vocab.json"))
        XCTAssertTrue(EngineSync.sync(from: bundle, to: data, version: "v1"))
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("vocab.json"), encoding: .utf8), "mine")
        try write("changed", bundle.appendingPathComponent("server.py"))
        XCTAssertTrue(EngineSync.sync(from: bundle, to: data, version: "v1"))
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("server.py"), encoding: .utf8), "server",
                       "same version: no copy")
        XCTAssertTrue(EngineSync.sync(from: bundle, to: data, version: "v2"))
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("server.py"), encoding: .utf8), "changed")
    }

    func testStampOnlyOnFullSuccess() throws {
        try makeBundle()
        let locked = bundle.appendingPathComponent("models.json")
        try write("{}", locked)
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o644) }
        XCTAssertFalse(EngineSync.sync(from: bundle, to: data, version: "v1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent(".engine-version").path),
                       "failure: no stamp, retried next time")
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("server.py").path), "the rest is copied")
    }
}

final class RunResultTests: XCTestCase {
    func testParseLine() {
        XCTAssertEqual(RunOutcome.parseLine("RESULT: ok"), .init(ok: true, code: 0, message: ""))
        XCTAssertEqual(RunOutcome.parseLine("RESULT: error 4 модель turbo не скачана"),
                       .init(ok: false, code: 4, message: "модель turbo не скачана"))
        XCTAssertEqual(RunOutcome.parseLine("RESULT: error 2"), .init(ok: false, code: 2, message: ""))
        XCTAssertEqual(RunOutcome.parseLine("RESULT: error что-то"), .init(ok: false, code: nil, message: "что-то"))
        XCTAssertNil(RunOutcome.parseLine("STATUS: ok"))
        XCTAssertNil(RunOutcome.parseLine("RESULT: maybe"))
    }

    func testExitCodes() {
        XCTAssertEqual(RunOutcome.parse(exitCode: 0, lines: ["…", "RESULT: ok"]), .ok)
        XCTAssertEqual(RunOutcome.parse(exitCode: 2, lines: ["RESULT: error 2 нет звука"]), .noAudio("нет звука"))
        XCTAssertEqual(RunOutcome.parse(exitCode: 3, lines: ["RESULT: error 3 нет torch"]), .engineBroken("нет torch"))
        XCTAssertEqual(RunOutcome.parse(exitCode: 4, lines: ["RESULT: error 4 нет модели"]), .modelMissing("нет модели"))
        XCTAssertEqual(RunOutcome.parse(exitCode: 5, lines: ["RESULT: error 5 битый файл", ""]), .damaged("битый файл"))
        XCTAssertEqual(RunOutcome.parse(exitCode: 1, lines: ["Traceback", "ValueError: x"]),
                       .failed(code: 1, message: "ValueError: x"), "no RESULT: the last line")
        XCTAssertEqual(RunOutcome.parse(exitCode: 143, lines: []), .failed(code: 143, message: ""), "killed by a signal")
        XCTAssertEqual(RunOutcome.parse(exitCode: -1, lines: ["Не удалось запустить: x"]),
                       .failed(code: -1, message: "Не удалось запустить: x"))
    }

    func testResultRefinesGenericCode() {
        XCTAssertEqual(RunOutcome.parse(exitCode: 1, lines: ["RESULT: error 4 нет модели"]), .modelMissing("нет модели"))
        XCTAssertEqual(RunOutcome.parse(exitCode: 0, lines: ["RESULT: error 5 битый"]), .damaged("битый"))
        XCTAssertEqual(RunOutcome.parse(exitCode: 0, lines: ["RESULT: error что-то"]), .failed(code: 1, message: "что-то"))
        XCTAssertEqual(RunOutcome.parse(exitCode: 2, lines: ["RESULT: error 4 x"]), .noAudio("x"), "the exit code wins")
    }
}

final class SetupFlowTests: XCTestCase {
    func testOnlyAReadyEngineCountsAsInstalled() {
        XCTAssertTrue(SetupFlow.installed(.ready))
        XCTAssertFalse(SetupFlow.installed(.needsUpdate),
                       "a stopped first install leaves a venv without a model and without .venv-lock: not installed")
        XCTAssertFalse(SetupFlow.installed(.modelMissing(.gigaam)))
        XCTAssertFalse(SetupFlow.installed(.notInstalled))
    }

    func testResumeStep() {
        let model = SetupFlow.modelStep
        XCTAssertEqual(SetupFlow.resume(saved: nil, engine: .notInstalled), 0, "never opened: from the start")
        XCTAssertEqual(SetupFlow.resume(saved: 2, engine: .notInstalled), 2, "before the model step: the same step")
        XCTAssertEqual(SetupFlow.resume(saved: model + 2, engine: .ready), model + 2, "engine ready: the same step")
        XCTAssertEqual(SetupFlow.resume(saved: model + 1, engine: .needsUpdate), model,
                       "closed during the download: back to the model choice, the download continues from there")
        XCTAssertEqual(SetupFlow.resume(saved: model + 2, engine: .modelMissing(.turbo)), model)
    }
}

final class RuModelTests: TempDirTestCase {
    func testRuModelOnlyAfterWhisper() {
        XCTAssertEqual(WhisperModel.ruModel(main: .turbo, ru: .gigaam), .gigaam)
        XCTAssertNil(WhisperModel.ruModel(main: .gigaam, ru: .gigaam))
        XCTAssertNil(WhisperModel.ruModel(main: .parakeet, ru: .gigaam), "onnx can't tell languages apart")
        XCTAssertNil(WhisperModel.ruModel(main: .turbo, ru: .large))
        XCTAssertNil(WhisperModel.ruModel(main: .turbo, ru: nil))
    }

    func testAutoModelForACall() {
        XCTAssertEqual(WhisperModel.auto(languages: [.ru], main: .turbo, ru: .gigaam), .gigaam)
        XCTAssertEqual(WhisperModel.auto(languages: [.en], main: .turbo, ru: .gigaam), .turbo)
        XCTAssertNil(WhisperModel.auto(languages: [.ru, .en], main: .turbo, ru: .gigaam), "by the language of each track")
        XCTAssertNil(WhisperModel.auto(languages: [], main: .turbo, ru: .gigaam))
        XCTAssertEqual(WhisperModel.auto(languages: [.ru], main: .turbo, ru: nil), .turbo)
    }

    func testBothModelsMustBeDownloaded() throws {
        let py = data.appendingPathComponent(".venv/bin/python3")
        try write("#!/bin/sh\n", py)
        chmod(py.path, 0o755)
        try write("", data.appendingPathComponent("models/\(WhisperModel.turbo.dir)/.complete"))
        XCTAssertEqual(EngineState.evaluate(data: data, model: .turbo, isDevEngine: false, ruModel: .gigaam), .modelMissing(.gigaam))
        try write("", data.appendingPathComponent("models/\(WhisperModel.gigaam.dir)/.complete"))
        try write("", data.appendingPathComponent("models/silero-vad-onnx/.complete"))
        XCTAssertEqual(EngineState.evaluate(data: data, model: .turbo, isDevEngine: false, ruModel: .gigaam), .ready)
    }

    func testSettingsKeepTheRuModel() {
        var s = SettingsValues()
        s.modelRu = .gigaam
        XCTAssertTrue(s.pairs.contains { $0 == (SettingsValues.Key.modelRu, "gigaam") })
        s.modelRu = nil
        XCTAssertFalse(s.pairs.contains { $0.0 == SettingsValues.Key.modelRu })
    }
}
