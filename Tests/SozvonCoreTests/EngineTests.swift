import Foundation
import XCTest
@testable import SozvonCore

final class EngineStateTests: TempDirTestCase {
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
                       "без venv и модели не установлен")
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
        XCTAssertEqual(EngineState.evaluate(data: data, model: .turbo, isDevEngine: true), .ready, "свой движок не обновляем")
        try write(EngineState.lockHash(Data("lock v2".utf8)) + "\n", data.appendingPathComponent(".venv-lock"))
        XCTAssertEqual(EngineState.evaluate(data: data, model: .turbo, isDevEngine: false), .ready)
    }

    func testEnvironmentFollowsContract() {
        let env = Engine.environment(base: ["HOME": "/h", "SOZVON_THREADS": "8", "WHISPER_MCP_DIR": "/old"], data: data, calls: calls, gentle: false,
                                     uiLanguage: "en", mcpToken: "t", pyannoteTar: URL(fileURLWithPath: "/b/p.tar.gz"))
        XCTAssertEqual(env["SOZVON_DATA_DIR"], data.path)
        XCTAssertNil(env["WHISPER_MCP_DIR"], "старое имя больше не передаётся")
        XCTAssertEqual(env["SOZVON_CALLS_DIR"], calls.path)
        XCTAssertEqual(env["SOZVON_UI_LANG"], "en")
        XCTAssertNil(env["SOZVON_THREADS"], "без «Не мешать работе» потоки не ограничены")
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
        XCTAssertFalse(fm.fileExists(atPath: data.appendingPathComponent("sozvon_engine/old.py").path), "папка заменена целиком")
        XCTAssertTrue(fm.fileExists(atPath: data.appendingPathComponent("server.py").path))
        XCTAssertFalse(fm.fileExists(atPath: data.appendingPathComponent("pyannote-models-v1.tar.gz").path), "архив не копируется")
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("ENGINE_VERSION"), encoding: .utf8), "abc",
                       "движок сам читает свою версию")
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("sozvon_engine/pipeline/run.py"), encoding: .utf8),
                       "deep", "вложенные папки копируются целиком")
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("vocab.json"), encoding: .utf8), "{\"schema\": 1}")
        XCTAssertTrue(fm.fileExists(atPath: data.appendingPathComponent("profiles/acme.json").path), "проекты не тронуты")
        XCTAssertTrue(fm.fileExists(atPath: data.appendingPathComponent(".venv/marker").path), "окружение не тронуто")
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
        XCTAssertTrue(fm.fileExists(atPath: data.appendingPathComponent("scripts/custom.py").path), "чужое не трогаем")
    }

    func testVocabNotOverwrittenAndSameVersionSkipped() throws {
        try makeBundle()
        try write("mine", data.appendingPathComponent("vocab.json"))
        XCTAssertTrue(EngineSync.sync(from: bundle, to: data, version: "v1"))
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("vocab.json"), encoding: .utf8), "mine")
        try write("changed", bundle.appendingPathComponent("server.py"))
        XCTAssertTrue(EngineSync.sync(from: bundle, to: data, version: "v1"))
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("server.py"), encoding: .utf8), "server",
                       "та же версия: не копируем")
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
                       "сбой: метки нет, в следующий раз повторим")
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("server.py").path), "остальное скопировано")
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
                       .failed(code: 1, message: "ValueError: x"), "без RESULT: последняя строка")
        XCTAssertEqual(RunOutcome.parse(exitCode: 143, lines: []), .failed(code: 143, message: ""), "убит сигналом")
        XCTAssertEqual(RunOutcome.parse(exitCode: -1, lines: ["Не удалось запустить: x"]),
                       .failed(code: -1, message: "Не удалось запустить: x"))
    }

    func testResultRefinesGenericCode() {
        XCTAssertEqual(RunOutcome.parse(exitCode: 1, lines: ["RESULT: error 4 нет модели"]), .modelMissing("нет модели"))
        XCTAssertEqual(RunOutcome.parse(exitCode: 0, lines: ["RESULT: error 5 битый"]), .damaged("битый"))
        XCTAssertEqual(RunOutcome.parse(exitCode: 0, lines: ["RESULT: error что-то"]), .failed(code: 1, message: "что-то"))
        XCTAssertEqual(RunOutcome.parse(exitCode: 2, lines: ["RESULT: error 4 x"]), .noAudio("x"), "код завершения главнее")
    }
}
