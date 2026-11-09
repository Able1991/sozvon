// Calls window features: transcript lines and edits, replacements, import folders, action items and due dates.

import Foundation
import XCTest
@testable import SozvonCore

final class TranscriptTests: TempDirTestCase {
    static let md = """
    # Звонок 2026-11-04 15-01 · Acme · запуск

    Длительность: 1:02:10 · Участники: Я, Собеседник 1, Анна

    ## Коротко
    Договорились.

    ---

    ## Расшифровка

    **[00:00] Я:** Привет, давай начнём.

    **[00:03] Собеседник 1:** Бюджет согласован, кубер готов.

    **[59:59] Анна:** Собеседник 1: это я.

    **[01:02:03] Собеседник 1:** Кубер, ещё раз кубер.

    """
    static let txt = """
    [00:00] Я: Привет, давай начнём.
    [00:03] Собеседник 1: Бюджет согласован, кубер готов.
    [59:59] Анна: Собеседник 1: это я.
    [01:02:03] Собеседник 1: Кубер, ещё раз кубер.

    """

    func testTimestamps() {
        XCTAssertEqual(Transcript.timestamp("05:07"), 307)
        XCTAssertEqual(Transcript.timestamp("1:02:03"), 3723)
        XCTAssertEqual(Transcript.timestamp("01:02:03"), 3723)
        XCTAssertNil(Transcript.timestamp("5:7"))
        XCTAssertNil(Transcript.timestamp("05:60"))
        XCTAssertNil(Transcript.timestamp("ab:cd"))
        XCTAssertNil(Transcript.timestamp("05"))
    }

    func testParseBothFormats() throws {
        let md = try XCTUnwrap(Transcript.parse("**[01:02:03] Собеседник 1:** Кубер, ещё раз."))
        XCTAssertEqual(md.line, TranscriptLine(start: 3723, speaker: "Собеседник 1", text: "Кубер, ещё раз."))
        XCTAssertEqual(md.prefix, "**[01:02:03] Собеседник 1:** ")
        let txt = try XCTUnwrap(Transcript.parse("[59:59] Анна: Собеседник 1: это я."))
        XCTAssertEqual(txt.line, TranscriptLine(start: 3599, speaker: "Анна", text: "Собеседник 1: это я."))
        XCTAssertNil(Transcript.parse("## Расшифровка"))
        XCTAssertNil(Transcript.parse("[note] text"))
        XCTAssertEqual(Transcript.lines(Self.md).count, 4)
        XCTAssertEqual(Transcript.lines(Self.md), Transcript.lines(Self.txt))
    }

    func testLineAtTime() {
        let starts: [TimeInterval] = [0, 3, 3599, 3723]
        XCTAssertNil(Transcript.lineIndex(at: 0, starts: [5]))
        XCTAssertEqual(Transcript.lineIndex(at: 0, starts: starts), 0)
        XCTAssertEqual(Transcript.lineIndex(at: 2.9, starts: starts), 0)
        XCTAssertEqual(Transcript.lineIndex(at: 3, starts: starts), 1)
        XCTAssertEqual(Transcript.lineIndex(at: 3700, starts: starts), 2)
        XCTAssertEqual(Transcript.lineIndex(at: 99999, starts: starts), 3)
        XCTAssertNil(Transcript.lineIndex(at: 1, starts: []))
    }

    func testOffsets() {
        let o = TrackOffsets(AudioTimes(micStart: 10.5, systemStart: 10.0))
        XCTAssertEqual(o.mic, 0.5, accuracy: 1e-9)
        XCTAssertEqual(o.system, 0)
        XCTAssertEqual(TrackOffsets(AudioTimes(systemStart: 0, systemSeconds: 60)), TrackOffsets(AudioTimes()))
    }

    func testRenameSpeakerBothFormats() {
        let md = Transcript.renameSpeaker(Self.md, from: "Собеседник 1", to: "Иван")
        XCTAssertTrue(md.contains("Участники: Я, Иван, Анна"))
        XCTAssertTrue(md.contains("**[00:03] Иван:** Бюджет согласован"))
        XCTAssertTrue(md.contains("**[01:02:03] Иван:** Кубер"))
        XCTAssertTrue(md.contains("**[59:59] Анна:** Собеседник 1: это я."), "text is not a label")
        let txt = Transcript.renameSpeaker(Self.txt, from: "Собеседник 1", to: "Иван")
        XCTAssertEqual(txt, Self.txt.replacingOccurrences(of: "] Собеседник 1:", with: "] Иван:"))
        // Merging into an existing name doesn't duplicate it in the header.
        XCTAssertTrue(Transcript.renameSpeaker(Self.md, from: "Анна", to: "Я").contains("Участники: Я, Собеседник 1\n"))
    }

