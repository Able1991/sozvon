// A failed call.json write must be reported, never swallowed (audit 3.3).

import XCTest
@testable import SozvonCore

final class CallSaveTests: TempDirTestCase {
    private func makeCall() throws -> URL {
        let dir = calls.appendingPathComponent("2026-11-08 10-00")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: dir.appendingPathComponent("mic.m4a"))
        return dir
    }

    override func tearDownWithError() throws {
        // Let the temp folder be deleted after the read-only tests.
        if let dirs = try? FileManager.default.contentsOfDirectory(at: calls, includingPropertiesForKeys: nil) {
            for d in dirs { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.path) }
        }
        try super.tearDownWithError()
    }

    func testStoppedCallIsSavedAndReportedOK() throws {
        let dir = try makeCall()
        let ok = CallFile.saveStopped(dir, startedAt: Date(), audio: AudioTimes(micSeconds: 5), info: CallInfo(topic: "x"))
        XCTAssertTrue(ok)
        XCTAssertEqual(CallFile.read(dir)["status"] as? String, "recorded")
        XCTAssertEqual(CallFile.read(dir)["topic"] as? String, "x")
    }

    func testStoppedCallReportsAFailedWriteAndKeepsAudio() throws {
        let dir = try makeCall()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let ok = CallFile.saveStopped(dir, startedAt: Date(), audio: AudioTimes(micSeconds: 5), info: CallInfo(topic: "x"))
        XCTAssertFalse(ok)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("mic.m4a")), "audio")
    }

    func testStoppedCallInAVanishedFolderIsReported() {
        let dir = calls.appendingPathComponent("gone")
        XCTAssertFalse(CallFile.saveStopped(dir, startedAt: Date(), audio: AudioTimes(), info: CallInfo()))
    }

    func testQueuedSaveReportsAFailedWrite() throws {
        let dir = try makeCall()
        XCTAssertTrue(CallFile.setQueued(dir, at: Date()))
        XCTAssertNotNil(CallFile.read(dir)[CallFile.queuedAtKey])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertFalse(CallFile.setQueued(dir, at: Date()))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("mic.m4a")), "audio")
    }
}
