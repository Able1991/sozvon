import XCTest
@testable import SozvonCore

/// Choosing another calls folder: which folders make no sense, and moving the calls there without losing any.
final class CallsFolderTests: XCTestCase {
    var tmp: URL!
    var old: URL!
    var data: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("calls-folder-\(UUID().uuidString)")
        old = tmp.appendingPathComponent("Calls")
        data = tmp.appendingPathComponent("Data")
        for d in [old!, data!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func makeCall(_ name: String, in root: URL? = nil) throws -> URL {
        let d = (root ?? old).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data("{\"id\":\"\(name)\"}".utf8).write(to: d.appendingPathComponent("call.json"))
        try Data(repeating: 7, count: 5000).write(to: d.appendingPathComponent("mic.m4a"))
        return d
    }

    func testFoldersThatMakeNoSense() {
        XCTAssertEqual(CallsFolder.problem(from: old, to: old, data: data), .same)
        XCTAssertEqual(CallsFolder.problem(from: old, to: old.appendingPathComponent("Sub"), data: data), .inside)
        XCTAssertEqual(CallsFolder.problem(from: old, to: tmp, data: data), .contains)
        XCTAssertEqual(CallsFolder.problem(from: old, to: data, data: data), .engineData)
        XCTAssertEqual(CallsFolder.problem(from: old, to: data.appendingPathComponent("x"), data: data), .engineData)
        XCTAssertNil(CallsFolder.problem(from: old, to: tmp.appendingPathComponent("New"), data: data))
    }

    func testOnlyCallFoldersCount() throws {
        _ = try makeCall("2026-11-04 15-01 · Acme")
        _ = try makeCall("2026-11-05 10-00")
        try FileManager.default.createDirectory(at: old.appendingPathComponent("Random"), withIntermediateDirectories: true)
        try Data().write(to: old.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(CallsFolder.calls(in: old).map(\.lastPathComponent).sorted(), ["2026-11-04 15-01 · Acme", "2026-11-05 10-00"])
    }

    func testMoveTakesEveryCallAndLeavesTheRest() throws {
        _ = try makeCall("2026-11-04 15-01 · Acme")
        _ = try makeCall("2026-11-05 10-00")
        try FileManager.default.createDirectory(at: old.appendingPathComponent("Random"), withIntermediateDirectories: true)
        let new = tmp.appendingPathComponent("New")
        var seen: [Int] = []
        let moved = try CallsFolder.move(from: old, to: new, trash: { try FileManager.default.removeItem(at: $0) },
                                         progress: { done, _ in seen.append(done) })
        XCTAssertEqual(moved, 2)
        XCTAssertEqual(CallsFolder.calls(in: new).count, 2)
        XCTAssertTrue(CallsFolder.calls(in: old).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("Random").path))
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("2026-11-05 10-00/mic.m4a")).count, 5000)
        XCTAssertEqual(seen.last, 2)
    }

    func testANameTakenInTheNewFolderStopsBeforeMovingAnything() throws {
        _ = try makeCall("2026-11-04 15-01")
        _ = try makeCall("2026-11-05 10-00")
        let new = tmp.appendingPathComponent("New")
        _ = try makeCall("2026-11-05 10-00", in: new)
        XCTAssertThrowsError(try CallsFolder.move(from: old, to: new, trash: { _ in XCTFail("nothing goes") },
                                                  progress: { _, _ in })) { error in
            XCTAssertEqual(error as? CallsFolder.MoveError, .taken(["2026-11-05 10-00"]))
        }
        XCTAssertEqual(CallsFolder.calls(in: old).count, 2)
    }

    func testACopyToAnotherDiskIsCheckedBeforeTheOriginalGoes() throws {
        let call = try makeCall("2026-11-04 15-01")
        let new = tmp.appendingPathComponent("New")
        var trashed: [URL] = []
        // The copy path, as on another volume: the original goes to the Trash only after the copy matches it.
        let moved = try CallsFolder.move(from: old, to: new, sameVolume: false,
                                         trash: { trashed.append($0); try FileManager.default.removeItem(at: $0) },
                                         progress: { _, _ in })
        XCTAssertEqual(moved, 1)
        XCTAssertEqual(trashed.map(\.lastPathComponent), [call.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("2026-11-04 15-01/mic.m4a")).count, 5000)
    }

    func testTheChoiceIsKeptAndTheDefaultIsDocumentsCalls() {
        // Read the suite's own domain: launch arguments of other tests (callsDir) override what a lookup returns.
        let name = "calls-folder-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        CallsFolder.choose(tmp, defaults)
        XCTAssertEqual(defaults.persistentDomain(forName: name)?[CallsFolder.defaultsKey] as? String, tmp.path)
        CallsFolder.choose(nil, defaults)
        XCTAssertNil(defaults.persistentDomain(forName: name)?[CallsFolder.defaultsKey])
        XCTAssertTrue(CallsFolder.defaultURL.path.hasSuffix("Documents/Calls"))
    }
}