    func testFixWordOnlyInThatLine() throws {
        let line = TranscriptLine(start: 3, speaker: "Собеседник 1", text: "Бюджет согласован, кубер готов.")
        let md = try XCTUnwrap(Transcript.fix(Self.md, line: line, wrong: "кубер", right: "Kubernetes"))
        XCTAssertTrue(md.contains("**[00:03] Собеседник 1:** Бюджет согласован, Kubernetes готов."))
        XCTAssertTrue(md.contains("**[01:02:03] Собеседник 1:** Кубер, ещё раз кубер."))
        XCTAssertNil(Transcript.fix(Self.md, line: line, wrong: "нет такого", right: "x"))
        XCTAssertNil(Transcript.fix(Self.md, line: TranscriptLine(start: 9, speaker: "X", text: "y"), wrong: "y", right: "z"))
    }

    func testFixWordWholeWordsOnly() throws {
        let text = "[00:01] Анна: кот, который котик. Кот-кот кот_1 кот"
        let line = try XCTUnwrap(Transcript.parse(text)?.line)
        XCTAssertEqual(Transcript.fix(text, line: line, wrong: "кот", right: "пёс"),
                       "[00:01] Анна: пёс, который котик. Кот-пёс кот_1 пёс", "not inside other words, \"_\" is a word character")
        XCTAssertNil(Transcript.fix("[00:01] Анна: который", line: TranscriptLine(start: 1, speaker: "Анна", text: "который"),
                                    wrong: "кот", right: "пёс"))
        XCTAssertTrue(Transcript.containsWord("версия 2.0 готова", "2.0"))
        XCTAssertFalse(Transcript.containsWord("версия 12.0", "2.0"))
        XCTAssertEqual(Transcript.replaceWord("C++ и C", "C++", with: "$1 \\0"), "$1 \\0 и C", "a literal replacement, not a template")
        XCTAssertEqual(Transcript.replaceWord("Kubernetes кубер", "кубер", with: "Kubernetes"), "Kubernetes Kubernetes")
    }

    func testFixWordTheClickedDuplicateLine() throws {
        let text = "[00:01] Анна: да кубер\n[00:01] Анна: да кубер\n[00:05] Иван: нет"
        let line = TranscriptLine(start: 1, speaker: "Анна", text: "да кубер")
        XCTAssertEqual(Transcript.fix(text, line: line, occurrence: 1, wrong: "кубер", right: "K8s"),
                       "[00:01] Анна: да кубер\n[00:01] Анна: да K8s\n[00:05] Иван: нет")
        XCTAssertEqual(Transcript.fix(text, line: line, wrong: "кубер", right: "K8s"),
                       "[00:01] Анна: да K8s\n[00:01] Анна: да кубер\n[00:05] Иван: нет")
        XCTAssertNil(Transcript.fix(text, line: line, occurrence: 2, wrong: "кубер", right: "K8s"))
    }

    func testSwapSpeakers() {
        let md = Transcript.swapSpeakers(Self.md, "Собеседник 1", "Анна")
        XCTAssertTrue(md.contains("Участники: Я, Анна, Собеседник 1"))
        XCTAssertTrue(md.contains("**[00:03] Анна:** Бюджет согласован"))
        XCTAssertTrue(md.contains("**[59:59] Собеседник 1:** Собеседник 1: это я."), "text is not a label")
        XCTAssertEqual(Transcript.swapSpeakers(md, "Анна", "Собеседник 1"), Self.md, "swapping back restores it")
        XCTAssertEqual(Transcript.swapSpeakers(Self.txt, "Я", "Я"), Self.txt)
    }

    func testReassignOneLine() throws {
        let line = TranscriptLine(start: 3, speaker: "Собеседник 1", text: "Бюджет согласован, кубер готов.")
        let md = try XCTUnwrap(Transcript.reassign(Self.md, line: line, to: "Иван"))
        XCTAssertTrue(md.contains("**[00:03] Иван:** Бюджет согласован, кубер готов."))
        XCTAssertTrue(md.contains("**[01:02:03] Собеседник 1:** Кубер"), "other lines keep their speaker")
        XCTAssertTrue(md.contains("Участники: Я, Иван, Анна, Собеседник 1"), "the list follows the lines")
        let txt = try XCTUnwrap(Transcript.reassign(Self.txt, line: line, to: "Иван"))
        XCTAssertTrue(txt.contains("[00:03] Иван: Бюджет"))
        let last = TranscriptLine(start: 59 * 60 + 59, speaker: "Анна", text: "Собеседник 1: это я.")
        XCTAssertTrue(try XCTUnwrap(Transcript.reassign(Self.md, line: last, to: "Я")).contains("Участники: Я, Собеседник 1\n"),
                      "a speaker with no lines left leaves the list")
        XCTAssertNil(Transcript.reassign(Self.md, line: TranscriptLine(start: 1, speaker: "X", text: "y"), to: "Z"))
    }

