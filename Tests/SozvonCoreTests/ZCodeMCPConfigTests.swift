import Foundation
import XCTest
@testable import SozvonCore

final class ZCodeMCPConfigTests: XCTestCase {
    let url = "http://127.0.0.1:47816/mcp"

    private func upsert(_ text: String, token: String = "T") -> String? {
        ZCodeMCPConfig.upsert(text, name: "sozvon", url: url, token: token)
    }

    private func has(_ text: String, token: String? = "T") -> Bool {
        ZCodeMCPConfig.hasServer(text, name: "sozvon", url: url, token: token)
    }

    /// The whole document as [String: Any], the way the ZCode app reads it.
    private func doc(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func servers(_ text: String) throws -> [String: Any] {
        let mcp = try XCTUnwrap(try doc(text)["mcp"] as? [String: Any])
        return try XCTUnwrap(mcp["servers"] as? [String: Any])
    }

    func testEmptyOrMissingDocumentGetsFreshConfig() throws {
        let out = try XCTUnwrap(upsert("{}"))
        let entry = try XCTUnwrap(try servers(out)["sozvon"] as? [String: Any])
        XCTAssertEqual(entry["type"] as? String, "http")
        XCTAssertEqual(entry["url"] as? String, url)
        XCTAssertEqual(entry["protocolVersion"] as? String, "auto", "the client and FastMCP agree on the version")
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        let headers = try XCTUnwrap(entry["headers"] as? [String: Any])
        XCTAssertEqual(headers["Authorization"] as? String, "Bearer T")
        XCTAssertTrue(has(out))
        XCTAssertTrue(has(try XCTUnwrap(upsert("  \n"))), "an empty file works too")
    }

    func testOtherServersAndOtherRootKeysAreKept() throws {
        let text = """
        {
          "plugins": {"demo": {"on": true}},
          "mcp": {
            "servers": {
              "playwright": {"type": "stdio", "command": "npx", "args": ["-y", "@playwright/mcp@latest"], "enabled": false},
              "sozvon": {"type": "http", "url": "http://127.0.0.1:9999/mcp"}
            }
          }
        }
        """
        let out = try XCTUnwrap(upsert(text))
        let all = try servers(out)
        XCTAssertEqual(all.count, 2, "the other server stays")
        let old = try XCTUnwrap(all["playwright"] as? [String: Any])
        XCTAssertEqual(old["command"] as? String, "npx")
        XCTAssertEqual((try doc(out))["plugins"] as? [String: [String: Bool]], ["demo": ["on": true]])
        XCTAssertTrue(has(out), "the entry is replaced with the right url")
        XCTAssertFalse(has(text), "the old port was not ours")
        XCTAssertTrue(ZCodeMCPConfig.hasEntry(text, name: "sozvon"), "but an entry was there: outdated, not none")
    }

    func testWrongTokenIsConnectedOnlyWithTheRightOne() throws {
        let out = try XCTUnwrap(upsert("{}", token: "T"))
        XCTAssertTrue(has(out, token: "T"))
        XCTAssertFalse(has(out, token: "X"), "another password is a different setup")
        XCTAssertTrue(ZCodeMCPConfig.hasServer(out, name: "sozvon", url: url), "url alone still counts")
    }

    func testRemoveLeavesTheRestUntouched() throws {
        let text = """
        {"mcp": {"servers": {"sozvon": {"type": "http", "url": "\(url)"}, "github": {"type": "stdio", "command": "gh"}}}, "plugins": {}}
        """
        let out = try XCTUnwrap(ZCodeMCPConfig.remove(text, name: "sozvon"))
        let all = try servers(out)
        XCTAssertEqual(all.count, 1)
        XCTAssertNotNil(all["github"])
        XCTAssertFalse(ZCodeMCPConfig.hasEntry(out, name: "sozvon"))
        let plugins = try XCTUnwrap((try doc(out))["plugins"] as? [String: Any])
        XCTAssertTrue(plugins.isEmpty)
    }

    func testRemoveWithoutEntryIsNoOp() throws {
        let text = "{\"plugins\": {}}"
        XCTAssertEqual(ZCodeMCPConfig.remove(text, name: "sozvon"), text)
        XCTAssertEqual(ZCodeMCPConfig.remove("{\"mcp\": {}}", name: "sozvon"), "{\"mcp\": {}}")
        XCTAssertEqual(ZCodeMCPConfig.remove("{\"mcp\": \"not an object\"}", name: "sozvon"),
                       "{\"mcp\": \"not an object\"}", "nothing to remove, the file stays as it is")
    }

    func testGarbageIsRefused() throws {
        XCTAssertNil(upsert("not json at all"))
        XCTAssertNil(ZCodeMCPConfig.remove("[1, 2]", name: "sozvon"), "not an object")
        XCTAssertNil(ZCodeMCPConfig.upsert("\"just a string\"", name: "sozvon", url: url, token: "T"))
        XCTAssertNil(ZCodeMCPConfig.upsert("{\"mcp\": \"not an object\"}", name: "sozvon", url: url, token: "T"),
                     "a non-object mcp is not ours to fix")
        XCTAssertNil(ZCodeMCPConfig.upsert("{\"mcp\": {\"servers\": []}}", name: "sozvon", url: url, token: "T"))
        XCTAssertFalse(has("garbage"))
        XCTAssertFalse(ZCodeMCPConfig.hasEntry("garbage", name: "sozvon"))
    }
}
