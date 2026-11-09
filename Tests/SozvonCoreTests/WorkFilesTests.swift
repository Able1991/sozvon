// <call>/.work: the engine's working files, cleared at launch (contract section 4).

import XCTest
@testable import SozvonCore

final class WorkFilesTests: TempDirTestCase {
    private func call(_ name: String, status: String = "done", work: Bool = true) throws -> URL {
        let dir = calls.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"schema": 1, "id": "\#(name)", "status": "\#(status)"}"#.utf8).write(to: dir.appendingPathComponent("call.json"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("mic.m4a"))
        if work {
            let w = dir.appendingPathComponent(WorkFiles.folder)
            try FileManager.default.createDirectory(at: w, withIntermediateDirectories: true)
            try Data(count: 5000).write(to: w.appendingPathComponent("mic.wav"))
        }
        return dir
    }

    private func hasWork(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(WorkFiles.folder).path)
    }

    func testSweepRemovesWorkAndKeepsEverythingElse() throws {
        let a = try call("2026-11-04 15-01"), b = try call("2026-11-04 15-02", status: "failed")
        WorkFiles.sweep(in: calls, keeping: [])
        XCTAssertFalse(hasWork(a)); XCTAssertFalse(hasWork(b))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.appendingPathComponent("mic.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.appendingPathComponent("call.json").path))
    }

    func testCallsInTheRestoredQueueAreLeftAlone() throws {
        let a = try call("2026-11-04 15-01"), b = try call("2026-11-04 15-02")
        WorkFiles.sweep(in: calls, keeping: [a])
        XCTAssertTrue(hasWork(a)); XCTAssertFalse(hasWork(b))
    }

    func testARunningCallIsLeftAlone() throws {
        // An engine started after launch, while the sweep was still going.
        let a = try call("2026-11-04 15-01", status: "processing")
        WorkFiles.sweep(in: calls, keeping: [])
        XCTAssertTrue(hasWork(a))
    }

    func testFolderWithoutWorkAndStrayFilesAreFine() throws {
        _ = try call("2026-11-04 15-01", work: false)
        try Data("x".utf8).write(to: calls.appendingPathComponent("stray.txt"))
        WorkFiles.sweep(in: calls, keeping: [])
    }

    func testWorkIsNotPartOfTheCallSize() throws {
        let a = try call("2026-11-04 15-01")
        let with = Call.folderSize(a)
        try FileManager.default.removeItem(at: a.appendingPathComponent(WorkFiles.folder))
        XCTAssertEqual(with, Call.folderSize(a))
    }
}