    func testSwapAndReassignFiles() throws {
        let dir = try makeCall()
        XCTAssertTrue(try TranscriptEdit.swapSpeakers(in: dir, "Собеседник 1", "Анна"))
        XCTAssertEqual(CallFile.read(dir)["names"] as? [String], ["Анна", "Собеседник 1"])
        let txt = try String(contentsOf: dir.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertTrue(txt.contains("[00:03] Анна: Бюджет"))
        let line = TranscriptLine(start: 3, speaker: "Анна", text: "Бюджет согласован, кубер готов.")
        XCTAssertTrue(try TranscriptEdit.reassignLine(in: dir, line: line, to: "Иван"))
        XCTAssertEqual(CallFile.read(dir)["names"] as? [String], ["Анна", "Собеседник 1"], "a line edit never changes names")
        XCTAssertTrue(try CallParticipants.update(in: dir, me: "Я"))
        XCTAssertEqual(CallFile.read(dir)["names"] as? [String], ["Анна", "Собеседник 1"], "names stay as typed")
        XCTAssertEqual(CallFile.read(dir)["participants"] as? [String], ["Иван", "Анна"])
        XCTAssertThrowsError(try TranscriptEdit.reassignLine(in: dir, line: line, to: "Иван"), "the line is no longer Анна's")
    }

    func testRenameMergeWarning() {
        let lines = Transcript.lines(Self.md)
        XCTAssertTrue(Transcript.renameMerges(lines, from: "Собеседник 1", to: " Анна "))
        XCTAssertFalse(Transcript.renameMerges(lines, from: "Собеседник 1", to: "Иван"))
        XCTAssertFalse(Transcript.renameMerges(lines, from: "Анна", to: "Анна"), "the same name is not a merge")
        XCTAssertFalse(Transcript.renameMerges(lines, from: "Анна", to: "А: Б"))
    }

    private func makeCall() throws -> URL {
        let dir = calls.appendingPathComponent("2026-11-04 15-01 · Acme")
        try write(Self.md, dir.appendingPathComponent("transcript.md"))
        try write(Self.txt, dir.appendingPathComponent("transcript.txt"))
        try write(#"{"schema": 1, "id": "2026-11-04 15-01", "names": ["Собеседник 1", "Анна"], "status": "done"}"#,
                  dir.appendingPathComponent("call.json"))
        return dir
    }

    private func tracks(_ dir: URL) -> [String: String]? { CallFile.read(dir)["speaker_tracks"] as? [String: String] }

    private func setTracks(_ dir: URL, _ t: [String: String]) throws {
        try CallFile.edit(dir) { c in c["speaker_tracks"] = t; return true }
    }

    func testRenameKeepsTheSpeakerTrack() throws {
        let dir = try makeCall()
        try setTracks(dir, ["Я": "mic", "Собеседник 1": "mic", "Анна": "system"])
        try TranscriptEdit.renameSpeaker(in: dir, from: "Собеседник 1", to: "Вера")
        XCTAssertEqual(tracks(dir), ["Я": "mic", "Вера": "mic", "Анна": "system"])
    }

    func testRenameOntoASpeakerOfTheOtherTrackIsBoth() throws {
        let dir = try makeCall()
        try write("[00:01] Собеседник 1: а\n[00:03] Анна: б\n", dir.appendingPathComponent("transcript.txt"))
        try setTracks(dir, ["Собеседник 1": "mic", "Анна": "system"])
        try TranscriptEdit.renameSpeaker(in: dir, from: "Собеседник 1", to: "Анна")
        XCTAssertEqual(tracks(dir), ["Анна": "both"])
    }

    func testRenameOfAnUnknownSpeakerStaysUnknown() throws {
        let dir = try makeCall()
        try setTracks(dir, ["Я": "mic"])
        try TranscriptEdit.renameSpeaker(in: dir, from: "Собеседник 1", to: "Вера")
        XCTAssertEqual(tracks(dir), ["Я": "mic"])
    }

    func testRenameWithoutTheFieldAddsNone() throws {
        let dir = try makeCall()
        try TranscriptEdit.renameSpeaker(in: dir, from: "Собеседник 1", to: "Вера")
        XCTAssertNil(CallFile.read(dir)["speaker_tracks"])
    }

    func testSwapSwapsTheSpeakerTracks() throws {
        let dir = try makeCall()
        try write("[00:01] Собеседник 1: а\n[00:03] Анна: б\n", dir.appendingPathComponent("transcript.txt"))
        try setTracks(dir, ["Собеседник 1": "mic", "Анна": "system"])
        try TranscriptEdit.swapSpeakers(in: dir, "Собеседник 1", "Анна")
        XCTAssertEqual(tracks(dir), ["Анна": "mic", "Собеседник 1": "system"])
    }

    func testAReassignedLineMakesTheNewSpeakerBoth() throws {
        let dir = try makeCall()
        try write("[00:01] Собеседник 1: а\n[00:03] Анна: б\n", dir.appendingPathComponent("transcript.txt"))
        try setTracks(dir, ["Собеседник 1": "mic", "Анна": "system"])
        let line = TranscriptLine(start: 1, speaker: "Собеседник 1", text: "а")
        try TranscriptEdit.reassignLine(in: dir, line: line, to: "Анна")
        XCTAssertEqual(tracks(dir), ["Собеседник 1": "mic", "Анна": "both"])
    }

    func testAReassignedLineGivesANewSpeakerItsTrack() throws {
        let dir = try makeCall()
        try write("[00:01] Собеседник 1: а\n[00:03] Анна: б\n", dir.appendingPathComponent("transcript.txt"))
        try setTracks(dir, ["Собеседник 1": "mic", "Анна": "system"])
        let line = TranscriptLine(start: 1, speaker: "Собеседник 1", text: "а")
        try TranscriptEdit.reassignLine(in: dir, line: line, to: "Вера")
        XCTAssertEqual(tracks(dir), ["Собеседник 1": "mic", "Анна": "system", "Вера": "mic"])
    }

    func testRenameSpeakerFiles() throws {
        let dir = try makeCall()
        XCTAssertTrue(try TranscriptEdit.renameSpeaker(in: dir, from: "Собеседник 1", to: " Иван "))
        let txt = try String(contentsOf: dir.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertTrue(txt.contains("[00:03] Иван: Бюджет"))
        XCTAssertFalse(txt.contains("] Собеседник 1:"))
        let md = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("**[01:02:03] Иван:**"))
        XCTAssertEqual(CallFile.read(dir)["names"] as? [String], ["Иван", "Анна"])
        XCTAssertEqual(CallFile.read(dir)["status"] as? String, "done")
        XCTAssertThrowsError(try TranscriptEdit.renameSpeaker(in: dir, from: "Иван", to: "А: Б"))
        XCTAssertThrowsError(try TranscriptEdit.renameSpeaker(in: dir, from: "Никто", to: "Б"))
    }

    func testFixWordFiles() throws {
        let dir = try makeCall()
        let line = TranscriptLine(start: 3723, speaker: "Собеседник 1", text: "Кубер, ещё раз кубер.")
        XCTAssertTrue(try TranscriptEdit.fixWord(in: dir, line: line, wrong: "кубер", right: "Kubernetes"))
        let txt = try String(contentsOf: dir.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertTrue(txt.contains("[01:02:03] Собеседник 1: Кубер, ещё раз Kubernetes."))
        XCTAssertTrue(txt.contains("кубер готов"), "other lines are untouched")
        let md = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("**[01:02:03] Собеседник 1:** Кубер, ещё раз Kubernetes."))
        XCTAssertThrowsError(try TranscriptEdit.fixWord(in: dir, line: line, wrong: "кубер", right: "x"))
    }
}

final class ReplacementStoreTests: TempDirTestCase {
    func testProjectReplacementKeepsFieldsAndOverwritesSameLeftSide() throws {
        let profiles = data.appendingPathComponent("profiles")
        let url = profiles.appendingPathComponent("acme.json")
        try write(#"{"schema": 1, "title": "Acme", "people": ["Анна"], "replacements": [["Кубер", "k8s"], ["хелм", "Helm"]]}"#, url)
        try ReplacementStore.add(wrong: "кубер", right: "Kubernetes", project: "acme", data: data, profiles: profiles)
        try ReplacementStore.add(wrong: "ПостГрес", right: "Postgres", project: "acme", data: data, profiles: profiles)
        let o = try json(url)
        XCTAssertEqual(o["title"] as? String, "Acme")
        XCTAssertEqual(o["people"] as? [String], ["Анна"])
        XCTAssertEqual(o["schema"] as? Int, 1)
        XCTAssertEqual(o["replacements"] as? [[String]], [["кубер", "Kubernetes"], ["хелм", "Helm"], ["ПостГрес", "Postgres"]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: profiles.appendingPathComponent("acme.json.lock").path))
    }

    func testMissingOrInvalidProjectIsAnError() throws {
        let profiles = data.appendingPathComponent("profiles")
        XCTAssertThrowsError(try ReplacementStore.add(wrong: "a", right: "b", project: "nope", data: data, profiles: profiles))
        XCTAssertThrowsError(try ReplacementStore.add(wrong: "a", right: "b", project: "../x", data: data, profiles: profiles))
        XCTAssertThrowsError(try ReplacementStore.add(wrong: " ", right: "b", project: "", data: data, profiles: profiles))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profiles.appendingPathComponent("nope.json").path))
    }

