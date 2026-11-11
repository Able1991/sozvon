// "Connect Cloudflare": one click from Settings to the user's own server (docs/SERVER.md).
// Sign-in through Cloudflare OAuth (Authorization Code + PKCE, a public client without a secret,
// redirect to a one-shot listener on 127.0.0.1), then the Cloudflare REST API creates or reuses
// the D1 database and the KV namespace, uploads the Worker bundled in the app and turns on workers.dev.
// The access token lives only in memory for this one run (the client has no refresh tokens).

import CryptoKit
import Foundation
import Network
import Security

public struct CloudflareError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - OAuth

public enum CloudflareOAuth {
    /// Public OAuth client "Sozvon" (publisher domain sozvon.ottkit.io). No secret: PKCE S256.
    public static let clientID = "f3e3629d54e6f828e18f190026554649"
    public static let port: UInt16 = 47817
    public static let callbackPath = "/oauth/callback"
    public static var redirectURI: String { "http://127.0.0.1:\(port)\(callbackPath)" }
    /// From https://dash.cloudflare.com/.well-known/openid-configuration.
    public static let authorizeEndpoint = URL(string: "https://dash.cloudflare.com/oauth2/auth")!
    public static let tokenEndpoint = URL(string: "https://dash.cloudflare.com/oauth2/token")!
    /// Exactly the scopes the client is registered with: Account Settings Read, D1 Write,
    /// Workers Editor, Workers KV Storage Write. No offline_access: the client may not ask for it.
    public static let scopes = ["account-settings.read", "d1.write", "workers-scripts.edit", "workers-scripts.admin", "workers-kv-storage.write"]

    public struct PKCE: Equatable, Sendable {
        public let verifier: String
        public let challenge: String

