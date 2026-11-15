// OpenCode has an `mcp add` command, but no `mcp remove`, its list reads a stale copy from the background
// service, and the config is pure JSON anyway: so the Sozvon entry is edited directly in
// ~/.config/opencode/opencode.json ("mcp"."servers"), through the shared JSON editor (JSONMCPServers),
// and the CLI is told to reload it.
//
// The entry is what `opencode mcp add` itself writes: {"type": "remote", "url": …, "headers": …}.

import Foundation

public enum OpenCodeMCPConfig {
    // MARK: Public API

    /// Whether `mcp.servers.<name>` points at `url` (and, when `token` is given, sends `Bearer <token>`).
    public static func hasServer(_ text: String, name: String, url: String, token: String? = nil) -> Bool {
        JSONMCPServers.hasServer(text, name: name, url: url, token: token)
    }

    /// Whether there is any `mcp.servers.<name>` entry, whatever it points at.
    public static func hasEntry(_ text: String, name: String) -> Bool {
        JSONMCPServers.hasEntry(text, name: name)
    }

    /// Adds or updates `"name": {"type": "remote", "url": …, "headers": …}` in `mcp.servers`; the rest of
    /// the document is kept. nil: the text isn't JSON we can edit safely.
    public static func upsert(_ text: String, name: String, url: String, token: String) -> String? {
        JSONMCPServers.upsert(text, name: name, url: url, token: token, entry: ["type": "remote"])
    }

    /// Removes the `mcp.servers.<name>` entry. No entry: the text comes back unchanged. nil: can't parse.
    public static func remove(_ text: String, name: String) -> String? {
        JSONMCPServers.remove(text, name: name)
    }
}