    func testSharedVocabulary() throws {
        let url = ReplacementStore.vocabURL(data: data)
        try ReplacementStore.add(wrong: "сазвон", right: "Sozvon", project: "", data: data)
        XCTAssertEqual(try json(url)["replacements"] as? [[String]], [["сазвон", "Sozvon"]])
        try write(#"{"schema": 1, "terms": ["MCP"], "replacements": []}"#, url)
        try ReplacementStore.add(wrong: "эм си пи", right: "MCP", project: "", data: data)
        let o = try json(url)
        XCTAssertEqual(o["terms"] as? [String], ["MCP"])
        XCTAssertEqual(o["replacements"] as? [[String]], [["эм си пи", "MCP"]])
        // A broken dictionary is left for the user, never overwritten.
        try write("{broken", url)
        XCTAssertThrowsError(try ReplacementStore.add(wrong: "a", right: "b", project: "", data: data))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{broken")
    }
}

final class CallImportTests: TempDirTestCase {
    func testFolderNamedByFileDateWithSuffix() throws {
        let file = tmp.appendingPathComponent("Meeting.MP4")
        try write("x", file)
        let date = try XCTUnwrap(Call.parseID("2026-10-01 09-30"))
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: file.path)
        XCTAssertTrue(CallImport.isSupported(file))
        XCTAssertFalse(CallImport.isSupported(tmp.appendingPathComponent("notes.txt")))
        let a = try CallImport.createFolder(for: file, in: calls)
        let b = try CallImport.createFolder(for: file, in: calls)
        XCTAssertEqual(a.lastPathComponent, "2026-10-01 09-30")
        XCTAssertEqual(b.lastPathComponent, "2026-10-01 09-30-2")
        XCTAssertEqual(CallFile.read(b)["id"] as? String, "2026-10-01 09-30-2")
    }

    func testImportFormatsAndRecordedDate() throws {
        for ext in ["m4a", "MP3", "wav", "mov", "flac"] { XCTAssertTrue(CallImport.isSupported(URL(fileURLWithPath: "/x/a.\(ext)")), ext) }
        for ext in ["webm", "ogg", "OPUS"] {
            let u = URL(fileURLWithPath: "/x/a.\(ext)")
            XCTAssertFalse(CallImport.isSupported(u), "AVFoundation can't open \(ext)")
            XCTAssertTrue(CallImport.isUnreadable(u))
        }
        // The date written in the file wins over the file's own dates (a download's creation date).
        let file = tmp.appendingPathComponent("Downloaded.m4a")
        try write("x", file)
        let downloaded = try XCTUnwrap(Call.parseID("2026-11-05 20-00"))
        try FileManager.default.setAttributes([.creationDate: downloaded], ofItemAtPath: file.path)
        let recorded = try XCTUnwrap(Call.parseID("2026-10-01 09-30"))
        XCTAssertEqual(CallImport.date(of: file), downloaded)
        XCTAssertEqual(CallImport.date(of: file, recorded: recorded), recorded)
        XCTAssertEqual(try CallImport.createFolder(for: file, recorded: recorded, in: calls).lastPathComponent, "2026-10-01 09-30")

        XCTAssertEqual(CallImport.parseDate("2026-11-04T15:01:02Z"), Date(timeIntervalSince1970: 1_793_804_462))
        XCTAssertEqual(CallImport.parseDate("2026-11-04T18:01:02+0300"), Date(timeIntervalSince1970: 1_793_804_462))
        XCTAssertEqual(CallImport.parseDate("2026-11-04T15:01:02.000Z"), Date(timeIntervalSince1970: 1_793_804_462))
        XCTAssertNotNil(CallImport.parseDate("2026-11-04"))
        XCTAssertNil(CallImport.parseDate("вчера"))
        let now = Date(timeIntervalSince1970: 1_793_804_462)
        XCTAssertNil(CallImport.plausible(CallImport.parseDate("1904-01-01T00:00:00Z"), now: now), "QuickTime's empty date")
        XCTAssertNil(CallImport.plausible(now.addingTimeInterval(7 * 86_400), now: now), "a wrong clock")
        XCTAssertEqual(CallImport.plausible(now.addingTimeInterval(-60), now: now), now.addingTimeInterval(-60))
    }

    func testImportLeftoversAfterACrash() throws {
        let now = Date()
        let old = now.addingTimeInterval(-7200)
        func age(_ u: URL, _ d: Date) throws { try FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: u.path) }
        // 1. An import that crashed: call.json without a status and a half-written temp file, two hours ago.
        let crashed = try CallFolder.create(in: calls, at: Call.parseID("2026-10-01 09-30")!)
        let temp = crashed.appendingPathComponent(".import-1.m4a")
        try write("half", temp)
        try age(crashed.appendingPathComponent("call.json"), old); try age(temp, old)
        // 2. The same, but just now (an import in progress): left alone.
        let fresh = try CallFolder.create(in: calls, at: Call.parseID("2026-10-02 09-30")!)
        try write("half", fresh.appendingPathComponent(".import-2.m4a"))
        // 3. A real call with a stale temp file: only the temp file goes.
        let real = try CallFolder.create(in: calls, at: Call.parseID("2026-10-03 09-30")!)
        XCTAssertTrue(CallImport.finish(real, recordedAt: old, seconds: 10))
        try write("audio", real.appendingPathComponent("system.m4a"))
        let stray = real.appendingPathComponent(".import-3.m4a")
        try write("half", stray)
        try age(stray, old)
        // 4. A recorded call (status set) without audio yet, old: stays, it is not an import leftover.
        let recorded = try CallFolder.create(in: calls, at: Call.parseID("2026-10-04 09-30")!)
        XCTAssertTrue(CallImport.finish(recorded, recordedAt: old, seconds: 10))
        try age(recorded.appendingPathComponent("call.json"), old)
        // 5. Only call.json without a status, old (crashed before conversion started).
        let empty = try CallFolder.create(in: calls, at: Call.parseID("2026-10-05 09-30")!)
        try age(empty.appendingPathComponent("call.json"), old)

        XCTAssertEqual(CallImport.leftovers(in: calls, now: now).map(\.lastPathComponent),
                       [crashed.lastPathComponent, ".import-3.m4a", empty.lastPathComponent])
    }

