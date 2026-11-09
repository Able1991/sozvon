import Foundation
import XCTest
@testable import SozvonCore

final class VoicesTests: TempDirTestCase {
    private func record(_ id: String, _ body: String) throws {
        try write(body, Voices.dir.appendingPathComponent("\(id).json"))
    }

    func testRecordsAreReadFromDataFolder() throws {
        XCTAssertEqual(Voices.all(), [], "no folder: no voices")
        try record("a1", #"{"schema":1,"id":"a1","name":"Олег","profile":"acme","me":false,"embedding":[0.1,0.2],"seconds":12.5,"updated_at":"2026-11-01T10:00:00Z"}"#)
        try record("me", #"{"schema":1,"id":"me","name":"Аня","profile":"","me":true,"embedding":[],"seconds":24,"updated_at":"2026-11-02T10:00:00Z"}"#)
        try record("b2", #"{"schema":1,"id":"b2","name":"анна","profile":"acme","me":false,"seconds":5,"updated_at":""}"#)
        try record("c3", #"{"schema":1,"id":"c3","name":"Иван","profile":"other"}"#)
        try record("broken", "{not json")
        try record("noid", #"{"name":"X"}"#)
        try write("ignored", Voices.dir.appendingPathComponent("notes.txt"))

        let all = Voices.all()
        XCTAssertEqual(all.map(\.id), ["b2", "me", "c3", "a1"], "sorted by name, broken files skipped")
        XCTAssertEqual(all.last, VoiceRecord(id: "a1", name: "Олег", profile: "acme", me: false, seconds: 12.5,
                                             updatedAt: "2026-11-01T10:00:00Z"))
        XCTAssertEqual(Voices.me?.id, "me")
        XCTAssertEqual(Voices.me?.seconds, 24)
        XCTAssertEqual(Voices.forProfile("acme").map(\.id), ["b2", "a1"], "the own voice isn't a project voice")
        XCTAssertEqual(Voices.forProfile("").map(\.id), [])
        XCTAssertEqual(Voices.voice(named: "Анна ", profile: "acme", in: all)?.id, "b2", "case-insensitive")
        XCTAssertNil(Voices.voice(named: "Иван", profile: "acme", in: all))
    }

    func testRecordWithModelFieldIsRead() throws {
        try record("m1", #"{"schema":1,"id":"m1","name":"Олег","profile":"","me":false,"embedding":[0.1],"seconds":9,"updated_at":"2026-11-01T10:00:00Z","model":"wespeaker-voxceleb-resnet34-LM/256"}"#)
        try record("m2", #"{"schema":1,"id":"m2","name":"Анна","model":"other/model/512","future":{"x":1}}"#)
        XCTAssertEqual(Voices.all().map(\.id), ["m2", "m1"], "unknown fields, the model among them, don't hide a record")
    }

    func testArgumentBuilders() {
        let wav = URL(fileURLWithPath: "/tmp/me.wav")
        XCTAssertEqual(Voices.enrollFile(name: "Я", me: true, file: wav),
                       ["enroll", "--name", "Я", "--me", "--file", "/tmp/me.wav"])
        XCTAssertEqual(Voices.enrollFile(name: "Я", me: true, add: true, file: wav),
                       ["enroll", "--name", "Я", "--me", "--add", "--file", "/tmp/me.wav"], "one more sample")
        XCTAssertEqual(Voices.enrollFile(name: "Олег", profile: "acme", me: false, file: wav),
                       ["enroll", "--name", "Олег", "--profile", "acme", "--file", "/tmp/me.wav"])
        let dir = URL(fileURLWithPath: "/calls/2026-11-04 15-01")
        XCTAssertEqual(Voices.enrollCall(name: "Олег", profile: "acme", dir: dir, speaker: "Олег"),
                       ["enroll", "--name", "Олег", "--profile", "acme", "--call", "/calls/2026-11-04 15-01", "--speaker", "Олег"])
        XCTAssertEqual(Voices.enrollCall(name: "Олег", dir: dir, speaker: "Олег"),
                       ["enroll", "--name", "Олег", "--call", "/calls/2026-11-04 15-01", "--speaker", "Олег"])
        XCTAssertEqual(Voices.delete(id: "a1"), ["delete", "--id", "a1"])
        XCTAssertEqual(Voices.deleteAll(), ["delete", "--all"])
    }

    func testGenericLabels() {
        for n in ["Собеседник", "Собеседник 2", "собеседник 12", "Speaker", "Speaker 3", "Speaker N", "SPEAKER_00",
                  "Спикер 1", "Спикер ?", "Я", "Me", "me", "Я + собеседники", "Аня + others", "", "  "] {
            XCTAssertTrue(Voices.isGenericLabel(n), n)
        }
        XCTAssertTrue(Voices.isGenericLabel("аня", me: "Аня"), "the user's own name")
        for n in ["Олег", "Speaker Smith", "Собеседница Анна", "Mei", "Яна"] {
            XCTAssertFalse(Voices.isGenericLabel(n, me: "Аня"), n)
        }
        XCTAssertEqual(Voices.namesToEnroll(["Олег", "Собеседник 1", "олег", "Аня", " Иван "], me: "Аня"), ["Олег", "Иван"])
        // The name in Settings can be empty or in another alphabet: my own voice print knows it too.
        XCTAssertEqual(Voices.namesToEnroll(["Boris", "Борис", "Влад"], me: "", own: ["Boris"]), ["Влад"])
        XCTAssertTrue(Voices.isGenericLabel("Борис", me: "Boris"))
        XCTAssertTrue(Voices.sameName("Борис", " boris "))
        XCTAssertFalse(Voices.sameName("", ""))
        XCTAssertFalse(Voices.sameName("Борис", "Влад"))
    }

    func testResultLineCarriesValue() {
        XCTAssertEqual(RunOutcome.parseLine("RESULT: ok a1b2"), .init(ok: true, code: 0, message: "a1b2"))
        XCTAssertEqual(RunOutcome.parse(exitCode: 0, lines: ["x", "RESULT: ok a1b2"]), .ok)
        XCTAssertEqual(RunOutcome.parse(exitCode: 1, lines: ["RESULT: error 2 мало речи"]), .noAudio("мало речи"))
    }
}

final class UnsavedVoicesTests: XCTestCase {
    func testOnlyNamedSpeakersWithoutAPrint() {
        let records = [VoiceRecord(id: "a", name: "Мария Соколова", profile: "vitrina"),
                       VoiceRecord(id: "b", name: "Олег", profile: ""),
                       VoiceRecord(id: "c", name: "Иван", profile: "acme"),
                       VoiceRecord(id: "m", name: "Boris", me: true)]
        let speakers = ["Boris", "Собеседник 1", "Мария Соколова", "Олег", "Иван", "Александр Бородин", "Александр Бородин"]
        XCTAssertEqual(Voices.unsaved(speakers: speakers, profile: "vitrina", records: records, me: "Boris"),
                       ["Иван", "Александр Бородин"], "Иван is saved only for another project")
    }
}
