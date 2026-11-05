import Foundation
import XCTest
@testable import SozvonCore

final class RecordingMachineTests: XCTestCase {
    let dir = URL(fileURLWithPath: "/calls/2026-11-04 15-01")
    let other = URL(fileURLWithPath: "/calls/2026-11-04 16-00")

    private func session(_ d: URL? = nil) -> RecordingSession {
        RecordingSession(dir: d ?? dir, startedAt: Date(timeIntervalSince1970: 0), info: CallInfo())
    }

    func testHappyPath() async {
        var m = RecordingMachine()
        XCTAssertEqual(m.state.name, "idle")
        XCTAssertTrue(m.begin(dir))
        XCTAssertEqual(m.state.name, "starting")
        XCTAssertEqual(m.state.dir, dir)
        XCTAssertTrue(m.started(session()))
        XCTAssertTrue(m.state.isRecording)
        XCTAssertTrue(m.updateInfo(CallInfo(profile: "acme")))
        XCTAssertEqual(m.state.session?.info.profile, "acme")
        let task = Task<Void, Never> {}
        let s = m.stop(finalize: task)
        XCTAssertEqual(s?.info.profile, "acme", "остановка отдаёт сессию с ответами")
        XCTAssertTrue(m.state.isStopping)
        XCTAssertTrue(m.state.isCapturing)
        XCTAssertNotNil(m.state.finalizeTask, "задачу дописывания можно дождаться (выход, сбой)")
        await m.state.finalizeTask?.value
        XCTAssertTrue(m.finalized())
        XCTAssertEqual(m.state.name, "saved")
        XCTAssertTrue(m.dismissSaved(dir))
        XCTAssertEqual(m.state.name, "idle")
    }

    func testDoubleStartRejected() {
        var m = RecordingMachine()
        XCTAssertTrue(m.begin(dir))
        XCTAssertFalse(m.begin(other), "двойной клик не запускает две записи")
        XCTAssertTrue(m.started(session()))
        XCTAssertFalse(m.begin(other), "во время записи новая не начинается")
    }

    func testStartFailed() {
        var m = RecordingMachine()
        XCTAssertFalse(m.startFailed())
        m.begin(dir)
        XCTAssertTrue(m.startFailed())
        XCTAssertEqual(m.state.name, "idle")
    }

    func testStartedForWrongDirRejected() {
        var m = RecordingMachine()
        m.begin(dir)
        XCTAssertFalse(m.started(session(other)))
        XCTAssertTrue(m.state.isStarting)
    }

    func testInvalidTransitions() {
        var m = RecordingMachine()
        XCTAssertNil(m.stop(finalize: Task {}), "нечего останавливать")
        XCTAssertFalse(m.finalized())
        XCTAssertFalse(m.updateInfo(CallInfo()))
        XCTAssertFalse(m.dismissSaved(dir))
        m.begin(dir)
        XCTAssertNil(m.stop(finalize: Task {}), "запуск ещё не закончился")
        m.started(session())
        m.stop(finalize: Task {})
        XCTAssertNil(m.stop(finalize: Task {}), "второй стоп во время остановки")
        XCTAssertFalse(m.updateInfo(CallInfo()))
    }

    func testNewRecordingWhileSavedQuestionOpen() {
        var m = RecordingMachine()
        m.begin(dir)
        m.started(session())
        m.stop(finalize: Task {})
        m.finalized()
        XCTAssertTrue(m.begin(other), "пока висит вопрос о звонке, можно начать новую запись")
        XCTAssertFalse(m.dismissSaved(dir), "ответ на старый вопрос не сбрасывает новую запись")
        XCTAssertTrue(m.state.isStarting)
    }

    func testElapsed() {
        let s = session()
        XCTAssertEqual(s.elapsed(at: Date(timeIntervalSince1970: 754)), "12:34")
        XCTAssertEqual(s.elapsed(at: Date(timeIntervalSince1970: 0)), "0:00")
    }
}

final class ProcessingQueueTests: XCTestCase {
    let a = URL(fileURLWithPath: "/calls/a")
    let b = URL(fileURLWithPath: "/calls/b")