    func testOneTrackCallJSON() throws {
        let dir = try CallFolder.create(in: calls, at: Date())
        XCTAssertTrue(CallImport.finish(dir, recordedAt: Date(), seconds: 125.5))
        let c = CallFile.read(dir)
        XCTAssertEqual(c["status"] as? String, "recorded")
        XCTAssertEqual(c["audio"] as? [String: Double], ["system_start": 0, "system_seconds": 125.5])
        XCTAssertEqual(TrackOffsets(TrackOffsets.times(of: dir)), TrackOffsets(AudioTimes(micStart: 0, systemStart: 0)))
    }
}

final class ActionItemsTests: XCTestCase {
    func testParseSection() {
        let s = """
        ## Коротко
        - [ ] Анна: это не задача

        ## Задачи
        - [ ] Анна: прислать договор, в пятницу
        - [x] Вы: созвониться с юристом
        - [ ] **Борис Иванов**: обновить смету, до 10 ноября
        - проверить бюджет

        ## Открытые вопросы
        - [ ] Олег: тоже не задача
        """
        let items = ActionItems.parse(s)
        XCTAssertEqual(items, [
            ActionItem(owner: "Анна", task: "прислать договор, в пятницу"),
            ActionItem(owner: "Вы", task: "созвониться с юристом", done: true),
            ActionItem(owner: "Борис Иванов", task: "обновить смету, до 10 ноября"),
            ActionItem(owner: "", task: "проверить бюджет"),
        ])
        let en = ActionItems.parse("## Action Items\n- [ ] You: send the deck, tomorrow\n- [ ] Note at 10:30 sharp\n")
        XCTAssertEqual(en, [ActionItem(owner: "You", task: "send the deck, tomorrow"),
                            ActionItem(owner: "", task: "Note at 10:30 sharp")])
        XCTAssertEqual(ActionItems.parse("## Action items\n- [ ] Anna: x").count, 1)
        XCTAssertTrue(ActionItems.parse("## Summary\nNothing").isEmpty)
    }

