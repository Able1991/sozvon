import Foundation
import XCTest
@testable import SozvonCore

final class CallDirNameTests: TempDirTestCase {
    func testWithoutInfo() {
        XCTAssertEqual(callDirName("2026-11-04 15-01", CallInfo(), projectTitle: nil), "2026-11-04 15-01")
    }

    func testFullName() {
        Project(slug: "acme", title: "Acme / Holding").save()
        let named = callDirName("2026-11-04 15-01", CallInfo(profile: "acme", names: "Анна, Иван", topic: "запуск: этап 1/2"),
                                projects: Project.all())
        XCTAssertEqual(named, "2026-11-04 15-01 · Acme · запуск- этап 1-2 · Анна, Иван")
        let renamed = callDirName(named, CallInfo(profile: "", names: "Олег", topic: ""), projects: Project.all())
        XCTAssertEqual(renamed, "2026-11-04 15-01 · Олег", "переименование берёт только дату")
    }

    func testLengthLimited() {
        XCTAssertEqual(callDirName("2026-11-04 15-01", CallInfo(topic: String(repeating: "x", count: 300)), projectTitle: nil).count, 120)
    }

    func testEdgeCases() {
        XCTAssertEqual(callDirName("short", CallInfo(topic: "t"), projectTitle: nil), "short · t", "имя короче id")
        XCTAssertEqual(callDirName("2026-11-04 15-01", CallInfo(topic: "a\nb\tc"), projectTitle: nil),
                       "2026-11-04 15-01 · a b c", "переводы строк и табуляция")
        XCTAssertEqual(callDirName("2026-11-04 15-01", CallInfo(topic: "a\\b"), projectTitle: nil),
                       "2026-11-04 15-01 · a-b", "обратная косая")
        XCTAssertEqual(callDirName("2026-11-04 15-01", CallInfo(names: " ,  , "), projectTitle: "  "),
                       "2026-11-04 15-01", "пустые имена и проект")
        XCTAssertEqual(callDirName("2026-11-04 15-01", CallInfo(names: "Анна,Иван ,"), projectTitle: nil),
                       "2026-11-04 15-01 · Анна, Иван", "имена нормализуются")
        XCTAssertEqual(callDirName("2026-11-04 15-01", CallInfo(profile: "gone"), projects: []), "2026-11-04 15-01",
                       "удалённый проект не попадает в имя")
        // Обрезка не оставляет висящий разделитель.
        let cut = callDirName("2026-11-04 15-01", CallInfo(names: "Анна", topic: String(repeating: "x", count: 101)),
                              projectTitle: nil)
        XCTAssertFalse(cut.hasSuffix(" ") || cut.hasSuffix("·"), cut)
        XCTAssertLessThanOrEqual(cut.count, 120)
    }
}

