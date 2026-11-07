import Foundation
import XCTest
@testable import SozvonCore

final class CursorMCPConfigTests: XCTestCase {
    let url = "http://127.0.0.1:47816/mcp"

    private func upsert(_ text: String, token: String = "T") -> String? {
        CursorMCPConfig.upsert(text, name: "sozvon", url: url, token: token)
    }

    private func has(_ text: String, token: String? = "T") -> Bool {
        CursorMCPConfig.hasServer(text, name: "sozvon", url: url, token: token)
    }

    /// The edited text must still be valid JSON once comments are stripped (checked with our own parser
    /// and, for comment-free output, with JSONSerialization).
    private func servers(_ text: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        return try XCTUnwrap(obj?["mcpServers"] as? [String: Any])
    }

    func testEmptyOrMissingFileGetsNewDocument() throws {
        let out = try XCTUnwrap(upsert(""))
        XCTAssertEqual(out, """
        {
          "mcpServers": {
            "sozvon": {
              "url": "\(url)",
              "headers": {
                "Authorization": "Bearer T"
              }
            }
          }
        }

        """)
        XCTAssertTrue(has(out))
        let entry = try XCTUnwrap(try servers(out)["sozvon"] as? [String: Any])
        XCTAssertEqual(entry["url"] as? String, url)
        XCTAssertNotNil(upsert("  \n"), "только пробелы")
        let commentsOnly = try XCTUnwrap(upsert("// my servers\n"))
        XCTAssertTrue(commentsOnly.hasPrefix("// my servers\n{") && has(commentsOnly))
    }

    func testValidJSONKeepsOtherServersAndAddsFirst() throws {
        let text = """
        {
          "mcpServers": {
            "github": {
              "url": "https://example.com/mcp",
              "headers": {"Authorization": "Bearer gh"}
            }
          },
          "other": [1, 2.5, true, null]
        }
        """
        let out = try XCTUnwrap(upsert(text))
        XCTAssertTrue(has(out))
        let s = try servers(out)
        XCTAssertEqual(Set(s.keys), ["sozvon", "github"])
        let sozvonAt = try XCTUnwrap(out.range(of: "\"sozvon\"")).lowerBound
        let githubAt = try XCTUnwrap(out.range(of: "\"github\"")).lowerBound
        XCTAssertLessThan(sozvonAt, githubAt, "первым в mcpServers")
        XCTAssertTrue(out.contains("    \"sozvon\": {\n      \"url\""), "отступ как у соседей")
        XCTAssertTrue(out.hasSuffix("  },\n  \"other\": [1, 2.5, true, null]\n}"), "хвост файла не тронут")
    }