        public init(verifier: String) {
            self.verifier = verifier
            challenge = CloudflareOAuth.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        /// 32 random bytes: a 43-character verifier (RFC 7636 allows 43 to 128).
        public static func random() -> PKCE { PKCE(verifier: CloudflareOAuth.randomToken()) }
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func randomToken(bytes: Int = 32) -> String {
        base64url(Data(SecureRandom.bytes(bytes)))
    }

    public static func authorizeURL(pkce: PKCE, state: String) -> URL {
        var c = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        // URLComponents leaves "+" alone in queries; spaces become %20, which the server accepts.
        return c.url!
    }

    public enum Callback: Equatable, Sendable {
        /// The authorization code: sign-in finished.
        case code(String)
        /// Cloudflare reported an error (the user declined, a wrong scope): stop with this message.
        case failed(String)
        /// Not our callback, or a state that is not ours: answer and keep waiting.
        case ignore
    }

    /// Request target of the browser's GET (`/oauth/callback?code=…&state=…`).
    /// A request without our state is ignored, errors included, so another page cannot finish or break the sign-in.
    public static func parseCallback(target: String, state: String) -> Callback {
        // The redirect query is form-encoded: "+" is a space (a real plus arrives as %2B).
        let raw = target.replacingOccurrences(of: "+", with: "%20")
        guard let c = URLComponents(string: "http://127.0.0.1" + raw), c.path == callbackPath else { return .ignore }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard q["state"] == state else { return .ignore }
        if let error = q["error"] {
            if error == "access_denied" { return .failed(L("Доступ в Cloudflare не разрешён")) }
            let text = q["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? error
            return .failed(L("Cloudflare не пустил: %@", text))
        }
        guard let code = q["code"], !code.isEmpty else { return .ignore }
        return .code(code)
    }

    /// Request target from the head of an HTTP request (`GET /path?x HTTP/1.1`), GET only.
    public static func requestTarget(head: String) -> String? {
        guard let line = head.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/") else { return nil }
        return String(parts[1])
    }

    public static func httpResponse(status: Int, html: String) -> Data {
        let body = Data(html.utf8)
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// Small page in the browser after the redirect.
    /// Opens Sozvon's Cloud tab: macOS brings the app forward for its own URL scheme, which an app
    /// can't do for itself while the browser is active.
    public static let returnURL = "sozvon://settings/cloud"

    public static func page(_ title: String, _ text: String, returnTo: String? = nil) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let openApp = L("Открыть Sozvon")  // outside the template: tools/l10n.py does not see an L() inside \( )
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">\
        <title>Sozvon</title><style>body{font:16px -apple-system,system-ui,sans-serif;margin:0;display:flex;\
        min-height:100vh;align-items:center;justify-content:center;background:#f5f5f7;color:#1d1d1f}\
        @media(prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}}main{text-align:center;padding:24px}\
        h1{font-size:22px;margin:0 0 8px}p{margin:0;opacity:.7}</style></head>\
        \(returnTo.map { "<meta http-equiv=\"refresh\" content=\"0;url=\(esc($0))\">" } ?? "")\
        <body><main><h1>\(esc(title))</h1><p>\(esc(text))</p>\
        \(returnTo.map { "<p style=\"margin-top:16px\"><a href=\"\(esc($0))\">\(esc(openApp))</a></p>" } ?? "")\
        </main></body></html>
        """
    }

    public static func tokenRequest(code: String, verifier: String) -> URLRequest {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(CloudflareAPI.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        req.httpBody = Data(formEncode([
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
            ("client_id", clientID), ("code_verifier", verifier),
        ]).utf8)
        return req
    }

    public static func formEncode(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return items.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }

    /// Token endpoint reply: `{"access_token": "...", "token_type": "bearer", ...}` or `{"error": ...}`.
    public static func accessToken(status: Int, body: Data) throws -> String {
        let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if status == 200, let t = j?["access_token"] as? String, !t.isEmpty { return t }
        let detail = (j?["error_description"] as? String) ?? (j?["error"] as? String) ?? L("код %@", status)
        throw CloudflareError(L("Cloudflare не выдал доступ: %@", detail))
    }

    /// The whole sign-in: listener on 127.0.0.1, the browser, the code, the token. Timeout, then an error;
    /// cancelling the task stops the listener.
    public static func signIn(timeout: TimeInterval = 300, session: URLSession = .shared,
                              open: @escaping @Sendable (URL) -> Void) async throws -> String {
        let pkce = PKCE.random()
        let state = randomToken()
        let server = LoopbackServer(port: port, state: state)
        let code = try await server.waitForCode(timeout: timeout) { open(authorizeURL(pkce: pkce, state: state)) }
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: tokenRequest(code: code, verifier: pkce.verifier))
        } catch {
            // "Cancel" during the exchange: back to idle quietly, not "cancelled" as an error.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw CloudflareError(L("Нет связи с Cloudflare: %@", error.localizedDescription))
        }
        return try accessToken(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

enum SecureRandom {
    static func bytes(_ n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n)
        precondition(SecRandomCopyBytes(kSecRandomDefault, n, &b) == errSecSuccess, "no system randomness")
        return b
    }
}

/// Strong password for the server: letters and digits only (easy to paste into a connector login), 32 chars, about 190 bits.
public enum ServerPassword {
    public static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    /// The server refuses a shorter SOZVON_PASSWORD (server/src/auth.ts, MIN_PASSWORD_LENGTH).
    public static let minimumLength = 20

    public static func generate(length: Int = 32) -> String {
        var out = ""
        while out.count < length {
            for b in SecureRandom.bytes(length) where Int(b) < 248 && out.count < length {  // 248 = 62 * 4: no modulo bias
                out.append(alphabet[Int(b) % alphabet.count])
            }
        }
        return out
    }
}

// MARK: - One-shot local listener for the OAuth redirect

/// Listens on 127.0.0.1:<port> until the browser brings the code back (or timeout, or cancel).
/// All state lives on one serial queue.
final class LoopbackServer: @unchecked Sendable {
    private let port: UInt16
    private let state: String
    private let queue = DispatchQueue(label: "io.github.able1991.sozvon.oauth-loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var done = false
    private var cancelled = false

    init(port: UInt16, state: String) {
        self.port = port
        self.state = state
    }

    /// `ready` runs once the port is open (opens the browser).
    func waitForCode(timeout: TimeInterval, ready: @escaping @Sendable () -> Void) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                queue.async { self.start(c, timeout: timeout, ready: ready) }
            }
        } onCancel: {
            queue.async { self.cancelled = true; self.finish(.failure(CancellationError())) }
        }
    }

    private func start(_ c: CheckedContinuation<String, Error>, timeout: TimeInterval, ready: @escaping @Sendable () -> Void) {
        continuation = c
        if cancelled { finish(.failure(CancellationError())); return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            listener = l
            l.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                switch st {
                case .ready: ready()
                case .failed:
                    self.finish(.failure(CloudflareError(L("Порт %@ занят: закрой другое окно входа и попробуй ещё раз", self.port))))
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
            l.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(CloudflareError(L("Вход в Cloudflare не завершён за 5 минут"))))
            }
        } catch {
            finish(.failure(CloudflareError(L("Не открыть порт %@: %@", port, error.localizedDescription))))
        }
    }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, Data())
    }

    private func read(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(conn, head: String(decoding: buf[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || isComplete || buf.count > 64 * 1024 {
                conn.cancel()
            } else {
                self.read(conn, buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, head: String) {
        let result = CloudflareOAuth.requestTarget(head: head).map { CloudflareOAuth.parseCallback(target: $0, state: state) } ?? .ignore
        let reply: Data
        switch result {
        case .code:
            reply = CloudflareOAuth.httpResponse(status: 200, html: CloudflareOAuth.page(
                L("Готово, можно вернуться в Sozvon"), L("Sozvon настраивает сервер, это окно можно закрыть."),
                returnTo: CloudflareOAuth.returnURL))
        case .failed(let m):
            reply = CloudflareOAuth.httpResponse(status: 400, html: CloudflareOAuth.page(L("Не получилось"), m))
        case .ignore:
            reply = CloudflareOAuth.httpResponse(status: 404, html: CloudflareOAuth.page("Sozvon", ""))
        }
        conn.send(content: reply, completion: .contentProcessed { [weak self] _ in
            conn.cancel()
            switch result {
            case .code(let code): self?.finish(.success(code))
            case .failed(let m): self?.finish(.failure(CloudflareError(m)))
            case .ignore: break
            }
        })
    }

    /// Exactly once: resume the waiter and close the port.
    private func finish(_ r: Result<String, Error>) {
        guard !done, let c = continuation else { return }
        done = true
        continuation = nil
        listener?.cancel()
        listener = nil
        c.resume(with: r)
    }
}

// MARK: - Worker bundled in the app

/// `Contents/Resources/server/`: `worker.js` (one ES module built by build.sh from server/) and `manifest.json`.
public struct WorkerBundle: Sendable {
    public struct Manifest: Codable, Equatable, Sendable {
        public var version: String
        public var mainModule: String
        public var compatibilityDate: String
        public var compatibilityFlags: [String]

        enum CodingKeys: String, CodingKey {
            case version, mainModule = "main_module", compatibilityDate = "compatibility_date",
                 compatibilityFlags = "compatibility_flags"
        }

        public init(version: String, mainModule: String, compatibilityDate: String, compatibilityFlags: [String]) {
            self.version = version
            self.mainModule = mainModule
            self.compatibilityDate = compatibilityDate
            self.compatibilityFlags = compatibilityFlags
        }
    }

    public let manifest: Manifest
    public let script: Data

    public init(manifest: Manifest, script: Data) {
        self.manifest = manifest
        self.script = script
    }

    /// The bundle inside Sozvon.app, or nil (a build without Node.js, or `swift run`).
    public static var bundled: WorkerBundle? {
        Bundle.main.resourceURL.flatMap { load(from: $0.appendingPathComponent("server")) }
    }

    public static func load(from dir: URL) -> WorkerBundle? {
        guard let m = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: m),
              !manifest.mainModule.contains("/"),
              let script = try? Data(contentsOf: dir.appendingPathComponent(manifest.mainModule)), !script.isEmpty
        else { return nil }
        return WorkerBundle(manifest: manifest, script: script)
    }

    /// Metadata part of the script upload: the same settings as server/wrangler.jsonc, plus the password secret.
    public func metadata(databaseID: String, namespaceID: String, password: String) -> Data {
        let meta: [String: Any] = [
            "main_module": manifest.mainModule,
            "compatibility_date": manifest.compatibilityDate,
            "compatibility_flags": manifest.compatibilityFlags,
            "bindings": [
                ["type": "d1", "name": "DB", "id": databaseID],
                ["type": "kv_namespace", "name": "OAUTH_KV", "namespace_id": namespaceID],
                ["type": "secret_text", "name": "SOZVON_PASSWORD", "text": password],
            ],
            "observability": ["enabled": false],
        ]
        return try! JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
    }

    public func upload(databaseID: String, namespaceID: String, password: String, boundary: String? = nil) -> Multipart {
        var m = boundary.map { Multipart(boundary: $0) } ?? Multipart()
        m.add(name: "metadata", contentType: "application/json",
              data: metadata(databaseID: databaseID, namespaceID: namespaceID, password: password))
        m.add(name: manifest.mainModule, filename: manifest.mainModule, contentType: "application/javascript+module", data: script)
        return m
    }
}

public struct Multipart: Sendable {
    public struct Part: Sendable {
        public let name: String
        public let filename: String?
        public let contentType: String
        public let data: Data
    }

    public let boundary: String
    public private(set) var parts: [Part] = []

    public init(boundary: String = "sozvon-" + CloudflareOAuth.randomToken(bytes: 18)) { self.boundary = boundary }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func add(name: String, filename: String? = nil, contentType: String, data: Data) {
        parts.append(Part(name: name, filename: filename, contentType: contentType, data: data))
    }

    public func body() -> Data {
        var d = Data()
        for p in parts {
            var disposition = "form-data; name=\"\(p.name)\""
            if let f = p.filename { disposition += "; filename=\"\(f)\"" }
            d.append(Data("--\(boundary)\r\nContent-Disposition: \(disposition)\r\nContent-Type: \(p.contentType)\r\n\r\n".utf8))
            d.append(p.data)
            d.append(Data("\r\n".utf8))
        }
        d.append(Data("--\(boundary)--\r\n".utf8))
        return d
    }
}

// MARK: - Cloudflare REST API (only what Connect needs)

public struct CloudflareAPI: Sendable {
    public static let base = URL(string: "https://api.cloudflare.com/client/v4")!
    /// Cloudflare blocks default library user agents (error 1010), so say who we are.
    public static var userAgent: String { "Sozvon/\(Updates.current) (macOS)" }

    public struct Account: Codable, Equatable, Hashable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    public struct Database: Codable, Equatable, Sendable {
        public let uuid: String
        public let name: String
        public init(uuid: String, name: String) { self.uuid = uuid; self.name = name }
    }

    public struct Namespace: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }

    /// A binding of an already uploaded script (`GET .../scripts/{name}/settings`).
    public struct Binding: Codable, Equatable, Sendable {
        public let name: String
        public let type: String
        public var id: String?
        public var databaseID: String?
        public var namespaceID: String?

        enum CodingKeys: String, CodingKey {
            case name, type, id, databaseID = "database_id", namespaceID = "namespace_id"
        }

        public init(name: String, type: String, id: String? = nil, databaseID: String? = nil, namespaceID: String? = nil) {
            self.name = name
            self.type = type
            self.id = id
            self.databaseID = databaseID
            self.namespaceID = namespaceID
        }
    }

    struct Envelope<T: Decodable>: Decodable {
        struct Item: Decodable { let code: Int?; let message: String? }
        let success: Bool?
        let errors: [Item]?
        let result: T?
    }

    struct Empty: Decodable {}

    /// Only the error list of a reply, whatever its result is.
    struct Errors: Decodable { let errors: [Envelope<Empty>.Item]? }

    public let token: String
    public let session: URLSession
    public let base: URL

    /// Pauses before the second and third try of a request Cloudflare answered with a temporary error.
    let retryDelays: [Double]

    public init(token: String, session: URLSession = .shared, base: URL = CloudflareAPI.base,
                retryDelays: [Double] = [2, 6]) {
        self.token = token
        self.session = session
        self.base = base
        self.retryDelays = retryDelays
    }

    /// One request. `path` segments must already be percent-encoded where needed (KV key names).
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
              contentType: String? = nil) async throws -> (data: Data, status: Int) {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = c.percentEncodedPath + (c.percentEncodedPath.hasSuffix("/") ? "" : "/") + path
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        // Cloudflare's API answers 502/503/504 during its own incidents: try again a couple of times
        // before giving up, so a short hiccup doesn't fail Connect or Update server.
        var attempt = 0
        while true {
            do {
                let (data, resp) = try await session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if Self.retryable(status) {
                    // Cloudflare's request id and the start of a JSON error: enough to ask their support.
                    // Never the body of a KV value (that is the server password) and never the path's key name.
                    let ray = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "cf-ray") ?? "-"
                    let isValue = path.contains("/values/")
                    let errors = isValue ? [] : ((try? JSONDecoder().decode(Errors.self, from: data))?.errors?.compactMap(\.message) ?? [])
                    // No path: the request id identifies the call for Cloudflare, and a path may name a KV key.
                    Self.log("\(method) -> \(status) cf-ray \(ray) \(errors.joined(separator: "; "))")
                }
                if Self.retryable(status), attempt < retryDelays.count {
                    try await Task.sleep(for: .seconds(retryDelays[attempt]))
                    attempt += 1
                    continue
                }
                return (data, status)
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw CloudflareError(L("Нет связи с Cloudflare: %@", error.localizedDescription))
            }
        }
    }

    static func retryable(_ status: Int) -> Bool { status == 502 || status == 503 || status == 504 }

    /// One API call. `notFound`: 404 returns nil instead of an error.
    func call<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: Any]? = nil,
                            multipart: Multipart? = nil, raw: Data? = nil, notFound: Bool = false,
                            as: T.Type = T.self) async throws -> T? {
        var body: Data?, type: String?
        if let json {
            body = try JSONSerialization.data(withJSONObject: json)
            type = "application/json"
        } else if let multipart {
            body = multipart.body()
            type = multipart.contentType
        } else if let raw {
            body = raw
            type = "text/plain; charset=utf-8"
        }
        let (data, status) = try await send(method, path, query: query, body: body, contentType: type)
        if status == 404 && notFound { return nil }
        let env = try? JSONDecoder().decode(Envelope<T>.self, from: data)
        if (200..<300).contains(status), env?.success != false, let env {
            if let r = env.result { return r }
            if T.self == Empty.self { return Empty() as? T }
        }
        throw failure(method, path, status: status, data: data)
    }

    /// Log a failed call (path without the account id, never the token) and turn it into plain words.
    func failure(_ method: String, _ path: String, status: Int, data: Data) -> CloudflareError {
        let messages = (try? JSONDecoder().decode(Errors.self, from: data))?.errors?.compactMap(\.message) ?? []
        // Enough to see which permission is missing.
        // KV value paths end in the key name; keep only the namespace part.
        let shown = Self.shown(path)
        Self.log("\(method) \(shown) -> \(status) \(messages.joined(separator: "; "))")
        return Self.error(status: status, messages: messages, request: "\(method) \(shown)")
    }

    /// A path for the log: without the account id and without KV key names.
    static func shown(_ path: String) -> String {
        path.replacingOccurrences(of: #"accounts/[0-9a-f]{32}"#, with: "accounts/…", options: .regularExpression)
            .replacingOccurrences(of: #"/values/.*$"#, with: "/values/…", options: .regularExpression)
    }

    static func error(status: Int, messages: [String], request: String = "") -> CloudflareError {
        let detail = messages.isEmpty ? L("код %@", status) : messages.joined(separator: "; ")
        if status == 401 || status == 403 {
            return CloudflareError(L("Cloudflare не дал доступ (%@: %@). Попробуй ещё раз и разреши все права", request, detail))
        }
        if retryable(status) {
            return CloudflareError(L("Cloudflare сейчас не отвечает (код %@), это сбой на их стороне. Попробуй через несколько минут", status))
        }
        return CloudflareError(L("Cloudflare: %@", detail))
    }

    /// ~/Library/Logs/Sozvon/cloudflare.log (Paths.logs): failed API calls, for support. No tokens or passwords.
    static var logFile: URL { Paths.logs.appendingPathComponent("cloudflare.log") }

    static func log(_ line: String) {
        let dir = Paths.logs
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = logFile
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: f, atomically: true, encoding: .utf8)
        }
    }

    public func accounts() async throws -> [Account] {
        try await call("GET", "accounts", query: [URLQueryItem(name: "per_page", value: "50")]) ?? []
    }

    struct Subdomain: Codable { let subdomain: String? }

    /// The account's `<name>.workers.dev`, nil if it was never chosen.
    public func workersSubdomain(account: String) async throws -> String? {
        let r: Subdomain? = try await call("GET", "accounts/\(account)/workers/subdomain", notFound: true)
        return r?.subdomain.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func createWorkersSubdomain(account: String, name: String) async throws -> String {
        let r: Subdomain? = try await call("PUT", "accounts/\(account)/workers/subdomain", json: ["subdomain": name])
        return r?.subdomain ?? name
    }

    public func databases(account: String, name: String) async throws -> [Database] {
        try await call("GET", "accounts/\(account)/d1/database",
                       query: [URLQueryItem(name: "name", value: name), URLQueryItem(name: "per_page", value: "100")]) ?? []
    }

    public func createDatabase(account: String, name: String) async throws -> Database {
        guard let r: Database = try await call("POST", "accounts/\(account)/d1/database", json: ["name": name]) else {
            throw CloudflareError(L("Cloudflare не создал базу"))
        }
        return r
    }

    /// All KV namespaces, page by page.
    public func namespaces(account: String) async throws -> [Namespace] {
        var all: [Namespace] = []
        for page in 1...20 {
            let r: [Namespace] = try await call("GET", "accounts/\(account)/storage/kv/namespaces",
                                                query: [URLQueryItem(name: "page", value: String(page)),
                                                        URLQueryItem(name: "per_page", value: "100")]) ?? []
            all += r
            if r.count < 100 { break }
        }
        return all
    }

    public func createNamespace(account: String, title: String) async throws -> Namespace {
        guard let r: Namespace = try await call("POST", "accounts/\(account)/storage/kv/namespaces", json: ["title": title]) else {
            throw CloudflareError(L("Cloudflare не создал хранилище входов"))
        }
        return r
    }

    struct ScriptSettings: Decodable { let bindings: [Binding]? }

    /// Bindings of the uploaded script, nil if there is no such script yet.
    public func scriptBindings(account: String, script: String) async throws -> [Binding]? {
        let r: ScriptSettings? = try await call("GET", "accounts/\(account)/workers/scripts/\(script)/settings", notFound: true)
        return r.map { $0.bindings ?? [] }
    }

    public func uploadScript(account: String, script: String, body: Multipart) async throws {
        let _: Empty? = try await call("PUT", "accounts/\(account)/workers/scripts/\(script)", multipart: body)
    }

    /// Where Connect keeps a copy of the server password: in the server's own KV namespace (OAUTH_KV), so
    /// another Mac signed in to the same Cloudflare account can reuse it. The Worker never reads this key.
    public static let storedPasswordKey = "sozvon:password"

    static func kvPath(account: String, namespace: String, key: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        return "accounts/\(account)/storage/kv/namespaces/\(namespace)/values/\(k)"
    }

    /// A KV value as text (`GET .../values/{key}`, the raw bytes); nil when there is no such key.
    public func kvValue(account: String, namespace: String, key: String) async throws -> String? {
        let path = Self.kvPath(account: account, namespace: namespace, key: key)
        let (data, status) = try await send("GET", path)
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw failure("GET", path, status: status, data: data) }
        return String(data: data, encoding: .utf8)
    }

    /// Write a KV value (`PUT .../values/{key}`, the raw text as the body).
    public func putKVValue(account: String, namespace: String, key: String, value: String) async throws {
        let _: Empty? = try await call("PUT", Self.kvPath(account: account, namespace: namespace, key: key), raw: Data(value.utf8))
    }

    public func enableWorkersDev(account: String, script: String) async throws {
        let _: Empty? = try await call("POST", "accounts/\(account)/workers/scripts/\(script)/subdomain",
                                       json: ["enabled": true, "previews_enabled": false])
    }
}

// MARK: - Deploy

public enum CloudflareDeploy {
    public static let scriptName = "sozvon"
    public static let databaseName = "sozvon"
    public static let namespaceTitle = "sozvon-oauth"

    /// What Connect will use in the account: everything is found or created before the upload.
    public struct Plan: Equatable, Sendable {
        public let account: String
        public let serverURL: URL
        public let databaseID: String
        public let namespaceID: String
        /// The `sozvon` Worker already exists (an update, or a new Mac taking over its server).
        public var replacesServer = false
    }

    /// `https://sozvon.<subdomain>.workers.dev`.
    public static func serverURL(subdomain: String) -> URL {
        URL(string: "https://\(scriptName).\(subdomain).workers.dev")!
    }

    /// workers.dev subdomain from the account name: lowercase latin letters, digits and dashes, 63 at most.
    public static func subdomainCandidate(_ name: String) -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? name
        var out = ""
        for ch in latin.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) } else if out.last != "-" { out.append("-") }
        }
        // "Ann@x.com's Account": the e-mail part is enough.
        for suffix in ["-s-account", "-account"] where out.hasSuffix(suffix) { out.removeLast(suffix.count) }
        out = String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.count >= 3 ? out : "sozvon-\(Int.random(in: 1000...9999))"
    }

    /// Database and namespace ids to reuse, so running Connect again never makes duplicates or loses calls:
    /// first what the existing `sozvon` script is bound to (also a Deploy-button or wrangler install),
    /// then the resources by name. nil: create one.
    public static func reuse(bindings: [CloudflareAPI.Binding]?, databases: [CloudflareAPI.Database],
                             namespaces: [CloudflareAPI.Namespace]) -> (database: String?, namespace: String?) {
        let b = bindings ?? []
        let boundDB = b.first { $0.type == "d1" && $0.name == "DB" }.flatMap { $0.databaseID ?? $0.id }
        let boundKV = b.first { $0.type == "kv_namespace" && $0.name == "OAUTH_KV" }.flatMap { $0.namespaceID ?? $0.id }
        let db = boundDB ?? databases.first { $0.name == databaseName }?.uuid
        let kv = boundKV ?? namespaces.first { $0.title == namespaceTitle }?.id
        return (db, kv)
    }

    /// Find or create: the workers.dev subdomain, the database, the namespace.
    public static func prepare(api: CloudflareAPI, account: CloudflareAPI.Account,
                               progress: @MainActor @Sendable (String) -> Void) async throws -> Plan {
        await progress(L("Создаю базу…"))
        var sub = try await api.workersSubdomain(account: account.id)
        if sub == nil {
            let base = subdomainCandidate(account.name)
            var lastError: Error?
            for attempt in 0..<4 where sub == nil {
                let name = attempt == 0 ? base : "\(base.prefix(36))-\(String(Int.random(in: 1000...9999)))"
                do { sub = try await api.createWorkersSubdomain(account: account.id, name: name) } catch { lastError = error }
            }
            guard let s = sub else { throw lastError ?? CloudflareError(L("Cloudflare не создал адрес workers.dev")) }
            sub = s
        }
        let bindings = try await api.scriptBindings(account: account.id, script: scriptName)
        let found = reuse(bindings: bindings, databases: try await api.databases(account: account.id, name: databaseName),
                          namespaces: try await api.namespaces(account: account.id))
        let db: String
        if let id = found.database { db = id } else { db = try await api.createDatabase(account: account.id, name: databaseName).uuid }
        let kv: String
        if let id = found.namespace { kv = id } else { kv = try await api.createNamespace(account: account.id, title: namespaceTitle).id }
        return Plan(account: account.id, serverURL: serverURL(subdomain: sub!), databaseID: db, namespaceID: kv,
                    replacesServer: bindings != nil)
    }

    /// Upload the bundled Worker with its bindings and the password, and turn on workers.dev.
    public static func upload(api: CloudflareAPI, plan: Plan, bundle: WorkerBundle, password: String,
                              progress: @MainActor @Sendable (String) -> Void) async throws {
        await progress(L("Загружаю сервер…"))
        try await api.uploadScript(account: plan.account, script: scriptName,
                                   body: bundle.upload(databaseID: plan.databaseID, namespaceID: plan.namespaceID, password: password))
        try await api.enableWorkersDev(account: plan.account, script: scriptName)
    }

    /// The server password kept in the account (the server's KV namespace), nil when there is none.
    public static func storedPassword(api: CloudflareAPI, plan: Plan) async throws -> String? {
        try await api.kvValue(account: plan.account, namespace: plan.namespaceID, key: CloudflareAPI.storedPasswordKey)
    }

    /// Keep the server password in the account, for the user's other Macs.
    public static func storePassword(_ password: String, api: CloudflareAPI, plan: Plan) async throws {
        try await api.putKVValue(account: plan.account, namespace: plan.namespaceID, key: CloudflareAPI.storedPasswordKey,
                                 value: password)
    }

    /// A fresh workers.dev address takes a while to appear (DNS, certificate): poll /api/health.
    public static func waitForHealth(_ url: URL, timeout: TimeInterval = 180, interval: Duration = .seconds(3),
                                     check: @Sendable (URL) async -> OwnServer.Health = { await OwnServer.checkHealth($0) }) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while true {
            try Task.checkCancellation()
            switch await check(url) {
            case .ok(let version): return version
            case .failed(let m): last = m
            }
            guard Date() < deadline else {
                throw CloudflareError(L("Сервер загружен, но пока не отвечает (%@). Попробуй ещё раз через минуту", last))
            }
            try await Task.sleep(for: interval)
        }
    }
}
