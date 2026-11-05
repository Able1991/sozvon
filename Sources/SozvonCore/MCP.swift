// MCP: Sozvon as a tool for Claude Code and Codex. One shared engine server on 127.0.0.1
// (the app keeps it running), and the assistant CLIs connect to it with a password.

import Foundation
import os
import Security

public enum MCP {
    public static let name = "sozvon"
    public static let port = 47816
    public static var url: String { "http://127.0.0.1:\(port)/mcp" }

    private static let tokenCache = OSAllocatedUnfairLock<(path: String, token: String)?>(initialState: nil)

    /// Server password (bearer token): random, created once, stored in `.mcp-token` with mode 600.
    /// Without it neither a localhost web page nor another program can reach the server.
    /// Read from disk once per data folder.
    public static var token: String { token(in: Paths.data) }

    public static func token(in data: URL) -> String {
        let f = data.appendingPathComponent(".mcp-token")
        return tokenCache.withLock { cache in
            if let cache, cache.path == f.path { return cache.token }
            let t: String
            if let saved = try? String(contentsOf: f, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               saved.count >= 32 {
                t = saved
            } else {
                var bytes = [UInt8](repeating: 0, count: 32)
                _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                t = bytes.map { String(format: "%02x", $0) }.joined()
                try? PrivateFile.write(Data(t.utf8), to: f)
            }
            cache = (f.path, t)
            return t
        }
    }

    /// Codex can't set a header in `mcp add` for HTTP, so we add it to the `[mcp_servers.sozvon]` section
    /// of ~/.codex/config.toml (an old http_headers is replaced). No section: nil.
    public static func codexConfig(_ text: String, token: String, server: String = name) -> String? {
        guard let r = text.range(of: "[mcp_servers.\(server)]") else { return nil }
        let line = "http_headers = { \"Authorization\" = \"Bearer \(token)\" }"
        let sectionEnd = text[r.upperBound...].range(of: "\n[")?.lowerBound ?? text.endIndex
        let section = String(text[r.upperBound..<sectionEnd])
        let cleaned = section.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("http_headers") }
            .joined(separator: "\n")
        var out = text
        out.replaceSubrange(r.upperBound..<sectionEnd, with: "\n" + line + cleaned)
        return out
    }

    private static var cliEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (Assistant.searchDirs + ["/usr/bin", "/bin"]).joined(separator: ":")
        return env
    }

    private static func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        ProcessRunner.capture(exe, args, environment: cliEnvironment)
    }

    /// Whether Sozvon is connected in this CLI. Runs the CLI: don't call from the main thread.
    public static func isConnected(_ a: Assistant) -> Bool {
        guard let exe = a.cliPath else { return false }
        return run(exe, ["mcp", "get", name]).0 == 0
    }

    /// Connect: the CLI talks to Sozvon's shared server at a local address instead of starting
    /// its own copy in every session (a copy per session ate memory). Don't call from the main thread.
    public static func connect(_ a: Assistant) -> (Bool, String) {
        guard let exe = a.cliPath else { return (false, L("Не найден %@", a.title)) }
        let token = self.token
        let args: [String] = a == .claude
            // --header goes last: the option is greedy and would otherwise swallow the name and URL
            ? ["mcp", "add", "--scope", "user", "--transport", "http", name, url, "--header", "Authorization: Bearer \(token)"]
            : ["mcp", "add", name, "--url", url]
        _ = run(exe, ["mcp", "remove", name] + (a == .claude ? ["--scope", "user"] : []))
        let r = run(exe, args)
        if a == .codex && r.0 == 0 {
            let f = Paths.home.appendingPathComponent(".codex/config.toml")
            if let text = try? String(contentsOf: f, encoding: .utf8), let edited = codexConfig(text, token: token) {
                try? edited.write(to: f, atomically: true, encoding: .utf8)
            }
        }
        return (r.0 == 0, r.1.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func disconnect(_ a: Assistant) {
        guard let exe = a.cliPath else { return }
        _ = run(exe, ["mcp", "remove", name] + (a == .claude ? ["--scope", "user"] : []))
    }
}

/// Check the shared MCP server: an authenticated POST to 127.0.0.1:<port>/mcp.
public enum MCPHealth: Equatable, Sendable {
    case listening
    case notListening
    case unauthorized
    case unexpected(Int)
    case error(String)

    public static func classify(statusCode: Int?, error: URLError.Code?) -> MCPHealth {
        if let statusCode {
            switch statusCode {
            case 200..<300: return .listening
            case 401, 403: return .unauthorized
            default: return .unexpected(statusCode)
            }
        }
        switch error {
        case .cannotConnectToHost?, .cannotFindHost?, .networkConnectionLost?, .timedOut?: return .notListening
        case let code?: return .error("URLError \(code.rawValue)")
        case nil: return .notListening
        }
    }

    public static func probe(port: Int = MCP.port, token: String = MCP.token) async -> MCPHealth {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"sozvon-health","version":"1"}}}"#
        req.httpBody = Data(body.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, resp) = try await session.data(for: req)
            return classify(statusCode: (resp as? HTTPURLResponse)?.statusCode, error: nil)
        } catch let e as URLError {
            return classify(statusCode: nil, error: e.code)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    public var title: String {
        switch self {
        case .listening: return L("работает")
        case .notListening: return L("не отвечает")
        case .unauthorized: return L("не принял пароль")
        case .unexpected(let c): return L("ответил кодом %@", c)
        case .error(let m): return m
        }
    }
}
