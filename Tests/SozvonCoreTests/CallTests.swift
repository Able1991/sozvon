import Foundation
import XCTest
@testable import SozvonCore

final class CallDirNameTests: TempDirTestCase {
    func testWithoutInfo() {
        XCTAssertEqual(callDirName("2026-11-04 15-01", CallInfo(), projectTitle: nil), "2026-11-04 15-01")
    }

    func testFullName() throws {
        try Project(slug: "acme", title: "Acme / Holding").save()
        let named = callDirName("2026-11-04 15-01", CallInfo(profile: "acme", names: "Анна, Иван", topic: "запуск: этап 1/2"),
                                projects: Project.all())
        XCTAssertEqual(named, "2026-11-04 15-01 · Acme · запуск- этап 1-2 · Анна, Иван")
        let renamed = callDirName(named, CallInfo(profile: "", names: "Олег", topic: ""), projects: Project.all())
        XCTAssertEqual(renamed, "2026-11-04 15-01 · Олег", "a rename keeps only the date")
    }

    func testLengthLimited() {
        XCTAssertEqual(callDirName("2026-11-04 15-01", CallInfo(topic: String(repeating: "x", count: 300)), projectTitle: nil).count, 120)
    }

    func testEdgeCases() {
        XCTAssertEqual(callDirName("short", CallInfo(topic: "t"), projectTitle: nil), "short · t", "the name is shorter than the id")
        XCTAssertEqual(callDirName("2026-11-04 15-01", CallInfo(topic: "a\nb\tc"), projectTitle: nil),
                       "2026-11-04 15-01 · a b c", "line breaks and tabs")
        XCTAssertEqual(callDirName("2026-11-04 15-01", CallInfo(topic: "a\\b"), projectTitle: nil),
                       "2026-11-04 15-01 · a-b", "backslash")
        XCTAssertEqual(callDirName("2026-11-04 15-01", CallInfo(names: " ,  , "), projectTitle: "  "),
                       "2026-11-04 15-01", "empty names and project")
        XCTAssertEqual(callDirName("2026-11-04 15-01", CallInfo(names: "Анна,Иван ,"), projectTitle: nil),
                       "2026-11-04 15-01 · Анна, Иван", "names are normalized")
        XCTAssertEqual(callDirName("2026-11-04 15-01", CallInfo(profile: "gone"), projects: []), "2026-11-04 15-01",
                       "a deleted project does not get into the name")
        // Truncation doesn't leave a dangling separator.
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
        XCTAssertEqual((c["engine"] as? [String: String])?["version"], "abc", "the engine's fields are kept")
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
        // The folder name deliberately lies: everything must come from call.json.
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
        XCTAssertEqual(Call.load(dir)?.bytes, 0, "without withSize the folder is not walked")
    }

    func testProjectFromAnotherMacShowsTheServerTitle() throws {
        let dir = calls.appendingPathComponent("2026-11-04 15-01")
        try write(#"{"schema": 1, "id": "2026-11-04 15-01", "profile": "velorent", "project_title": "Velo Rent"}"#,
                  dir.appendingPathComponent("call.json"))
        XCTAssertEqual(Call.load(dir)?.project, "Velo Rent")
        XCTAssertEqual(Call.load(dir, projects: ["velorent": "Velo"])?.project, "Velo", "this Mac's own title wins")
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
        XCTAssertEqual(CallFolder.id(fromName: "2026-11-04 15-01-x"), "2026-11-04 15-01", "not a number: the first 16 characters as before")
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

        // The first one was already renamed after transcription: its id is still taken.
        try FileManager.default.moveItem(at: first, to: calls.appendingPathComponent("2026-11-04 15-01 · Acme"))
        let third = try CallFolder.create(in: calls, at: minute)
        XCTAssertEqual(third.lastPathComponent, "2026-11-04 15-01-3")

        // Stopping and answering don't change the assigned id, and renaming preserves it.
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
        XCTAssertFalse(CallFolder.discardIfUnused(dir), "not deleted when it has a track")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.m4a").path))

        let empty = try CallFolder.create(in: calls, at: minute)
        XCTAssertTrue(CallFolder.discardIfUnused(empty))
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
    }

    private func call(_ name: String, _ fields: [String: Any]) throws -> URL {
        let dir = calls.appendingPathComponent(name)
        var c = fields
        c["schema"] = 1
        c["id"] = name
        let data = try JSONSerialization.data(withJSONObject: c)
        try write(String(decoding: data, as: UTF8.self), dir.appendingPathComponent("call.json"))
        return dir
    }

