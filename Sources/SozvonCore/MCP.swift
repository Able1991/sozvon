// MCP: Sozvon as a tool for Claude Code, Codex and Cursor. One shared engine server on 127.0.0.1
// (the app keeps it running), and the assistants connect to it with a password. Claude Code and Codex
// are set up through their CLIs; Cursor has no `mcp add`, so its ~/.cursor/mcp.json is edited directly.

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

    /// How Sozvon is registered in an assistant's CLI.
    public enum Connection: Equatable, Sendable {
        case none
        /// Points at the shared server with the password header.
        case connected
        /// Registered, but in an older way (its own server copy per session, another port, no password):
        /// Connect again to fix it.
        case outdated
    }

    /// Reads `<cli> mcp get sozvon`: its exit code and output (Claude prints `URL: …` and `Headers:`,
    /// Codex prints `url: …` and `http_headers: …`, `-` when unset).
    public static func connection(exitCode: Int32, output: String, url: String = MCP.url) -> Connection {
        guard exitCode == 0 else { return .none }
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let pointsHere = lines.contains { $0.lowercased().hasPrefix("url:") && $0.hasSuffix(url) }
        let codexHeaders = lines.first { $0.hasPrefix("http_headers:") }
        let hasPassword = codexHeaders.map { !$0.hasSuffix("-") } ?? output.contains("Authorization")
        return pointsHere && hasPassword ? .connected : .outdated
    }

    /// Whether and how Sozvon is connected in this CLI. Runs the CLI: don't call from the main thread.
    public static func connection(_ a: Assistant) -> Connection {
        if a == .cursor { return cursorConnection() }
        guard let exe = a.cliPath else { return .none }
        let (code, out) = run(exe, ["mcp", "get", name])
        return connection(exitCode: code, output: out)
    }

    /// Connect: the CLI talks to Sozvon's shared server at a local address instead of starting
    /// its own copy in every session (a copy per session ate memory). Don't call from the main thread.
    public static func connect(_ a: Assistant) -> (Bool, String) {
        if a == .cursor { return cursorConnect() }
        guard let exe = a.cliPath else { return (false, L("Не найден %@", a.title)) }
        let token = self.token
        let args: [String] = a == .claude
            // --header goes last: the option is greedy and would otherwise swallow the name and URL.
            // The password is an argument here, so another account on this Mac could see it in `ps` for the
            // moment the command runs: `claude mcp add` and `add-json` take a header no other way (no stdin,
            // no file, no environment variable), and Claude Code's own config is not ours to edit.
            ? ["mcp", "add", "--scope", "user", "--transport", "http", name, url, "--header", "Authorization: Bearer \(token)"]
            : ["mcp", "add", name, "--url", url]
        _ = run(exe, ["mcp", "remove", name] + (a == .claude ? ["--scope", "user"] : []))
        let r = run(exe, args)
        if a == .codex && r.0 == 0 { codexWriteToken(token) }
        return (r.0 == 0, r.1.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Puts the password header into the Sozvon section of ~/.codex/config.toml, keeping everything else in the
    /// file. Written atomically with mode 600: from now on the file holds the password. -> false when there is
    /// no file or no Sozvon section (nothing is written).
    @discardableResult
    static func codexWriteToken(_ token: String, file: URL = Paths.home.appendingPathComponent(".codex/config.toml")) -> Bool {
        let target = file.resolvingSymlinksInPath()
        guard let text = try? String(contentsOf: target, encoding: .utf8), let edited = codexConfig(text, token: token) else {
            return false
        }
        return (try? PrivateFile.write(Data(edited.utf8), to: target)) != nil
    }

    /// What Connect does, as text to paste into a terminal (the "Copy command" button).
    /// Contains the password, so it only goes to the clipboard on the user's request.
    public static func manualSetup(_ a: Assistant, token: String = MCP.token) -> String {
        switch a {
        case .claude:
            return "claude mcp add --scope user --transport http \(name) \(url) --header 'Authorization: Bearer \(token)'"
        case .codex:
            return """
            codex mcp add \(name) --url \(url)
            # then add this line to the [mcp_servers.\(name)] section of ~/.codex/config.toml:
            # http_headers = { "Authorization" = "Bearer \(token)" }
            """
        case .cursor:
            return CursorMCPConfig.snippet(name: name, url: url, token: token)
        case .none:
            return "\(url)\nAuthorization: Bearer \(token)"
        }
    }

    public static func disconnect(_ a: Assistant) {
        if a == .cursor { _ = cursorDisconnect(); return }
        guard let exe = a.cliPath else { return }
        _ = run(exe, ["mcp", "remove", name] + (a == .claude ? ["--scope", "user"] : []))
    }

    /// Whether there is something to connect: the CLI, or for Cursor also the app or its ~/.cursor folder
    /// (the Cursor app and Cursor CLI read the same ~/.cursor/mcp.json).
    public static func isInstalled(_ a: Assistant) -> Bool {
        guard a == .cursor else { return a.cliPath != nil }
        let fm = FileManager.default
        return a.cliPath != nil || fm.fileExists(atPath: cursorDir.path)
            || ["/Applications/Cursor.app", "\(Paths.home.path)/Applications/Cursor.app"].contains { fm.fileExists(atPath: $0) }
    }

    // MARK: Cursor (~/.cursor/mcp.json)

    public static var cursorDir: URL { Paths.home.appendingPathComponent(".cursor") }
    public static var cursorConfig: URL { cursorDir.appendingPathComponent("mcp.json") }

    public static func cursorConnection(file: URL = cursorConfig, token: String = MCP.token) -> Connection {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .none }
        if CursorMCPConfig.hasServer(text, name: name, url: url, token: token) { return .connected }
        return CursorMCPConfig.hasEntry(text, name: name) ? .outdated : .none
    }

    /// Adds or updates the Sozvon entry, keeping comments and other servers. Creates the file
    /// (mode 600: it holds the password) and ~/.cursor if missing.
    public static func cursorConnect(file: URL = cursorConfig, token: String = MCP.token) -> (Bool, String) {
        let fm = FileManager.default
        let target = file.resolvingSymlinksInPath()
        let exists = fm.fileExists(atPath: target.path)
        let text: String
        if exists {
            guard let t = try? String(contentsOf: target, encoding: .utf8) else { return (false, cursorManualHint) }
            text = t
        } else {
            text = ""
        }
        guard let edited = CursorMCPConfig.upsert(text, name: name, url: url, token: token) else {
            return (false, cursorManualHint)
        }
        if edited == text { return (true, "") }
        do {
            try writeKeepingPermissions(edited, to: target)
            return (true, "")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Removes the Sozvon entry. Missing file or no entry: nothing to do.
    @discardableResult
    public static func cursorDisconnect(file: URL = cursorConfig) -> (Bool, String) {
        let target = file.resolvingSymlinksInPath()
        guard let text = try? String(contentsOf: target, encoding: .utf8) else { return (true, "") }
        guard let edited = CursorMCPConfig.remove(text, name: name) else { return (false, cursorManualHint) }
        if edited == text { return (true, "") }
        do {
            try writeKeepingPermissions(edited, to: target)
            return (true, "")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private static var cursorManualHint: String {
        L("Не получилось разобрать ~/.cursor/mcp.json. Добавь Sozvon вручную: кнопка «Скопировать» ниже.")
    }

    /// Atomic write (a temp file alongside, then rename) with the old file's permissions; a new file gets 600.
    static func writeKeepingPermissions(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.int16Value
        try PrivateFile.write(Data(text.utf8), to: url)
        if let mode, mode != 0o600 {
            try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
        }
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