final class CallFileTests: TempDirTestCase {
    func testRecordStoppedThenInfoKeepsEngineFields() throws {
        let dir = calls.appendingPathComponent("2026-11-04 15-01")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = AudioTimes(micStart: 10, systemStart: 9.5, micSeconds: 60, systemSeconds: 61)
        XCTAssertTrue(CallFile.recordStopped(dir, startedAt: Date(timeIntervalSince1970: 0), audio: audio))
        var c = CallFile.read(dir)
        XCTAssertEqual(c["schema"] as? Int, 1)
        XCTAssertEqual(c["id"] as? String, "2026-11-04 15-01")
        XCTAssertEqual(c["status"] as? String, "recorded")
        XCTAssertEqual(c["created_at"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(AudioTimes((c["audio"] as? [String: Any]) ?? [:]), audio)

        CallFile.update(dir) { $0["engine"] = ["version": "abc", "model": "turbo"] }
        CallFile.writeInfo(dir, CallInfo(profile: "acme", names: "Анна, Иван", topic: " запуск ", terms: "HPA",
                                         summary: false, languages: [.ru, .en]))
        c = CallFile.read(dir)
        XCTAssertEqual(c["profile"] as? String, "acme")
        XCTAssertEqual(c["names"] as? [String], ["Анна", "Иван"])
        XCTAssertEqual(c["topic"] as? String, "запуск")
        XCTAssertEqual(c["terms"] as? String, "HPA")
        XCTAssertEqual(c["languages"] as? String, "ru,en")
        XCTAssertEqual(c["summary"] as? Bool, false)
        XCTAssertEqual((c["engine"] as? [String: String])?["version"], "abc", "поля движка сохранились")
        XCTAssertEqual(c["status"] as? String, "recorded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".call.json.tmp").path))

        let info = CallFile.info(c)
        XCTAssertEqual(info, CallInfo(profile: "acme", names: "Анна, Иван", topic: "запуск", terms: "HPA",
                                      summary: false, languages: [.ru, .en]))
    }

    func testWriteInfoOnLegacyCallAddsID() {
        let dir = calls.appendingPathComponent("2026-01-02 03-04 · old")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CallFile.writeInfo(dir, CallInfo())
        XCTAssertEqual(CallFile.read(dir)["id"] as? String, "2026-01-02 03-04")
    }
}

final class CallModelTests: TempDirTestCase {
    func testParseID() {
        let d = Call.parseID("2026-11-04 15-01 · что угодно")
        let c = d.map { Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
        XCTAssertEqual(c?.year, 2026)
        XCTAssertEqual(c?.month, 11)
        XCTAssertEqual(c?.hour, 15)
        XCTAssertEqual(c?.minute, 1)
        XCTAssertNil(Call.parseID("2026-13-04 15-01"))
        XCTAssertNil(Call.parseID("not a date at all"))
        XCTAssertNil(Call.parseID("2026-11-04"))
    }

    func testLoadedOnlyFromCallJSON() throws {
        // Имя папки нарочно врёт: всё должно прийти из call.json.
        let dir = calls.appendingPathComponent("2026-11-04 15-01 · Чужой · неправда · Кто-то")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(#"""
        {"schema": 1, "id": "2026-11-04 15-01", "status": "done", "profile": "acme", "names": ["Анна"],
         "topic": "запуск", "terms": "", "languages": "ru,en", "summary": true,
         "audio": {"mic_start": 1, "mic_seconds": 120.5, "system_start": 1, "system_seconds": 90}}
        """#, dir.appendingPathComponent("call.json"))
        try write("x", dir.appendingPathComponent("transcript.md"))
        let c = try XCTUnwrap(Call.load(dir, projects: ["acme": "Acme"], withSize: true))
        XCTAssertFalse(c.isLegacy)
        XCTAssertEqual(c.callID, "2026-11-04 15-01")
        XCTAssertEqual(c.title, "запуск")
        XCTAssertEqual(c.project, "Acme")
        XCTAssertEqual(c.people, "Анна")
        XCTAssertEqual(c.languages, [.ru, .en])
        XCTAssertEqual(c.duration, 120.5)
        XCTAssertEqual(c.status, .done)
        XCTAssertEqual(c.info.profile, "acme")
        XCTAssertTrue(c.hasTranscript)
        XCTAssertFalse(c.hasSummary)
        XCTAssertFalse(c.hasAudio)
        XCTAssertNotNil(c.date)
        XCTAssertGreaterThan(c.bytes, 0)
        XCTAssertEqual(Call.load(dir)?.bytes, 0, "без withSize папка не обходится")
    }

    func testUnknownProjectShowsSlugAndTitleFallsBack() throws {
        let dir = calls.appendingPathComponent("2026-11-04 15-01")
        try write(#"{"schema": 1, "id": "2026-11-04 15-01", "profile": "gone"}"#, dir.appendingPathComponent("call.json"))
        let c = try XCTUnwrap(Call.load(dir))
        XCTAssertEqual(c.project, "gone")
        XCTAssertEqual(c.title, "gone")
        try write(#"{"schema": 1, "id": "2026-11-04 15-01"}"#, dir.appendingPathComponent("call.json"))
        XCTAssertEqual(Call.load(dir)?.title, "Звонок")
    }

    func testLegacyFolderNameFallback() throws {
        let dir = calls.appendingPathComponent("2026-11-03 10-00 · Acme · запуск · Анна, Иван")
        try write(#"{"mic_seconds": 30, "system_seconds": 45}"#, dir.appendingPathComponent("meta.json"))
        let c = try XCTUnwrap(Call.load(dir))
        XCTAssertTrue(c.isLegacy)
        XCTAssertEqual(c.project, "Acme")
        XCTAssertEqual(c.topic, "запуск")
        XCTAssertEqual(c.people, "Анна, Иван")
        XCTAssertEqual(c.duration, 45)
    }

    func testForeignFoldersSkippedAndSorted() throws {
        try FileManager.default.createDirectory(at: calls.appendingPathComponent("Разное"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: calls.appendingPathComponent("2026-11-01 09-00"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: calls.appendingPathComponent("2026-11-02 09-00"), withIntermediateDirectories: true)
        let all = Call.all()
        XCTAssertEqual(all.map(\.callID), ["2026-11-02 09-00", "2026-11-01 09-00"])
    }

    func testClock() {
        XCTAssertEqual(Call.clock(0), "")
        XCTAssertEqual(Call.clock(0, empty: "0:00"), "0:00")
        XCTAssertEqual(Call.clock(754), "12:34")
        XCTAssertEqual(Call.clock(3723), "1:02:03")
    }
}

final class CallFolderTests: TempDirTestCase {
    private var minute: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 15, minute: 1, second: 7))!
    }

    func testIDFromName() {
        XCTAssertEqual(CallFolder.id(fromName: "2026-11-04 15-01"), "2026-11-04 15-01")
        XCTAssertEqual(CallFolder.id(fromName: "2026-11-04 15-01 · Acme · -2"), "2026-11-04 15-01")
        XCTAssertEqual(CallFolder.id(fromName: "2026-11-04 15-01-2"), "2026-11-04 15-01-2")
        XCTAssertEqual(CallFolder.id(fromName: "2026-11-04 15-01-12 · Acme"), "2026-11-04 15-01-12")
        XCTAssertEqual(CallFolder.id(fromName: "2026-11-04 15-01-x"), "2026-11-04 15-01", "не число: прежние 16 символов")
        XCTAssertEqual(CallFolder.id(fromName: "Разное"), "Разное")
    }

    func testSameMinuteGetsNewFolderAndKeepsOld() throws {
        let first = try CallFolder.create(in: calls, at: minute)
        XCTAssertEqual(first.lastPathComponent, "2026-11-04 15-01")
        XCTAssertEqual(CallFile.read(first)["id"] as? String, "2026-11-04 15-01")
        try write("audio", first.appendingPathComponent("mic.m4a"))

        let second = try CallFolder.create(in: calls, at: minute)
        XCTAssertEqual(second.lastPathComponent, "2026-11-04 15-01-2")
        XCTAssertEqual(CallFile.read(second)["id"] as? String, "2026-11-04 15-01-2")
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("mic.m4a"), encoding: .utf8), "audio")

        // Первая уже переименована после расшифровки: её id всё равно занят.
        try FileManager.default.moveItem(at: first, to: calls.appendingPathComponent("2026-11-04 15-01 · Acme"))
        let third = try CallFolder.create(in: calls, at: minute)
        XCTAssertEqual(third.lastPathComponent, "2026-11-04 15-01-3")

        // Остановка и ответы не меняют выданный id, переименование его сохраняет.
        CallFile.recordStopped(second, startedAt: minute, audio: AudioTimes())
        CallFile.writeInfo(second, CallInfo(topic: "запуск"))
        XCTAssertEqual(CallFile.read(second)["id"] as? String, "2026-11-04 15-01-2")
        XCTAssertEqual(callDirName(second.lastPathComponent, CallInfo(topic: "запуск"), projectTitle: nil),
                       "2026-11-04 15-01-2 · запуск")
        XCTAssertEqual(Call.load(second)?.callID, "2026-11-04 15-01-2")
        XCTAssertEqual(Call.all().map(\.callID), ["2026-11-04 15-01-3", "2026-11-04 15-01-2", "2026-11-04 15-01"])
    }

    func testDiscardRemovesOnlyUnusedFolder() throws {
        let dir = try CallFolder.create(in: calls, at: minute)
        try write("audio", dir.appendingPathComponent("system.m4a"))
        XCTAssertFalse(CallFolder.discardIfUnused(dir), "с дорожкой не удаляется")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.m4a").path))

        let empty = try CallFolder.create(in: calls, at: minute)
        XCTAssertTrue(CallFolder.discardIfUnused(empty))
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
    }

    func testStaleProcessingMarkedFailed() throws {
        let a = calls.appendingPathComponent("2026-11-04 15-01")
        let b = calls.appendingPathComponent("2026-11-04 16-01")
        try write(#"{"schema": 1, "id": "2026-11-04 15-01", "status": "processing"}"#, a.appendingPathComponent("call.json"))
        try write(#"{"schema": 1, "id": "2026-11-04 16-01", "status": "done"}"#, b.appendingPathComponent("call.json"))
        XCTAssertEqual(CallFile.failStaleProcessing(in: calls), 1)
        XCTAssertEqual(CallFile.read(a)["status"] as? String, "failed")
        XCTAssertEqual(CallFile.read(b)["status"] as? String, "done")
    }
}

final class CallCacheTests: TempDirTestCase {
    func testTextCacheRereadsOnlyChangedFile() throws {
        let f = calls.appendingPathComponent("a/summary.md")
        try write("Привет ACME", f)
        let cache = CallTextCache()
        XCTAssertEqual(cache.text(f), "привет acme")
        XCTAssertEqual(cache.matching("acme", in: [(id: "a", urls: [f]), (id: "b", urls: [calls.appendingPathComponent("none")])]), ["a"])
        try write("другое", f)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: f.path)
        XCTAssertEqual(cache.text(f), "другое", "новый mtime: перечитали")
        try FileManager.default.removeItem(at: f)
        XCTAssertNil(cache.text(f))
    }

    func testFolderSizeCachedByFolderMtime() throws {
        let dir = calls.appendingPathComponent("2026-11-04 15-01")
        try write("12345", dir.appendingPathComponent("mic.m4a"))
        let cache = FolderSizeCache()
        XCTAssertEqual(cache.size(dir), 5)
        try write("1234567890", dir.appendingPathComponent("system.m4a"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: dir.path)
        XCTAssertEqual(cache.size(dir), 15)
    }
}
