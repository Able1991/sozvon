// Shared test fixture: temporary data and calls folders via app defaults.

import Foundation
import XCTest
@testable import SozvonCore

class TempDirTestCase: XCTestCase {
    var tmp: URL!
    var data: URL { tmp.appendingPathComponent("data") }
    var calls: URL { tmp.appendingPathComponent("calls") }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sozvon-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: calls, withIntermediateDirectories: true)
        // Like launch arguments (-engineDir …): they override saved defaults and aren't written to disk.
        UserDefaults.standard.setVolatileDomain(["engineDir": data.path, "callsDir": calls.path,
                                                 "logsDir": tmp.appendingPathComponent("logs").path],
                                                forName: UserDefaults.argumentDomain)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        try? FileManager.default.removeItem(at: tmp)
    }

    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}