    func testReminderDuplicates() {
        let call = URL(fileURLWithPath: "/calls/2026-11-04 15-01 · Acme")
        let summary = call.appendingPathComponent("summary.md")
        let links = ["Звонок в Sozvon: 2026-11-04 15-01 · Acme"]
        let existing = [
            ReminderMatch.Existing(title: "Прислать договор", notes: "Звонок · 4 ноября\nЗвонок в Sozvon: 2026-11-04 15-01 · Acme", url: nil),
            ReminderMatch.Existing(title: "Обновить смету", notes: nil, url: summary),
            ReminderMatch.Existing(title: "Чужая задача", notes: "Звонок в Sozvon: 2026-10-01 09-30", url: nil),
        ]
        XCTAssertTrue(ReminderMatch.contains(existing, title: " прислать договор ", links: links, urls: [summary, call]))
        XCTAssertTrue(ReminderMatch.contains(existing, title: "Обновить смету", links: links, urls: [summary, call]))
        XCTAssertFalse(ReminderMatch.contains(existing, title: "Чужая задача", links: links, urls: [summary, call]),
                       "the same title from another call is a different reminder")
        XCTAssertFalse(ReminderMatch.contains(existing, title: "Новая задача", links: links, urls: [summary, call]))
        XCTAssertFalse(ReminderMatch.contains(existing, title: "Прислать договор", links: [""], urls: []))
    }

    func testOwnerOnlyBeforeColonAndSpace() {
        func owner(_ line: String) -> String? { ActionItems.item(line)?.owner }
        XCTAssertEqual(owner("- [ ] Проверить https://x.y"), "", "a link is not an owner")
        XCTAssertEqual(ActionItems.item("- [ ] Проверить https://x.y")?.task, "Проверить https://x.y")
        XCTAssertEqual(owner("- [ ] Посмотреть доклад на www.site.ru: там всё"), "", "a domain is not a name")
        XCTAssertEqual(owner("- [ ] Анна, Борис и Олег: созвониться"), "Анна, Борис и Олег")
        XCTAssertEqual(owner("- [ ] Пять слов в этой строке тут: x"), "")
        XCTAssertEqual(owner("- [ ] Созвон в 10:30 с Анной"), "")
        XCTAssertEqual(owner("- [ ] Почта ann@x.com: ответить"), "")
        XCTAssertEqual(owner("- [ ] **Анна:** прислать"), "Анна")
        XCTAssertEqual(ActionItems.item("- [ ] **Анна:** прислать")?.task, "прислать")
        XCTAssertEqual(owner("- [ ] Анна:прислать"), "", "no space after the colon")
    }

