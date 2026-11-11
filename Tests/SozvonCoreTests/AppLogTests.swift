import Foundation
import XCTest
@testable import SozvonCore

final class AppLogTests: TempDirTestCase {
    func testCreatesTheFolderAndAppends() throws {
        let f = tmp.appendingPathComponent("logs/deep/app.log")
        AppLog.append("one\n", to: f)
        AppLog.append("two\n", to: f)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "one\ntwo\n")
    }

    func testKeepsWhatAnotherWriterAdded() throws {
        let f = tmp.appendingPathComponent("app.log")
        try write("theirs\n", f)
        AppLog.append("ours\n", to: f)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "theirs\nours\n")
    }

    /// recorder.log is written from the capture queue and the main thread at once: no line may be lost or cut.
    func testLinesFromManyThreadsStayWhole() throws {
        let f = tmp.appendingPathComponent("logs/recorder.log")
        let threads = 8, perThread = 200
        DispatchQueue.concurrentPerform(iterations: threads) { t in
            for i in 0..<perThread { AppLog.append("thread \(t) line \(i) \(String(repeating: "x", count: 200))\n", to: f) }
        }
        let lines = try String(contentsOf: f, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, threads * perThread)
        XCTAssertEqual(Set(lines).count, threads * perThread, "every line is there once")
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("thread ") && $0.hasSuffix(String(repeating: "x", count: 200)) }, "no line is cut")
    }
}