    func testInterruptedRunIsRequeuedOnce() throws {
        let a = try call("2026-11-04 15-01", ["status": "processing"])
        let done = try call("2026-11-04 16-01", ["status": "done"])
        let jobs = CallFile.recoverQueue(in: calls)
        XCTAssertEqual(jobs, [ProcessingQueue.Job(dir: a, kind: .transcribe)])
        let c = CallFile.read(a)
        XCTAssertEqual(c["retries"] as? Int, 1)
        XCTAssertEqual(c["status"] as? String, "recorded", "not shown as still running while it waits")
        XCTAssertNotNil(c["queued_at"])
        XCTAssertEqual(CallFile.read(done)["status"] as? String, "done")
        XCTAssertNil(CallFile.read(done)["queued_at"], "a finished call is left alone")
    }

    func testInterruptedAgainIsFailedSoACrashCannotLoop() throws {
        let a = try call("2026-11-04 15-01", ["status": "processing", "retries": 1])
        XCTAssertEqual(CallFile.recoverQueue(in: calls), [])
        let c = CallFile.read(a)
        XCTAssertEqual(c["status"] as? String, "failed")
        XCTAssertNil(c["queued_at"])
    }

    func testWaitingCallsComeBackInTheirOrder() throws {
        let late = try call("2026-11-04 15-01", ["status": "recorded", "queued_at": "2026-11-05T10:00:03Z"])
        let first = try call("2026-11-04 16-01", ["status": "done", "queued_at": "2026-11-05T10:00:01.250Z"])
        let second = try call("2026-11-04 17-01", ["status": "failed", "queued_at": "2026-11-05T10:00:01.750Z",
                                                   "queued_summary_only": true])
        XCTAssertEqual(CallFile.recoverQueue(in: calls), [
            ProcessingQueue.Job(dir: first, kind: .transcribe),
            ProcessingQueue.Job(dir: second, kind: .summaryOnly),
            ProcessingQueue.Job(dir: late, kind: .transcribe),
        ])
        XCTAssertEqual(CallFile.read(first)["status"] as? String, "done", "a waiting call keeps its status")
        XCTAssertNil(CallFile.read(first)["retries"], "waiting is not a retry")
    }

    func testInterruptedRunGoesBeforeTheWaitingOnes() throws {
        let waiting = try call("2026-11-04 15-01", ["status": "recorded", "queued_at": "2026-11-05T10:00:00Z"])
        let interrupted = try call("2026-11-04 16-01", ["status": "processing"])
        XCTAssertEqual(CallFile.recoverQueue(in: calls), [ProcessingQueue.Job(dir: interrupted, kind: .transcribe),
                                                          ProcessingQueue.Job(dir: waiting, kind: .transcribe)], "it was already running")
    }

    func testBrokenQueuedAtIsIgnored() throws {
        _ = try call("2026-11-04 15-01", ["status": "recorded", "queued_at": "вчера"])
        _ = try call("2026-11-04 16-01", ["status": "recorded", "queued_at": 5])
        XCTAssertEqual(CallFile.recoverQueue(in: calls), [])
    }