    func testTopObjectWithoutServersGetsThem() throws {
        let out = try XCTUnwrap(upsert("{\n  \"theme\": \"dark\"\n}\n"))
        XCTAssertTrue(has(out))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(obj["theme"] as? String, "dark")
        XCTAssertTrue(has(try XCTUnwrap(upsert("{}"))))
        XCTAssertTrue(has(try XCTUnwrap(upsert("{\"mcpServers\": {}}"))))
        XCTAssertTrue(has(try XCTUnwrap(upsert(#"{"mcpServers":{"a":{"url":"x"}}}"#))), "в одну строку")
    }

    func testJSONCWithCommentsAndTrailingCommas() throws {
        let text = """
        // Cursor MCP servers
        {
          /* block comment with "quotes" and { braces } */
          "mcpServers": {
            // "sozvon": {"url": "http://old"},
            "linear": {
              "url": "https://mcp.linear.app/sse", // trailing comment
            },
          },
        }
        """
        XCTAssertFalse(CursorMCPConfig.hasEntry(text, name: "sozvon"), "закомментированная запись не считается")
        let out = try XCTUnwrap(upsert(text))
        XCTAssertTrue(has(out))
        for kept in ["// Cursor MCP servers", "/* block comment with \"quotes\" and { braces } */",
                     "// \"sozvon\": {\"url\": \"http://old\"},", "\"url\": \"https://mcp.linear.app/sse\", // trailing comment"] {
            XCTAssertTrue(out.contains(kept), kept)
        }
        let back = try XCTUnwrap(CursorMCPConfig.remove(out, name: "sozvon"))
        XCTAssertEqual(back, text, "удаление возвращает файл как был")
    }

    func testExistingEntryUpdatedInPlace() throws {
        let text = """
        {
          "mcpServers": {
            "a": {"url": "https://a"},
            "sozvon": {
              "url": "http://127.0.0.1:9999/mcp"
            },
            "b": {"url": "https://b"}
          }
        }
        """
        XCTAssertTrue(CursorMCPConfig.hasEntry(text, name: "sozvon"))
        XCTAssertFalse(has(text, token: nil), "другой порт")
        let out = try XCTUnwrap(upsert(text, token: "NEW"))
        XCTAssertTrue(has(out, token: "NEW") && !has(out, token: "OLD"))
        XCTAssertFalse(out.contains("9999"))
        XCTAssertEqual(out.components(separatedBy: "\"sozvon\"").count, 2, "одна запись")
        let a = try XCTUnwrap(out.range(of: "\"a\"")).lowerBound
        let s = try XCTUnwrap(out.range(of: "\"sozvon\"")).lowerBound
        XCTAssertLessThan(a, s, "на своём месте")
        XCTAssertEqual(upsert(out, token: "NEW"), out, "повторное подключение ничего не меняет")
        XCTAssertEqual(Set(try servers(out).keys), ["a", "sozvon", "b"])
    }

    func testOldTokenIsNotConnected() throws {
        let out = try XCTUnwrap(upsert("", token: "OLD"))
        XCTAssertTrue(has(out, token: "OLD"))
        XCTAssertFalse(has(out, token: "NEW"))
        XCTAssertTrue(has(out, token: nil))
    }

    func testDuplicateEntriesCollapse() throws {
        let text = "{\n  \"mcpServers\": {\n    \"sozvon\": {\"url\": \"x\"},\n    \"k\": {},\n    \"sozvon\": {\"url\": \"y\"}\n  }\n}\n"
        let out = try XCTUnwrap(upsert(text))
        XCTAssertEqual(out.components(separatedBy: "\"sozvon\"").count, 2)
        XCTAssertTrue(has(out))
        XCTAssertEqual(Set(try servers(out).keys), ["sozvon", "k"])
    }

    func testRemoveKeepsOtherServersAndComments() throws {
        let text = """
        {
          "mcpServers": {
            // keep me
            "a": {"url": "https://a"},
            "sozvon": {"url": "\(url)", "headers": {"Authorization": "Bearer T"}}
          }
        }
        """
        let out = try XCTUnwrap(CursorMCPConfig.remove(text, name: "sozvon"))
        XCTAssertEqual(out, "{\n  \"mcpServers\": {\n    // keep me\n    \"a\": {\"url\": \"https://a\"}\n  }\n}")
        let first = "{\"mcpServers\": {\"sozvon\": {\"url\": \"u\"}, \"a\": {}}}"
        XCTAssertEqual(CursorMCPConfig.remove(first, name: "sozvon"), "{\"mcpServers\": {\"a\": {}}}")
        let only = try XCTUnwrap(CursorMCPConfig.remove(try XCTUnwrap(upsert("")), name: "sozvon"))
        XCTAssertEqual(try servers(only).count, 0)
        XCTAssertEqual(CursorMCPConfig.remove("{\"x\": 1}", name: "sozvon"), "{\"x\": 1}", "нечего удалять")
        XCTAssertEqual(CursorMCPConfig.remove("", name: "sozvon"), "")
    }

    func testMalformedTextReturnsNil() {
        for bad in ["{", "{\"mcpServers\": {\"a\": 1}", "[1, 2]", "{\"mcpServers\": []}", "{\"a\" 1}",
                    "{\"a\": \"unterminated}", "/* open comment {}", "{} {}", "{\"a\": tru}",
                    "{\"mcpServers\": {}, \"mcpServers\": {}}"] {
            XCTAssertNil(upsert(bad), bad)
            XCTAssertFalse(has(bad), bad)
        }
        XCTAssertNil(CursorMCPConfig.remove("{\"mcpServers\": {", name: "sozvon"))
    }

    func testSnippetCarriesThePassword() {
        let s = MCP.manualSetup(.cursor, token: "T0K")
        XCTAssertTrue(s.hasPrefix("// Add to \"mcpServers\" in ~/.cursor/mcp.json"))
        XCTAssertTrue(s.contains("\"sozvon\": {\n  \"url\": \"\(url)\"") && s.contains("\"Authorization\": \"Bearer T0K\""))
    }
}

final class CursorMCPFileTests: TempDirTestCase {
    func testConnectCreatesFolderAndPrivateFileThenDisconnects() throws {
        let f = tmp.appendingPathComponent("home/.cursor/mcp.json")
        XCTAssertEqual(MCP.cursorConnection(file: f, token: "T"), .none)
        XCTAssertTrue(MCP.cursorConnect(file: f, token: "T").0)
        let perm = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perm.intValue, 0o600, "в файле пароль")
        XCTAssertEqual(MCP.cursorConnection(file: f, token: "T"), .connected)
        XCTAssertEqual(MCP.cursorConnection(file: f, token: "OTHER"), .outdated)
        XCTAssertTrue(MCP.cursorDisconnect(file: f).0)
        XCTAssertEqual(MCP.cursorConnection(file: f, token: "T"), .none)
    }

    func testConnectKeepsPermissionsAndRefusesBadFile() throws {
        let f = tmp.appendingPathComponent(".cursor/mcp.json")
        try write("{\n  // mine\n  \"mcpServers\": {}\n}\n", f)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: f.path)
        XCTAssertTrue(MCP.cursorConnect(file: f, token: "T").0)
        let perm = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perm.intValue, 0o640)
        XCTAssertTrue(try String(contentsOf: f, encoding: .utf8).contains("// mine"))

        try write("{ broken", f)
        let (ok, msg) = MCP.cursorConnect(file: f, token: "T")
        XCTAssertFalse(ok)
        XCTAssertFalse(msg.isEmpty)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "{ broken", "файл не тронут")
    }
}
