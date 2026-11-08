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
        // Nothing listens on port 1 on localhost: connection refused.
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

    func testUpdatedFrom() {
        let d = UserDefaults(suiteName: "sozvon-tests-updates")!
        d.removePersistentDomain(forName: "sozvon-tests-updates")
        XCTAssertNil(Updates.updatedFrom(current: "0.1.1", defaults: d), "первый запуск")
        XCTAssertNil(Updates.updatedFrom(current: "0.1.1", defaults: d), "та же версия")
        XCTAssertEqual(Updates.updatedFrom(current: "0.1.2", defaults: d), "0.1.1")
        XCTAssertNil(Updates.updatedFrom(current: "0.1.2", defaults: d), "сказали один раз")
        XCTAssertNil(Updates.updatedFrom(current: "0.1.0", defaults: d), "откат на старую сборку")
        d.removePersistentDomain(forName: "sozvon-tests-updates")
    }

    func testQuietMoment() {
        XCTAssertTrue(Updates.canInstallQuietly(.init()))
        for a: Updates.Activity in [.init(recording: true), .init(processing: true), .init(inCall: true),
                                    .init(windowOpen: true), .init(settingUp: true)] {
            XCTAssertFalse(Updates.canInstallQuietly(a), "\(a)")
        }
        XCTAssertTrue(Updates.canCheckNow(.init(inCall: true, windowOpen: true)), "окно настроек открыто, это нормально")
        XCTAssertFalse(Updates.canCheckNow(.init(recording: true)))
        XCTAssertFalse(Updates.canCheckNow(.init(processing: true)))
    }

    func testReleaseLinks() {
        XCTAssertEqual(Updates.notesURL("0.1.2").absoluteString, "https://github.com/Able1991/sozvon/releases/tag/v0.1.2")
    }

    func testManualSetupCarriesThePassword() {
        let claude = MCP.manualSetup(.claude, token: "T0K")
        XCTAssertTrue(claude.hasPrefix("claude mcp add --scope user --transport http sozvon http://127.0.0.1:47816/mcp"))
        XCTAssertTrue(claude.hasSuffix("--header 'Authorization: Bearer T0K'"), "header goes last")
        let codex = MCP.manualSetup(.codex, token: "T0K")
        XCTAssertTrue(codex.hasPrefix("codex mcp add sozvon --url http://127.0.0.1:47816/mcp\n"))
        XCTAssertTrue(codex.contains(#"http_headers = { "Authorization" = "Bearer T0K" }"#))
    }
}

final class MCPConnectionTests: XCTestCase {
    func testClaudeConnected() {
        let out = """
        sozvon:
          Scope: User config (available in all your projects)
          Type: http
          URL: \(MCP.url)
          Headers:
            Authorization: Bearer abc
        """
        XCTAssertEqual(MCP.connection(exitCode: 0, output: out), .connected)
    }

    func testCodexConnectedAndWithoutPassword() {
        let ok = "sozvon\n  enabled: true\n  url: \(MCP.url)\n  http_headers: Authorization=*****\n"
        XCTAssertEqual(MCP.connection(exitCode: 0, output: ok), .connected)
        let bare = "sozvon\n  enabled: true\n  url: \(MCP.url)\n  http_headers: -\n"
        XCTAssertEqual(MCP.connection(exitCode: 0, output: bare), .outdated, "без пароля сервер не пустит")
    }

    func testOldStdioSetupIsOutdated() {
        let out = "sozvon:\n  Type: stdio\n  Command: /Users/x/.venv/bin/python3\n  Args: server.py\n"
        XCTAssertEqual(MCP.connection(exitCode: 0, output: out), .outdated)
        XCTAssertEqual(MCP.connection(exitCode: 0, output: "URL: http://127.0.0.1:9999/mcp\nAuthorization: x"), .outdated,
                       "другой порт")
    }

    func testNotRegistered() {
        XCTAssertEqual(MCP.connection(exitCode: 1, output: "No MCP server found with name: sozvon"), .none)
    }
}