    func testQueuedFieldsAreWrittenAndRemoved() throws {
        let a = try call("2026-11-04 15-01", ["status": "done", "retries": 1])
        let at = Date(timeIntervalSince1970: 1_800_000_000.5)
        XCTAssertTrue(CallFile.setQueued(a, at: at, summaryOnly: true))
        XCTAssertEqual(CallFile.queuedAt(CallFile.read(a)), at)
        XCTAssertEqual(CallFile.read(a)["queued_summary_only"] as? Bool, true)
        XCTAssertTrue(CallFile.setQueued(a, at: nil))
        XCTAssertNil(CallFile.read(a)["queued_at"])
        XCTAssertNil(CallFile.read(a)["queued_summary_only"])
        XCTAssertTrue(CallFile.clearRetries(a))
        XCTAssertNil(CallFile.read(a)["retries"])
        XCTAssertEqual(CallFile.read(a)["status"] as? String, "done")
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
        XCTAssertEqual(cache.text(f), "другое", "new mtime: read again")
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

    func testManyPeopleAreShortened() {
        XCTAssertEqual(shortPeople(["Анна"]), "Анна")
        XCTAssertEqual(shortPeople(["Анна", "Олег", "Иван"]), "Анна, Олег, Иван")
        XCTAssertEqual(shortPeople(["Анна", "Олег", "Иван", "Мария", "Пётр", "Ли"]), "Анна, Олег +4")
        let name = callDirName("2026-11-04 15-01",
                               CallInfo(names: "Анна, Олег, Иван, Мария, Пётр, Ли", topic: "планёрка"), projectTitle: "Acme")
        XCTAssertEqual(name, "2026-11-04 15-01 · Acme · планёрка · Анна, Олег, Иван +3")
    }
}

@MainActor
final class CallNotesTests: TempDirTestCase {
    private func callDir(_ extra: [String: Any] = [:]) throws -> URL {
        let d = calls.appendingPathComponent("2026-11-04 15-01 · Acme")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var c: [String: Any] = ["schema": 1, "id": "2026-11-04 15-01", "status": "done", "topic": "запуск",
                                "engine": ["version": "x"]]
        c.merge(extra) { _, b in b }
        try JSONSerialization.data(withJSONObject: c).write(to: d.appendingPathComponent("call.json"))
        return d
    }

    func testNotesRoundTrip() throws {
        let engineNote: [String: Any] = ["id": "0b7e0c4e-1111-4c3a-9d41-5d2f7f1a0a01", "at": "2026-11-04T12:00:00Z",
                                         "text": "Перезвонить Анне", "source": "claude-code"]
        let d = try callDir(["notes": [engineNote, ["id": "bad id", "at": "x", "text": "y", "source": "z"], "junk"]])
        XCTAssertEqual(CallNotes.read(d).map(\.text), ["Перезвонить Анне"], "invalid entries are skipped")
        let n = try CallNotes.add("  из приложения \n", to: d, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(n.text, "из приложения")
        XCTAssertEqual(n.source, "app")
        XCTAssertEqual(n.at, "2027-01-15T08:00:00Z")
        XCTAssertEqual(n.id, n.id.lowercased())
        let c = try json(d.appendingPathComponent("call.json"))
        let stored = try XCTUnwrap(c["notes"] as? [[String: String]])
        XCTAssertEqual(stored.count, 2, "the engine's note is kept, the invalid ones are dropped")
        XCTAssertEqual(stored[0], engineNote as? [String: String])
        XCTAssertEqual(stored[1], ["id": n.id, "at": n.at, "text": "из приложения", "source": "app"])
        XCTAssertEqual(c["topic"] as? String, "запуск")
        XCTAssertNotNil(c["engine"], "fields of the engine are kept")
        XCTAssertEqual(Call.load(d)?.notes.map(\.id), [engineNote["id"] as! String, n.id])
        XCTAssertNotNil(CallNotes.read(d).first?.date)
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent("call.json.lock").path),
                      "written under the engine's lock file")

        XCTAssertTrue(try CallNotes.delete(engineNote["id"] as! String, in: d))
        XCTAssertFalse(try CallNotes.delete("nope", in: d))
        let after = try json(d.appendingPathComponent("call.json"))
        XCTAssertEqual((after["notes"] as? [[String: String]])?.map { $0["id"]! }, [n.id])
        XCTAssertEqual(after["notes_deleted"] as? [String], [engineNote["id"] as! String], "a tombstone for the sync")
    }

    func testNoteLimits() throws {
        let d = try callDir()
        XCTAssertThrowsError(try CallNotes.add("   ", to: d)) { XCTAssertEqual($0 as? CallNotes.Failure, .empty) }
        XCTAssertThrowsError(try CallNotes.add(String(repeating: "я", count: 4001), to: d)) {
            XCTAssertEqual($0 as? CallNotes.Failure, .tooLong)
        }
        XCTAssertNoThrow(try CallNotes.add(String(repeating: "я", count: 4000), to: d))
        let many = (0..<199).map { ["id": "n\($0)", "at": "2026-11-04T12:00:00Z", "text": "x", "source": "app"] }
        try CallFile.edit(d) { c in
            c["notes"] = (c["notes"] as? [Any] ?? []) + many
            return true
        }
        XCTAssertThrowsError(try CallNotes.add("one more", to: d)) { XCTAssertEqual($0 as? CallNotes.Failure, .tooMany) }
    }

