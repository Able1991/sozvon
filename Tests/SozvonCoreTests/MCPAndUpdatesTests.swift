import Foundation
import XCTest
@testable import SozvonCore

final class MCPTests: TempDirTestCase {
    func testCodexHeaderAdded() {
        let text = "model = \"o3\"\n\n[mcp_servers.sozvon]\nurl = \"http://127.0.0.1:47816/mcp\"\n\n[other]\nx = 1\n"
        let out = MCP.codexConfig(text, token: "T")
        XCTAssertEqual(out, "model = \"o3\"\n\n[mcp_servers.sozvon]\nhttp_headers = { \"Authorization\" = \"Bearer T\" }\n"
                       + "url = \"http://127.0.0.1:47816/mcp\"\n\n[other]\nx = 1\n")
    }

    func testCodexHeaderReplacedNotDuplicated() throws {
        let text = "[mcp_servers.sozvon]\nhttp_headers = { \"Authorization\" = \"Bearer OLD\" }\nurl = \"u\"\n"
        let out = try XCTUnwrap(MCP.codexConfig(text, token: "NEW"))
        XCTAssertEqual(out.components(separatedBy: "http_headers").count, 2, "один заголовок")
        XCTAssertTrue(out.contains("Bearer NEW") && !out.contains("OLD"))
        XCTAssertTrue(out.hasSuffix("url = \"u\"\n"))
        XCTAssertEqual(MCP.codexConfig(out, token: "NEW"), out, "повторная правка ничего не меняет")
    }

    func testCodexOtherSectionsUntouched() {
        let text = "[mcp_servers.other]\nhttp_headers = { a = 1 }\n[mcp_servers.sozvon]\nurl = \"u\""
        let out = MCP.codexConfig(text, token: "T")
        XCTAssertEqual(out, "[mcp_servers.other]\nhttp_headers = { a = 1 }\n[mcp_servers.sozvon]\n"
                       + "http_headers = { \"Authorization\" = \"Bearer T\" }\nurl = \"u\"")
        XCTAssertNil(MCP.codexConfig("[mcp_servers.other]\n", token: "T"), "нет секции Sozvon")
    }

    func testTokenCreatedOnceWithOwnerOnlyPermissions() throws {
        let t = MCP.token(in: data)
        XCTAssertEqual(t.count, 64)
        let f = data.appendingPathComponent(".mcp-token")
        let perm = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perm.intValue, 0o600)
        XCTAssertEqual(MCP.token(in: data), t, "из кеша")
        try write(String(repeating: "b", count: 64), f)
        XCTAssertEqual(MCP.token(in: data), t, "диск не перечитывается")
        let other = tmp.appendingPathComponent("other")
        try write(String(repeating: "c", count: 40), other.appendingPathComponent(".mcp-token"))
        XCTAssertEqual(MCP.token(in: other), String(repeating: "c", count: 40), "другая папка данных: свой пароль")
    }

    func testHealthClassification() {
        XCTAssertEqual(MCPHealth.classify(statusCode: 200, error: nil), .listening)
        XCTAssertEqual(MCPHealth.classify(statusCode: 401, error: nil), .unauthorized)
        XCTAssertEqual(MCPHealth.classify(statusCode: 500, error: nil), .unexpected(500))
        XCTAssertEqual(MCPHealth.classify(statusCode: nil, error: .cannotConnectToHost), .notListening)
        XCTAssertEqual(MCPHealth.classify(statusCode: nil, error: .timedOut), .notListening)
    }

    func testProbeClosedPort() async {
        // Порт 1 на localhost никто не слушает: отказ в соединении.
        let h = await MCPHealth.probe(port: 1, token: "x")
        XCTAssertEqual(h, .notListening)
    }
}

final class UpdatesTests: XCTestCase {
    func testVersionOrder() {
        XCTAssertTrue(Updates.isNewer("0.2.0", than: "0.1.9"))
        XCTAssertTrue(Updates.isNewer("v0.10.0", than: "0.9.3"), "0.10 > 0.9 по числам, не по строке")
        XCTAssertFalse(Updates.isNewer("0.1.0", than: "0.1.0"), "равные")
        XCTAssertFalse(Updates.isNewer("0.1", than: "0.1.0"), "0.1 == 0.1.0")
        XCTAssertTrue(Updates.isNewer("1.0.0", than: "e119a6f"), "хеш сборки разработчика считается 0")
    }

    func testParseRelease() {
        let json = #"{"tag_name": "v0.3.0", "html_url": "https://github.com/x/y/releases/tag/v0.3.0", "draft": false}"#
        XCTAssertEqual(Updates.parseRelease(Data(json.utf8), current: "0.2.1"),
                       .init(version: "0.3.0", url: URL(string: "https://github.com/x/y/releases/tag/v0.3.0")!))
        XCTAssertNil(Updates.parseRelease(Data(json.utf8), current: "0.3.0"), "не новее")
        let draft = #"{"tag_name": "v9.0.0", "html_url": "https://x", "draft": true}"#
        XCTAssertNil(Updates.parseRelease(Data(draft.utf8), current: "0.1.0"), "черновик")
        XCTAssertNil(Updates.parseRelease(Data("{}".utf8), current: "0.1.0"))
    }
}