    func testAdmitAndFinish() {
        var q = ProcessingQueue()
        XCTAssertEqual(q.admit(a), .start)
        XCTAssertEqual(q.count, 1)
        XCTAssertTrue(q.contains(a))
        XCTAssertTrue(q.contains(URL(fileURLWithPath: "/calls/./a")), "один путь в разной записи")
        XCTAssertEqual(q.admit(a), .duplicate, "вторая расшифровка той же папки")
        XCTAssertEqual(q.admit(b), .start)
        XCTAssertEqual(q.count, 2)
        q.finish(a)
        XCTAssertFalse(q.contains(a))
        XCTAssertEqual(q.count, 1)
        q.finish(b)
        XCTAssertTrue(q.isEmpty)
    }

    func testPendingWhileEngineUpdating() {
        var q = ProcessingQueue()
        XCTAssertTrue(q.beginEngineUpdate())
        XCTAssertFalse(q.beginEngineUpdate(), "обновление уже идёт")
        XCTAssertEqual(q.admit(a), .queued)
        XCTAssertEqual(q.admit(a), .duplicate)
        XCTAssertEqual(q.admit(b), .queued)
        XCTAssertEqual(q.count, 0, "ничего не расшифровывается")
        XCTAssertTrue(q.contains(b))
        let pending = q.endEngineUpdate()
        XCTAssertEqual(pending, [a, b], "по порядку")
        XCTAssertFalse(q.engineUpdating)
        XCTAssertFalse(q.contains(a))
        XCTAssertEqual(q.admit(a), .start)
    }
}

final class AudioMathTests: XCTestCase {
    func testGapFiller() {
        XCTAssertEqual(GapFiller.silenceFrames(firstPTS: 10, framesWritten: 48000, sampleRate: 48000, pts: 11), 0, "без разрыва")
        XCTAssertEqual(GapFiller.silenceFrames(firstPTS: 10, framesWritten: 48000, sampleRate: 48000, pts: 11.2), 0,
                       "джиттер до 0,25 с не заполняем")
        XCTAssertEqual(GapFiller.silenceFrames(firstPTS: 10, framesWritten: 48000, sampleRate: 48000, pts: 13.5), 120_000,
                       "2,5 с тишины")
        XCTAssertEqual(GapFiller.silenceFrames(firstPTS: 10, framesWritten: 48000, sampleRate: 48000, pts: 10.5), 0,
                       "пакет из прошлого не заполняем")
        XCTAssertEqual(GapFiller.silenceFrames(firstPTS: 0, framesWritten: 0, sampleRate: 0, pts: 5), 0)
        XCTAssertEqual(GapFiller.chunks(120_000, maxChunk: 48000), [48000, 48000, 24000])
        XCTAssertEqual(GapFiller.chunks(0, maxChunk: 48000), [])
    }

    func testSignalMonitor() {
        var m = SignalMonitor()
        let t0 = Date(timeIntervalSince1970: 1000)
        var r = m.update(now: t0, mic: (0.5, t0), system: (0.4, t0))
        XCTAssertEqual(r, .init(mic: 0.5, system: 0.4, systemSilent: 0, micMissing: 0))
        r = m.update(now: t0.addingTimeInterval(1), mic: (0.5, t0.addingTimeInterval(1)), system: (0.001, t0.addingTimeInterval(1)))
        XCTAssertEqual(r.systemSilent, 0, "тишина только началась")
        r = m.update(now: t0.addingTimeInterval(21), mic: (0.5, t0.addingTimeInterval(21)), system: (0.001, t0.addingTimeInterval(21)))
        XCTAssertEqual(r.systemSilent, 20)
        r = m.update(now: t0.addingTimeInterval(22), mic: (0.5, t0), system: (0.3, t0.addingTimeInterval(22)))
        XCTAssertEqual(r.mic, 0, "старый пакет микрофона: уровень 0")
        XCTAssertEqual(r.systemSilent, 0, "звук вернулся")
        r = m.update(now: t0.addingTimeInterval(31), mic: (0.5, t0), system: (0.3, t0.addingTimeInterval(31)))
        XCTAssertEqual(r.micMissing, 9)
    }
}
