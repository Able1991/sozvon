// Shared editor for the CLI configs that keep MCP servers in "mcp"."servers" of a JSON document the CLI
// rewrites itself (ZCode: ~/.zcode/cli/config.json, OpenCode: ~/.config/opencode/opencode.json). Unlike
// Cursor's file these are pure JSON (no comments to keep), so the entry is edited with a whole-document
// round trip: parsed, changed, serialized back. Anything that fails to parse gives nil, and the app offers
// the Copy button instead of touching the file.

import Foundation

enum JSONMCPServers {
    /// Parsed JSON object; an empty or missing document counts as `{}`.
    static func document(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func server(_ text: String, _ name: String) -> Any? {
        guard let doc = document(text),
              let mcp = doc["mcp"] as? [String: Any],
              let servers = mcp["servers"] as? [String: Any] else { return nil }
        return servers[name]
    }

    /// Whether `mcp.servers.<name>` points at `url` (and, when `token` is given, sends `Bearer <token>`).
    static func hasServer(_ text: String, name: String, url: String, token: String?) -> Bool {
        guard let entry = server(text, name) as? [String: Any] else { return false }
        guard entry["url"] as? String == url else { return false }
        guard let token else { return true }
        let headers = entry["headers"] as? [String: Any]
        return headers?["Authorization"] as? String == "Bearer \(token)"
    }

    static func hasEntry(_ text: String, name: String) -> Bool {
        server(text, name) != nil
    }

    /// Adds or updates the entry in `mcp.servers`; the rest of the document (other servers, everything else)
    /// is kept. An existing "mcp" or "servers" that isn't an object refuses the edit (nil).
    static func upsert(_ text: String, name: String, url: String, token: String, entry: [String: Any]) -> String? {
        guard var doc = document(text) else { return nil }
        if let mcp = doc["mcp"], !(mcp is [String: Any]) { return nil }
        if let mcp = doc["mcp"] as? [String: Any], let servers = mcp["servers"], !(servers is [String: Any]) { return nil }
        var mcp = doc["mcp"] as? [String: Any] ?? [:]
        var servers = mcp["servers"] as? [String: Any] ?? [:]
        var full = entry
        full["url"] = url
        full["headers"] = ["Authorization": "Bearer \(token)"]
        servers[name] = full
        mcp["servers"] = servers
        doc["mcp"] = mcp
        return render(doc)
    }

    /// Removes the `mcp.servers.<name>` entry. No entry: the text comes back unchanged. nil: can't parse.
    static func remove(_ text: String, name: String) -> String? {
        guard var doc = document(text) else { return nil }
        guard var mcp = doc["mcp"] as? [String: Any],
              var servers = mcp["servers"] as? [String: Any] else { return text }
        guard servers.removeValue(forKey: name) != nil else { return text }
        mcp["servers"] = servers
        doc["mcp"] = mcp
        return render(doc)
    }

    static func render(_ doc: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(doc),
              let data = try? JSONSerialization.data(withJSONObject: doc,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