    func testOwnerMatching() {
        XCTAssertTrue(ActionItems.isMine("Борис", me: "Борис"))
        XCTAssertTrue(ActionItems.isMine("борис иванов", me: "Борис"))
        XCTAssertTrue(ActionItems.isMine("Борис", me: "Борис Иванов"))
        XCTAssertTrue(ActionItems.isMine("Анна и Борис", me: "Борис"))
        XCTAssertTrue(ActionItems.isMine("Anna, Boris", me: "boris"))
        XCTAssertTrue(ActionItems.isMine("Вы", me: ""))
        XCTAssertTrue(ActionItems.isMine("You", me: "Boris"))
        XCTAssertTrue(ActionItems.isMine("Я", me: "Boris"))
        XCTAssertFalse(ActionItems.isMine("Анна", me: "Борис"))
        XCTAssertFalse(ActionItems.isMine("Борислав", me: "Борис"))
        XCTAssertFalse(ActionItems.isMine("", me: "Борис"))
        XCTAssertFalse(ActionItems.isMine("Анна", me: ""))
    }

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }

    /// The call is on Wednesday, November 4, 2026.
    private func due(_ text: String) -> String? {
        let call = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 15, minute: 1))!
        guard let d = DueDate.parse(text, callDate: call, calendar: cal) else { return nil }
        return String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
    }

    func testDueDatesRussian() {
        XCTAssertEqual(due("прислать договор, завтра"), "2026-11-05")
        XCTAssertEqual(due("послезавтра утром"), "2026-11-06")
        XCTAssertEqual(due("сегодня до вечера"), "2026-11-04")
        XCTAssertEqual(due("в пятницу"), "2026-11-06")
        XCTAssertEqual(due("до понедельника"), "2026-11-09")
        XCTAssertEqual(due("в среду"), "2026-11-11", "the same weekday is next week")
        XCTAssertEqual(due("к 10 ноября"), "2026-11-10")
        XCTAssertEqual(due("до 15 января"), "2027-01-15", "a past date without a year is next year")
        XCTAssertEqual(due("до 3 марта 2027"), "2027-03-03")
        XCTAssertNil(due("на следующей неделе"))
        XCTAssertNil(due("обсудить средства"))
        XCTAssertNil(due("31 ноября"))
    }

    func testDueDatesEnglish() {
        XCTAssertEqual(due("send the deck, tomorrow"), "2026-11-05")
        XCTAssertEqual(due("the day after tomorrow"), "2026-11-06")
        XCTAssertEqual(due("by Friday"), "2026-11-06")
        XCTAssertEqual(due("Nov 10"), "2026-11-10")
        XCTAssertEqual(due("by November 10th, 2027"), "2027-11-10")
        XCTAssertEqual(due("10 Nov"), "2026-11-10")
        XCTAssertEqual(due("the 2nd of December"), "2026-12-02")
        XCTAssertNil(due("next sprint"))
        XCTAssertNil(due("update the marketing plan 5 times"))
    }
}

/// Tests/Fixtures/action_items.json: the same cases the engine's commitments.parse / is_owner_of run (engine/tests/test_commitments.py).
final class ActionItemsSharedFixtureTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/action_items.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testParseMatchesTheEngineRule() throws {
        let cases = try XCTUnwrap(try fixture()["parse"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 4)
        for c in cases {
            let got = ActionItems.parse(c["summary"] as? String ?? "").map {
                ["owner": $0.owner, "task": $0.task, "done": $0.done ? "true" : "false"]
            }
            let want = (c["items"] as? [[String: Any]] ?? []).map {
                ["owner": $0["owner"] as? String ?? "", "task": $0["task"] as? String ?? "",
                 "done": ($0["done"] as? Bool ?? false) ? "true" : "false"]
            }
            XCTAssertEqual(got, want, c["note"] as? String ?? "")
        }
    }

    func testOwnershipMatchesTheEngineRule() throws {
        let cases = try XCTUnwrap(try fixture()["mine"] as? [[String: Any]])
        for c in cases {
            let me = c["me"] as? String ?? ""
            let note = c["note"] as? String ?? ""
            XCTAssertEqual((c["yes"] as? [String] ?? []).filter { !ActionItems.isMine($0, me: me) }, [], note)
            XCTAssertEqual((c["no"] as? [String] ?? []).filter { ActionItems.isMine($0, me: me) }, [], note)
        }
    }
}

