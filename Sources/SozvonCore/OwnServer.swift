// The user's own optional server (docs/SERVER.md): address rules, the health check
// and the `bin/sync_server.py` result line (docs/CONTRACT.md).

import Foundation

public enum OwnServer {
    public static let protocolSchema = 1
    public static let docsURL = URL(string: "https://able1991.github.io/sozvon/docs.html#server")!
    /// Opens the "Add custom connector" dialog directly. No other query parameters: they break it.
    public static let claudeConnectorsURL = URL(string: "https://claude.ai/customize/connectors?modal=add-custom-connector")!
    public static let chatGPTConnectorsURL = URL(string: "https://chatgpt.com/#settings/Connectors")!

    /// https://host[/path] without a trailing slash. http only for localhost and 127.0.0.1 (testing).
    /// No credentials, query or fragment in the address. Anything else: nil.
    public static func normalize(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: text), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { return nil }
        guard scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1"].contains(host)) else { return nil }
        while c.path.hasSuffix("/") { c.path.removeLast() }
        return c.url
    }

    /// Both the address and the password are set and the address is valid.
    public static func isConfigured(url: String, password: String) -> Bool {
        normalize(url) != nil && !password.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public enum Health: Equatable, Sendable {
        case ok(version: String)
        case failed(String)
    }

    /// Reply of `GET /api/health`: `{"ok": true, "version": "...", "schema": 1}`.
    public static func health(status: Int, body: Data) -> Health {
        guard status == 200 else { return .failed(L("Сервер ответил кодом %@", status)) }
        guard let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any], j["ok"] as? Bool == true else {
            return .failed(L("Это не сервер Sozvon: проверь адрес"))
        }
        guard j["schema"] as? Int == protocolSchema else {
            return .failed(L("Несовместимая версия сервера, обнови его"))
        }
        return .ok(version: j["version"] as? String ?? "")
    }

    /// GET /api/health with a 10 s timeout, off the main thread.
    public static func checkHealth(_ url: URL) async -> Health {
        var req = URLRequest(url: url.appendingPathComponent("api/health"))
        req.timeoutInterval = 10
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, resp) = try await session.data(for: req)
            return health(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            return .failed(L("Сервер недоступен: %@", error.localizedDescription))
        }
    }

    /// The password is right: `GET /api/calls` answers 200 (a wrong one waits a second on the server).
    public static func accepts(_ url: URL, password: String) async -> Bool {
        var req = URLRequest(url: url.appendingPathComponent("api/calls"))
        req.timeoutInterval = 10
        req.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Last line of `bin/sync_server.py`: `RESULT: ok <sent> <deleted> <downloaded> <trashed> <failed>` or
    /// `RESULT: error <code> <message>`. Older engines printed fewer numbers (`<sent> <deleted>` before
    /// downloads, no `<trashed>` before call tombstones, no `<failed>` before per-call upload errors).
    public enum SyncResult: Equatable, Sendable {
        case ok(sent: Int, deleted: Int, downloaded: Int, trashed: Int, failed: Int)
        case failed(code: Int32?, message: String)
    }

    public static func parseSyncResult(_ line: String) -> SyncResult? {
        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = l.split(separator: " ")
        if (4...8).contains(parts.count), parts[0] == "RESULT:", parts[1] == "ok" {
            let n = parts.dropFirst(2).compactMap { Int($0) }
            guard n.count == parts.count - 2 else { return nil }
            func at(_ i: Int) -> Int { n.count > i ? n[i] : 0 }
            return .ok(sent: n[0], deleted: n[1], downloaded: at(2), trashed: at(3), failed: at(4))
        }
        guard let r = RunOutcome.parseLine(l), !r.ok else { return nil }
        return .failed(code: r.code, message: r.message)
    }

    /// The status line after a sync: "Синхронизировано 10:42: скачано 12 звонков, отправлено 3".
    /// Calls that did not upload: ". Не отправились: 2 звонка" at the end.
    public static func syncSummary(sent: Int, deleted: Int, downloaded: Int, trashed: Int = 0, failed: Int = 0, time: String,
                                   language: String = Engine.uiLanguage) -> String {
        var parts: [String] = []
        if downloaded > 0 { parts.append(L("скачано %@", callsCount(downloaded, language: language))) }
        parts.append(L("отправлено %@", sent))
        if deleted > 0 { parts.append(L("удалено %@", deleted)) }
        // Deleted on another Mac: the copies here went to the Trash.
        if trashed > 0 { parts.append(L("убрано в Корзину %@", callsCount(trashed, language: language))) }
        var text = L("Синхронизировано %@", time) + ": " + parts.joined(separator: ", ")
        if failed > 0 { text += ". " + L("Не отправились: %@", callsCount(failed, language: language)) }
        return text
    }

    /// "1 звонок", "3 звонка", "12 звонков"; "1 call", "12 calls".
    public static func callsCount(_ n: Int, language: String) -> String {
        // l10n-ignore-start: plural forms are chosen here, not by a strings key
        if language == "en" { return n == 1 ? "1 call" : "\(n) calls" }
        let tens = n % 100, ones = n % 10
        let word = (11...14).contains(tens) ? "звонков" : ones == 1 ? "звонок" : (2...4).contains(ones) ? "звонка" : "звонков"
        // l10n-ignore-end
        return "\(n) \(word)"
    }
}
