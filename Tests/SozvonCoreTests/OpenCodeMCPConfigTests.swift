import Foundation
import XCTest
@testable import SozvonCore

final class OpenCodeMCPConfigTests: XCTestCase {
    let url = "http://127.0.0.1:47816/mcp"

    private func upsert(_ text: String, token: String = "T") -> String? {
        OpenCodeMCPConfig.upsert(text, name: "sozvon", url: url, token: token)
    }

    private func has(_ text: String, token: String? = "T") -> Bool {
        OpenCodeMCPConfig.hasServer(text, name: "sozvon", url: url, token: token)
    }

    private func doc(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func servers(_ text: String) throws -> [String: Any] {
        let mcp = try XCTUnwrap(try doc(text)["mcp"] as? [String: Any])
        return try XCTUnwrap(mcp["servers"] as? [String: Any])
    }

    func testUpsertWritesWhatOpcodesOwnCommandWrites() throws {
        let out = try XCTUnwrap(upsert("{}"))
        let entry = try XCTUnwrap(try servers(out)["sozvon"] as? [String: Any])
        XCTAssertEqual(entry["type"] as? String, "remote")
        XCTAssertEqual(entry["url"] as? String, url)
        let headers = try XCTUnwrap(entry["headers"] as? [String: Any])
        XCTAssertEqual(headers["Authorization"] as? String, "Bearer T")
        XCTAssertTrue(has(out))
    }

    func testOtherServersAndTopLevelEntriesAreKept() throws {
        let text = """
        {
          "mcp": {
            "playwright": {"type": "local", "command": ["npx", "-y", "@playwright/mcp@latest"], "enabled": true},
            "servers": {"sozvon": {"type": "remote", "url": "http://127.0.0.1:9999/mcp"}}
          }
        }
        """
        let out = try XCTUnwrap(upsert(text))
        let mcp = try XCTUnwrap(try doc(out)["mcp"] as? [String: Any])
        let old = try XCTUnwrap(mcp["playwright"] as? [String: Any], "the legacy top-level server stays")
        XCTAssertEqual(old["type"] as? String, "local")
        XCTAssertEqual(old["command"] as? [String], ["npx", "-y", "@playwright/mcp@latest"])
        XCTAssertEqual(old["enabled"] as? Bool, true)
        XCTAssertTrue(has(out), "the entry is replaced with the right url")
        XCTAssertFalse(has(text), "the old port was not ours")
        XCTAssertTrue(OpenCodeMCPConfig.hasEntry(text, name: "sozvon"), "an entry was there: outdated, not none")
    }

    func testRemoveLeavesTheRestUntouched() throws {
        let text = """
        {"mcp": {"servers": {"sozvon": {"type": "remote", "url": "\(url)"}, "github": {"type": "local", "command": ["gh"]}}}}
        """
        let out = try XCTUnwrap(OpenCodeMCPConfig.remove(text, name: "sozvon"))
        let all = try servers(out)
        XCTAssertEqual(all.count, 1)
        XCTAssertNotNil(all["github"])
        XCTAssertFalse(OpenCodeMCPConfig.hasEntry(out, name: "sozvon"))
    }

    func testRemoveWithoutEntryIsNoOp() throws {
        let text = "{\"mcp\": {}}"
        XCTAssertEqual(OpenCodeMCPConfig.remove(text, name: "sozvon"), text)
        XCTAssertEqual(OpenCodeMCPConfig.remove("{\"other\": 1}", name: "sozvon"), "{\"other\": 1}")
    }

    func testGarbageIsRefused() throws {
        XCTAssertNil(upsert("not json at all"))
        XCTAssertNil(OpenCodeMCPConfig.upsert("{\"mcp\": \"not an object\"}", name: "sozvon", url: url, token: "T"))
        XCTAssertNil(OpenCodeMCPConfig.upsert("{\"mcp\": {\"servers\": []}}", name: "sozvon", url: url, token: "T"))
        XCTAssertFalse(has("garbage"))
        XCTAssertFalse(OpenCodeMCPConfig.hasEntry("garbage", name: "sozvon"))
    }
}