final class CallParticipantsTests: TempDirTestCase {
    /// Tests/Fixtures/participants.json: the same cases the engine's names.participants runs (engine/tests/test_names.py).
    private func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/participants.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testDerivedMatchesTheEngineRule() throws {
        let cases = try XCTUnwrap(try fixture()["participants"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 5)
        for c in cases {
            let got = CallParticipants.derived(c["typed"] as? [String] ?? [], speakers: c["speakers"] as? [String] ?? [],
                                               me: c["me"] as? String ?? "")
            XCTAssertEqual(got, c["participants"] as? [String], c["note"] as? String ?? "")
        }
    }

    func testGenericLabelsMatchTheEngineRule() throws {
        let g = try XCTUnwrap(try fixture()["generic"] as? [String: Any])
        let me = g["me"] as? String ?? ""
        XCTAssertEqual((g["yes"] as? [String] ?? []).filter { !Voices.isGenericLabel($0, me: me) }, [])
        XCTAssertEqual((g["no"] as? [String] ?? []).filter { Voices.isGenericLabel($0, me: me) }, [])
    }

    func testSameNameMatchesTheEngineRule() throws {
        let pairs = try XCTUnwrap(try fixture()["same_name"] as? [String: [[String]]])
        XCTAssertEqual((pairs["same"] ?? []).filter { !Voices.sameName($0[0], $0[1]) }, [])
        XCTAssertEqual((pairs["different"] ?? []).filter { Voices.sameName($0[0], $0[1]) }, [])
    }

    func testListPrefersParticipantsOverTypedNames() {
        XCTAssertEqual(CallParticipants.list(["names": ["Анна"], "participants": ["Анна Петрова"]]), ["Анна Петрова"])
        XCTAssertEqual(CallParticipants.list(["names": ["Анна"]]), ["Анна"], "an older call: the typed names")
        XCTAssertEqual(CallParticipants.list(["names": "Анна, Олег"]), ["Анна", "Олег"], "the old string form")
        XCTAssertNil(CallParticipants.stored(["names": ["Анна"]]))
    }

    private func call(names: String, transcript: String) throws -> URL {
        let dir = calls.appendingPathComponent("2026-11-06 23-13")
        try write(#"{"schema": 1, "id": "2026-11-06 23-13", "names": \#(names), "status": "done"}"#,
                  dir.appendingPathComponent("call.json"))
        try write(transcript, dir.appendingPathComponent("transcript.txt"))
        return dir
    }

    func testUpdateWritesParticipantsAndNeverNames() throws {
        let dir = try call(names: "[]", transcript: "[00:00] Boris: Привет.\n[00:02] Влад: Здорово.\n[00:05] Speaker: Угу.\n")
        XCTAssertTrue(try CallParticipants.update(in: dir, me: "Boris"))
        XCTAssertEqual(CallFile.read(dir)["participants"] as? [String], ["Влад"])
        XCTAssertEqual(CallFile.read(dir)["names"] as? [String], [], "found names are never fed back as typed")
        XCTAssertEqual(CallFile.read(dir)["status"] as? String, "done", "other fields are kept")
        XCTAssertFalse(try CallParticipants.update(in: dir, me: "Boris"), "nothing new: call.json is not rewritten")
    }

    func testUpdateKeepsTypedNamesAndAcceptsTheOldStringForm() throws {
        let dir = try call(names: #""Анна, Олег""#, transcript: "[00:00] Анна: Да.\n[00:01] Иван: Нет.\n")
        XCTAssertTrue(try CallParticipants.update(in: dir, me: ""))
        XCTAssertEqual(CallFile.read(dir)["participants"] as? [String], ["Анна", "Иван", "Олег"])
        XCTAssertEqual(CallFile.read(dir)["names"] as? String, "Анна, Олег")
    }

    func testAPersonLeftWithoutLinesLeavesTheParticipants() throws {
        let dir = try call(names: "[]", transcript: "[00:00] Я: Да.\n[00:01] Иван: Нет.\n[00:03] Влад: Ага.\n")
        XCTAssertTrue(try CallParticipants.update(in: dir, me: "Я"))
        XCTAssertEqual(CallFile.read(dir)["participants"] as? [String], ["Иван", "Влад"])
        XCTAssertTrue(try TranscriptEdit.reassignLine(in: dir, line: TranscriptLine(start: 3, speaker: "Влад", text: "Ага."), to: "Иван"))
        XCTAssertTrue(try CallParticipants.update(in: dir, me: "Я"))
        XCTAssertEqual(CallFile.read(dir)["participants"] as? [String], ["Иван"], "nobody stays in the list forever")
    }

    func testCallShowsParticipantsElseTypedNames() throws {
        let dir = try call(names: #"["Анна"]"#, transcript: "")
        XCTAssertNil(Call.load(dir)?.participants)
        XCTAssertEqual(Call.load(dir)?.people, "Анна")
        CallFile.update(dir) { $0["participants"] = ["Анна Петрова", "Влад"] }
        XCTAssertEqual(Call.load(dir)?.participants, ["Анна Петрова", "Влад"])
        XCTAssertEqual(Call.load(dir)?.people, "Анна Петрова, Влад")
        XCTAssertEqual(Call.load(dir)?.info.names, "Анна", "the typed names are what the info window edits")
        XCTAssertEqual(callDirName("2026-11-06 23-13", CallInfo(names: "Анна"), projectTitle: nil,
                                   people: CallParticipants.list(CallFile.read(dir))), "2026-11-06 23-13 · Анна Петрова, Влад")
    }

    func testUpdateLeavesCallsWithoutTranscriptOrCallJSONAlone() throws {
        let dir = try call(names: "[]", transcript: "")
        XCTAssertFalse(try CallParticipants.update(in: dir, me: ""))
        let legacy = calls.appendingPathComponent("2026-11-01 10-00 · Old")
        try write("[00:00] Анна: Да.\n", legacy.appendingPathComponent("transcript.txt"))
        XCTAssertFalse(try CallParticipants.update(in: legacy, me: ""))
        XCTAssertFalse(CallFile.exists(legacy), "an old call doesn't get a call.json")
    }

    func testUpdateNeverReplacesACorruptCallJSON() throws {
        let dir = try call(names: "[]", transcript: "[00:00] Анна: Да.\n")
        try write("{oops", dir.appendingPathComponent("call.json"))
        XCTAssertThrowsError(try CallParticipants.update(in: dir, me: ""))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("call.json"), encoding: .utf8), "{oops")
    }
}
