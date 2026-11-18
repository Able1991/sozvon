// Shared editor for the CLI configs that keep MCP servers in "mcp"."servers" of a JSON document
// the CLI rewrites itself (ZCode: ~/.zcode/cli/config.json, OpenCode: ~/.config/opencode/opencode.json
// or opencode.jsonc). Like the Cursor editor the file is edited as text: comments, other servers,
// key order and number formatting stay byte for byte, so a jsonc file with comments and trailing
// commas is editable too. Anything that fails to parse gives nil, and the app offers the Copy
// button instead of touching the file.

import Foundation

enum JSONMCPServers {
    /// One entry field; url and headers are added by upsert.
    enum Field {
        case string(String)
        case bool(Bool)
    }

    // MARK: Public API

    /// Whether `mcp.servers.<name>` points at `url` (and, when `token` is given, sends `Bearer <token>`).
    static func hasServer(_ text: String, name: String, url: String, token: String?) -> Bool {
        guard let edit = JSONCEditor.Edit(text), let servers = edit.container(["mcp", "servers"]),
              let entry = servers.member(name), case .object = entry.value.kind else { return false }
        guard edit.string(entry.value.member("url")?.value) == url else { return false }
        guard let token else { return true }
        let headers = entry.value.member("headers")?.value
        return edit.string(headers?.member("Authorization")?.value) == "Bearer \(token)"
    }

    /// Whether there is any `mcp.servers.<name>` entry, whatever it points at.
    static func hasEntry(_ text: String, name: String) -> Bool {
        JSONCEditor.Edit(text).flatMap { $0.container(["mcp", "servers"]) }?.member(name) != nil
    }

    /// Adds or updates `"name": {fields…, "url": …, "headers": {"Authorization": "Bearer …"}}` in
    /// `mcp.servers` (creating `mcp` and `servers` when missing); the rest of the document is kept.
    /// An existing entry is replaced in place (duplicates are removed). nil: the text isn't JSON(C)
    /// we can edit safely.
    static func upsert(_ text: String, name: String, url: String, token: String, fields: [(String, Field)]) -> String? {
        guard var edit = JSONCEditor.Edit(text) else { return nil }
        var value: [(String, JSONCEditor.Value)] = fields.map { f in
            switch f.1 {
            case .string(let s): return (f.0, .string(s))
            case .bool(let b): return (f.0, .bool(b))
            }
        }
        value.append(("url", .string(url)))
        value.append(("headers", .object([("Authorization", .string("Bearer \(token)"))])))
        guard edit.upsert(name, value: .object(value), path: ["mcp", "servers"]) else { return nil }
        return edit.text
    }

    /// Removes the `mcp.servers.<name>` entry. No entry: the text comes back unchanged. nil: can't parse.
    static func remove(_ text: String, name: String) -> String? {
        guard var edit = JSONCEditor.Edit(text) else { return nil }
        guard edit.remove(name, path: ["mcp", "servers"]) else { return nil }
        return edit.text
    }
}
