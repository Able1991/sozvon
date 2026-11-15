// ZCode has no `mcp add` command: MCP servers live in "mcp"."servers" of ~/.zcode/cli/config.json.
// The entry is edited through the shared JSON editor (JSONMCPServers).
//
// protocolVersion "auto": the FastMCP server speaks an older protocol date than the ZCode client's newest,
// and "auto" lets the client agree on it (without the field the client refuses: "failed to negotiate").

import Foundation

public enum ZCodeMCPConfig {
    // MARK: Public API

    /// Whether `mcp.servers.<name>` points at `url` (and, when `token` is given, sends `Bearer <token>`).
    public static func hasServer(_ text: String, name: String, url: String, token: String? = nil) -> Bool {
        JSONMCPServers.hasServer(text, name: name, url: url, token: token)
    }

    /// Whether there is any `mcp.servers.<name>` entry, whatever it points at.
    public static func hasEntry(_ text: String, name: String) -> Bool {
        JSONMCPServers.hasEntry(text, name: name)
    }

    /// Adds or updates `"name": {"type": "http", …, "protocolVersion": "auto", "enabled": true}` in
    /// `mcp.servers`; the rest of the document is kept. nil: the text isn't JSON we can edit safely.
    public static func upsert(_ text: String, name: String, url: String, token: String) -> String? {
        JSONMCPServers.upsert(text, name: name, url: url, token: token,
                              entry: ["type": "http", "protocolVersion": "auto", "enabled": true])
    }

    /// Removes the `mcp.servers.<name>` entry. No entry: the text comes back unchanged. nil: can't parse.
    public static func remove(_ text: String, name: String) -> String? {
        JSONMCPServers.remove(text, name: name)
    }

    /// The block to paste by hand (the Copy button), with a hint where it goes.
    public static func snippet(name: String, url: String, token: String) -> String {
        """
        // Add to "mcp"."servers" in ~/.zcode/cli/config.json (the ZCode app reads it too):
        "\(name)": {
          "type": "http",
          "url": "\(url)",
          "headers": { "Authorization": "Bearer \(token)" },
          "protocolVersion": "auto",
          "enabled": true
        }
        """
    }
}
