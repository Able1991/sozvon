// Cursor has no `mcp add` command: MCP servers live in ~/.cursor/mcp.json, which is JSONC in practice
// (people keep // comments in it). So the Sozvon entry is edited as text: everything else in the file,
// comments, other servers and formatting, stays byte for byte (JSONCEditor). Anything we can't parse
// safely gives nil, and the app offers the Copy button instead of touching the file.

import Foundation

public enum CursorMCPConfig {
    // MARK: Public API

    /// Whether `mcpServers.<name>` points at `url` (and, when `token` is given, sends `Bearer <token>`).
    /// Commented-out entries don't count.
    public static func hasServer(_ text: String, name: String, url: String, token: String? = nil) -> Bool {
        guard let edit = JSONCEditor.Edit(text), let servers = edit.container(["mcpServers"]),
              let entry = servers.member(name), case .object = entry.value.kind else { return false }
        guard edit.string(entry.value.member("url")?.value) == url else { return false }
        guard let token else { return true }
        let headers = entry.value.member("headers")?.value
        return edit.string(headers?.member("Authorization")?.value) == "Bearer \(token)"
    }

    /// Whether there is any `mcpServers.<name>` entry, whatever it points at.
    public static func hasEntry(_ text: String, name: String) -> Bool {
        JSONCEditor.Edit(text).flatMap { $0.container(["mcpServers"]) }?.member(name) != nil
    }

    /// Adds or updates `"<name>": {"url": …, "headers": {"Authorization": "Bearer …"}}` in `mcpServers`.
    /// An existing entry is replaced in place (duplicates are removed); a new one becomes the first member.
    /// Empty text gives a new file; a top-level object without `mcpServers` gets one.
    /// nil: the text isn't JSON(C) we can edit safely.
    public static func upsert(_ text: String, name: String, url: String, token: String) -> String? {
        var edit = JSONCEditor.Edit(text)
        guard edit != nil else { return nil }
        let value = entry(url: url, token: token)
        guard edit!.upsert(name, value: value, path: ["mcpServers"]) else { return nil }
        return edit!.text
    }

    /// Removes every `mcpServers.<name>` entry. No entry: the text comes back unchanged. nil: can't parse.
    public static func remove(_ text: String, name: String) -> String? {
        guard var edit = JSONCEditor.Edit(text) else { return nil }
        guard edit.remove(name, path: ["mcpServers"]) else { return nil }
        return edit.text
    }

    /// The block to paste by hand (the Copy button), with a hint where it goes.
    public static func snippet(name: String, url: String, token: String) -> String {
        return "// Add to \"mcpServers\" in ~/.cursor/mcp.json (Cursor and Cursor CLI both read it):\n"
            + JSONCEditor.quote(name) + ": " + JSONCEditor.render(entry(url: url, token: token), indent: "", unit: "  ")
    }

    // MARK: Entry

    static func entry(url: String, token: String) -> JSONCEditor.Value {
        .object([("url", .string(url)),
                 ("headers", .object([("Authorization", .string("Bearer \(token)"))]))])
    }
}