    func testBrokenCallJSONIsNotOverwrittenByNotes() throws {
        let d = try callDir()
        try write("{broken", d.appendingPathComponent("call.json"))
        XCTAssertThrowsError(try CallNotes.add("x", to: d)) { XCTAssertEqual($0 as? CallNotes.Failure, .corrupt) }
        XCTAssertEqual(try String(contentsOf: d.appendingPathComponent("call.json"), encoding: .utf8), "{broken")
    }

    func testEditNeverRecreatesAGoneFolder() {
        let gone = calls.appendingPathComponent("2026-11-04 16-00")
        XCTAssertFalse(CallFile.setStatus(gone, .failed))
        XCTAssertFalse(CallFile.setFailedUnlessDone(gone))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
    }

    /// A run stopped once the engine wrote `done` (a quit during the listening file): the finished call stays finished.
    func testAStoppedRunKeepsAFinishedCallDone() throws {
        let d = try callDir()
        XCTAssertTrue(CallFile.setStatus(d, .done))
        XCTAssertTrue(CallFile.setFailedUnlessDone(d))
        XCTAssertEqual(CallFile.read(d)["status"] as? String, "done")
    }

    func testAStoppedRunStillFailsAnUnfinishedCall() throws {
        let d = try callDir()
        XCTAssertTrue(CallFile.setStatus(d, .processing))
        XCTAssertTrue(CallFile.setFailedUnlessDone(d))
        XCTAssertEqual(CallFile.read(d)["status"] as? String, "failed")
    }

    func testDiscardIgnoresTheLockFile() throws {
        let d = try CallFolder.create(in: calls)
        XCTAssertTrue(CallFolder.discardIfUnused(d), "call.json and call.json.lock only: still unused")
    }

    func testServerTombstones() throws {
        let f = ServerTombstones.file
        XCTAssertEqual(f, data.appendingPathComponent("server-deleted.json"))
        XCTAssertEqual(ServerTombstones.ids(), [])
        try ServerTombstones.add("2026-11-04 15-01", at: Date(timeIntervalSince1970: 0))
        try ServerTombstones.add("2026-11-04 16-00")
        try ServerTombstones.add("2026-11-04 15-01")
        XCTAssertEqual(ServerTombstones.ids(), ["2026-11-04 15-01", "2026-11-04 16-00"])
        let o = try json(f)
        XCTAssertEqual(o["schema"] as? Int, 1)
        XCTAssertEqual((o["calls"] as? [[String: String]])?.first, ["id": "2026-11-04 15-01", "at": "1970-01-01T00:00:00Z"])
        try ServerTombstones.remove("2026-11-04 15-01")  // undo: restored from the Trash
        XCTAssertEqual(ServerTombstones.ids(), ["2026-11-04 16-00"])
        XCTAssertEqual(ServerRestores.ids(), [])
        try ServerTombstones.restored("2026-11-04 16-00", at: Date(timeIntervalSince1970: 0))  // undo with a server set up
        try ServerTombstones.restored("2026-11-04 16-00")
        XCTAssertEqual(ServerTombstones.ids(), [])
        XCTAssertEqual(ServerRestores.file, data.appendingPathComponent("server-restore.json"))
        XCTAssertEqual(ServerRestores.ids(), ["2026-11-04 16-00"])
        let r = try json(ServerRestores.file)
        XCTAssertEqual(r["schema"] as? Int, 1)
        XCTAssertEqual((r["calls"] as? [[String: String]]), [["id": "2026-11-04 16-00", "at": "1970-01-01T00:00:00Z"]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("server-restore.json.lock").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("server-deleted.json.lock").path))
        try write("{broken", f)
        XCTAssertEqual(ServerTombstones.ids(), [])
    }

    func testServerTombstonesReportWriteErrors() throws {
        // The list's folder is a regular file: neither the lock nor the list can be written.
        let blocker = tmp.appendingPathComponent("blocker")
        try write("x", blocker)
        let f = blocker.appendingPathComponent("server-deleted.json")
        XCTAssertThrowsError(try ServerTombstones.add("2026-11-04 15-01", file: f))
        XCTAssertThrowsError(try ServerTombstones.remove("2026-11-04 15-01", file: f))
        // Lock fine, the file itself not writable: a folder in its place.
        let g = data.appendingPathComponent("odd.json")
        try FileManager.default.createDirectory(at: g, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ServerTombstones.add("2026-11-04 15-01", file: g))
    }
}
