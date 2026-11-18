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

    func testEntryDisablesOAuth() throws {
        let out = try XCTUnwrap(upsert("{}"))
        let entry = try XCTUnwrap(try servers(out)["sozvon"] as? [String: Any])
        XCTAssertEqual(entry["type"] as? String, "remote")
        XCTAssertEqual(entry["oauth"] as? Bool, false, "a bearer header is not an OAuth flow")
        XCTAssertEqual(entry["url"] as? String, url)
    }

    func testJsoncIsEditedInPlace() throws {
        // opencode.jsonc in the wild: comments, trailing commas, floats the JSON round trip mangled.
        let text = """
        // OpenCode config
        {
          "theme": "dark",
          "model": {"provider": "anthropic", "temperature": 0.7},
          "mcp": {
            "servers": {
              // "sozvon": {"url": "http://old"},
              "context7": {"type": "remote", "url": "https://mcp.context7.com/mcp"}, // trailing
            },
          },
        }
        """
        XCTAssertFalse(OpenCodeMCPConfig.hasEntry(text, name: "sozvon"), "a commented-out entry does not count")
        let out = try XCTUnwrap(upsert(text))
        XCTAssertTrue(has(out))
        for kept in ["// OpenCode config", "\"temperature\": 0.7", "// \"sozvon\": {\"url\": \"http://old\"}",
                     "\"url\": \"https://mcp.context7.com/mcp\"}, // trailing"] {
            XCTAssertTrue(out.contains(kept), kept)
        }
        let back = try XCTUnwrap(OpenCodeMCPConfig.remove(out, name: "sozvon"))
        XCTAssertEqual(back, text, "removal returns the file to what it was")
    }
}

final class OpenCodeMCPFileTests: TempDirTestCase {
    func testConnectCreatesPrivateFileThenDisconnects() throws {
        let f = tmp.appendingPathComponent("home/.config/opencode/opencode.json")
        XCTAssertEqual(MCP.opencodeConnection(file: f, token: "T"), .none)
        XCTAssertTrue(MCP.opencodeConnect(file: f, token: "T").0)
        let perm = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perm.intValue, 0o600, "the file holds a password")
        XCTAssertEqual(MCP.opencodeConnection(file: f, token: "T"), .connected)
        XCTAssertEqual(MCP.opencodeConnection(file: f, token: "OTHER"), .outdated)
        XCTAssertTrue(MCP.opencodeDisconnect(file: f).0)
        XCTAssertEqual(MCP.opencodeConnection(file: f, token: "T"), .none)
    }

    func testConnectRefusesBadFileWithoutTouchingIt() throws {
        let f = tmp.appendingPathComponent(".config/opencode/opencode.json")
        try write("{ broken", f)
        let (ok, msg) = MCP.opencodeConnect(file: f, token: "T")
        XCTAssertFalse(ok)
        XCTAssertFalse(msg.isEmpty)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "{ broken", "the file is untouched")
        // An unreadable file is not overwritten with a fresh config either.
        try FileManager.default.removeItem(at: f)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let (ok2, msg2) = MCP.opencodeConnect(file: f, token: "T")
        XCTAssertFalse(ok2)
        XCTAssertFalse(msg2.isEmpty)
    }
}
