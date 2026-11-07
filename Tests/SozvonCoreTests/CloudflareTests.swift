import Foundation
import XCTest
@testable import SozvonCore

/// Fake Cloudflare API: answers by "METHOD path" from a table and records every request with its body.
final class FakeCloudflare: URLProtocol, @unchecked Sendable {
    struct Reply { let status: Int; let json: String }
    nonisolated(unsafe) static var routes: [String: Reply] = [:]
    nonisolated(unsafe) static var requests: [(key: String, query: String, body: Data, headers: [String: String])] = []
    static let lock = NSLock()

    static func reset(_ r: [String: Reply]) {
        lock.lock(); defer { lock.unlock() }
        routes = r
        requests = []
    }

    static func keys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return requests.map(\.key)
    }

    static func ok(_ result: String) -> Reply { Reply(status: 200, json: #"{"success":true,"errors":[],"result":\#(result)}"#) }

    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeCloudflare.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let path = url.path.replacingOccurrences(of: "/client/v4/", with: "")
        let key = "\(request.httpMethod ?? "GET") \(path)"
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            s.close()
        }
        Self.lock.lock()
        Self.requests.append((key, url.query ?? "", body, request.allHTTPHeaderFields ?? [:]))
        let reply = Self.routes[key] ?? Reply(status: 404, json: #"{"success":false,"errors":[{"code":10007,"message":"not found"}],"result":null}"#)
        Self.lock.unlock()
        let resp = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// TempDirTestCase: failed requests go to a temporary cloudflare.log, never to ~/Library/Logs/Sozvon.
final class CloudflareTests: TempDirTestCase {
    func testTemporaryErrorsAreRetriedThenExplained() async throws {
        CloudflareAPI.retryDelays = [0, 0]
        defer { CloudflareAPI.retryDelays = [2, 6] }
        FakeCloudflare.reset(["GET accounts": FakeCloudflare.Reply(status: 503, json: "")])
        let api = CloudflareAPI(token: "t", session: FakeCloudflare.session)
        do {
            let _: [CloudflareAPI.Account]? = try await api.call("GET", "accounts")
            XCTFail("503 must fail in the end")
        } catch let e as CloudflareError {
            XCTAssertTrue(e.message.contains("503"), e.message)
        }
        XCTAssertEqual(FakeCloudflare.keys(), ["GET accounts", "GET accounts", "GET accounts"], "two retries")
    }

    func testPKCEChallengeFromVerifier() {
        // RFC 7636, appendix B.
        let p = CloudflareOAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(p.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let r = CloudflareOAuth.PKCE.random()
        XCTAssertEqual(r.verifier.count, 43)
        XCTAssertNotEqual(r.verifier, CloudflareOAuth.PKCE.random().verifier)
        XCTAssertNil(r.verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testAuthorizeURL() throws {
        let url = CloudflareOAuth.authorizeURL(pkce: CloudflareOAuth.PKCE(verifier: "v".padding(toLength: 43, withPad: "v", startingAt: 0)),
                                               state: "st4te")
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual("\(c.scheme!)://\(c.host!)\(c.path)", "https://dash.cloudflare.com/oauth2/auth")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["client_id"], "f3e3629d54e6f828e18f190026554649")
        XCTAssertEqual(q["redirect_uri"], "http://127.0.0.1:47817/oauth/callback")
        XCTAssertEqual(q["scope"], "account-settings.read d1.write workers-scripts.edit workers-scripts.admin workers-kv-storage.write")
        XCTAssertEqual(q["state"], "st4te")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"]?.count, 43)
        XCTAssertFalse(url.absoluteString.contains("offline_access"))
        XCTAssertTrue(url.absoluteString.contains("redirect_uri=http://127.0.0.1:47817/oauth/callback")
                      || url.absoluteString.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A47817%2Foauth%2Fcallback"))
    }

    func testCallbackParsing() {
        let s = "abc"
        XCTAssertEqual(CloudflareOAuth.parseCallback(target: "/oauth/callback?code=C0DE&state=abc", state: s), .code("C0DE"))
        XCTAssertEqual(CloudflareOAuth.parseCallback(target: "/oauth/callback?code=C0DE&state=evil", state: s), .ignore)
        XCTAssertEqual(CloudflareOAuth.parseCallback(target: "/oauth/callback?code=C0DE", state: s), .ignore)
        XCTAssertEqual(CloudflareOAuth.parseCallback(target: "/favicon.ico", state: s), .ignore)
        XCTAssertEqual(CloudflareOAuth.parseCallback(target: "/oauth/callback?state=abc", state: s), .ignore)
        guard case .failed = CloudflareOAuth.parseCallback(target: "/oauth/callback?error=access_denied&state=abc", state: s) else {
            return XCTFail("declined sign-in must stop the flow")
        }
        guard case .failed(let m) = CloudflareOAuth.parseCallback(
            target: "/oauth/callback?error=invalid_scope&error_description=bad+scope&state=abc", state: s) else { return XCTFail() }
        XCTAssertTrue(m.contains("bad scope"), m)
        XCTAssertEqual(CloudflareOAuth.parseCallback(target: "/oauth/callback?error=access_denied&state=evil", state: s), .ignore)
        // Any web page can hit the loopback port: an error without our state never aborts the sign-in.
        XCTAssertEqual(CloudflareOAuth.parseCallback(target: "/oauth/callback?error=x&error_description=pwned", state: s), .ignore)
        XCTAssertEqual(CloudflareOAuth.parseCallback(target: "/oauth/callback?error=access_denied&state=", state: s), .ignore)

        XCTAssertEqual(CloudflareOAuth.requestTarget(head: "GET /oauth/callback?code=1 HTTP/1.1\r\nHost: x"), "/oauth/callback?code=1")
        XCTAssertNil(CloudflareOAuth.requestTarget(head: "POST /oauth/callback HTTP/1.1"))
        XCTAssertNil(CloudflareOAuth.requestTarget(head: "garbage"))
        let r = String(decoding: CloudflareOAuth.httpResponse(status: 200, html: "<p>ok</p>"), as: UTF8.self)
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(r.contains("Content-Length: 9\r\n"))
        XCTAssertTrue(CloudflareOAuth.page("<b>", "x").contains("&lt;b&gt;"))
    }

    func testTokenExchange() throws {
        let req = CloudflareOAuth.tokenRequest(code: "a b+c", verifier: "ver")
        XCTAssertEqual(req.url?.absoluteString, "https://dash.cloudflare.com/oauth2/token")
        XCTAssertEqual(req.httpMethod, "POST")
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        XCTAssertEqual(body, "grant_type=authorization_code&code=a%20b%2Bc&redirect_uri=http%3A%2F%2F127.0.0.1%3A47817%2Foauth%2Fcallback"
                       + "&client_id=f3e3629d54e6f828e18f190026554649&code_verifier=ver")
        XCTAssertEqual(try CloudflareOAuth.accessToken(status: 200, body: Data(#"{"access_token":"cfoat_x","expires_in":3600}"#.utf8)), "cfoat_x")
        XCTAssertThrowsError(try CloudflareOAuth.accessToken(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)))
        XCTAssertThrowsError(try CloudflareOAuth.accessToken(status: 403, body: Data("<html>Just a moment</html>".utf8)))
    }

    func testLoopbackServerReturnsCodeAndIgnoresStrangers() async throws {
        let port = UInt16.random(in: 49200...49900)
        let server = LoopbackServer(port: port, state: "good")
        let base = "http://127.0.0.1:\(port)"
        let session = URLSession(configuration: .ephemeral)
        let code = try await server.waitForCode(timeout: 10) {
            Task {
                _ = try? await session.data(from: URL(string: base + "/oauth/callback?code=EVIL&state=bad")!)
                _ = try? await session.data(from: URL(string: base + "/oauth/callback?error=x&error_description=stop")!)
                _ = try? await session.data(from: URL(string: base + "/oauth/callback?code=GOOD&state=good")!)
            }
        }
        XCTAssertEqual(code, "GOOD")
    }

    func testLoopbackServerCancel() async {
        let server = LoopbackServer(port: UInt16.random(in: 49901...50500), state: "s")
        let t = Task { try await server.waitForCode(timeout: 30) {} }
        try? await Task.sleep(for: .milliseconds(100))
        t.cancel()
        do { _ = try await t.value; XCTFail("must throw") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    func testPasswordGenerator() {
        let a = ServerPassword.generate()
        XCTAssertEqual(a.count, 32)
        XCTAssertTrue(a.allSatisfy { ServerPassword.alphabet.contains($0) })
        XCTAssertNotEqual(a, ServerPassword.generate())
        XCTAssertEqual(ServerPassword.generate(length: 100).count, 100)
        // Every symbol of the alphabet shows up: no truncated range.
        let many = Set((0..<50).map { _ in ServerPassword.generate() }.joined())
        XCTAssertEqual(many.count, ServerPassword.alphabet.count)
    }

    func testSubdomainCandidate() {
        XCTAssertEqual(CloudflareDeploy.subdomainCandidate("Anna@Example.com's Account"), "anna-example-com")
        XCTAssertEqual(CloudflareDeploy.subdomainCandidate("Аня Петрова"), "ana-petrova")
        XCTAssertTrue(CloudflareDeploy.subdomainCandidate("!!").hasPrefix("sozvon-"))
        XCTAssertLessThanOrEqual(CloudflareDeploy.subdomainCandidate(String(repeating: "a", count: 99)).count, 40)
        XCTAssertEqual(CloudflareDeploy.serverURL(subdomain: "anna").absoluteString, "https://sozvon.anna.workers.dev")
    }

    func testReusePrefersBoundResourcesThenNames() {
        typealias B = CloudflareAPI.Binding
        let dbs = [CloudflareAPI.Database(uuid: "db-other", name: "sozvon-old"), CloudflareAPI.Database(uuid: "db-name", name: "sozvon")]
        let kvs = [CloudflareAPI.Namespace(id: "kv-x", title: "x"), CloudflareAPI.Namespace(id: "kv-name", title: "sozvon-oauth")]
        // Nothing yet: create both.
        XCTAssertTrue(CloudflareDeploy.reuse(bindings: nil, databases: [], namespaces: []) == (nil, nil))
        // By name.
        XCTAssertTrue(CloudflareDeploy.reuse(bindings: nil, databases: dbs, namespaces: kvs) == ("db-name", "kv-name"))
        // A script deployed by the Deploy button or wrangler: its bindings win (D1 id old or new field name).
        let bound = [B(name: "DB", type: "d1", id: "db-bound"), B(name: "OAUTH_KV", type: "kv_namespace", namespaceID: "kv-bound"),
                     B(name: "SOZVON_PASSWORD", type: "secret_text")]
        XCTAssertTrue(CloudflareDeploy.reuse(bindings: bound, databases: dbs, namespaces: kvs) == ("db-bound", "kv-bound"))
        let newField = [B(name: "DB", type: "d1", databaseID: "db-new")]
        XCTAssertTrue(CloudflareDeploy.reuse(bindings: newField, databases: [], namespaces: kvs) == ("db-new", "kv-name"))
    }

    private func bundle() -> WorkerBundle {
        WorkerBundle(manifest: .init(version: "0.2.0", mainModule: "worker.js", compatibilityDate: "2026-11-01",
                                     compatibilityFlags: ["nodejs_compat", "global_fetch_strictly_public"]),
                     script: Data("export default {}\n".utf8))
    }

    func testMultipartUploadBody() throws {
        let m = bundle().upload(databaseID: "D", namespaceID: "K", password: "P", boundary: "XYZ")
        XCTAssertEqual(m.contentType, "multipart/form-data; boundary=XYZ")
        let body = String(decoding: m.body(), as: UTF8.self)
        XCTAssertTrue(body.hasPrefix("--XYZ\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n{"))
        XCTAssertTrue(body.contains("\r\n--XYZ\r\nContent-Disposition: form-data; name=\"worker.js\"; filename=\"worker.js\"\r\n"
                                    + "Content-Type: application/javascript+module\r\n\r\nexport default {}\n\r\n--XYZ--\r\n"))
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: bundle().metadata(databaseID: "D", namespaceID: "K", password: "P")) as? [String: Any])
        XCTAssertEqual(meta["main_module"] as? String, "worker.js")
        XCTAssertEqual(meta["compatibility_date"] as? String, "2026-11-01")
        XCTAssertEqual(meta["compatibility_flags"] as? [String], ["nodejs_compat", "global_fetch_strictly_public"])
        let bindings = try XCTUnwrap(meta["bindings"] as? [[String: String]])
        XCTAssertEqual(bindings, [["type": "d1", "name": "DB", "id": "D"],
                                  ["type": "kv_namespace", "name": "OAUTH_KV", "namespace_id": "K"],
                                  ["type": "secret_text", "name": "SOZVON_PASSWORD", "text": "P"]])
    }

    func testWorkerBundleLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sozvon-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(WorkerBundle.load(from: dir))
        try Data(#"{"version":"0.1.0","main_module":"worker.js","compatibility_date":"2026-11-01","compatibility_flags":["nodejs_compat"]}"#.utf8)
            .write(to: dir.appendingPathComponent("manifest.json"))
        XCTAssertNil(WorkerBundle.load(from: dir), "no script yet")
        try Data("export default {}".utf8).write(to: dir.appendingPathComponent("worker.js"))
        XCTAssertEqual(WorkerBundle.load(from: dir)?.manifest.version, "0.1.0")
    }

    private let account = CloudflareAPI.Account(id: "acc", name: "Anna")

    /// A fresh account: everything is created once, in order, and nothing is created twice.
    func testDeployFreshAccount() async throws {
        FakeCloudflare.reset([
            "GET accounts/acc/workers/subdomain": .init(status: 404, json: #"{"success":false,"errors":[{"code":10007,"message":"no subdomain"}]}"#),
            "PUT accounts/acc/workers/subdomain": FakeCloudflare.ok(#"{"subdomain":"anna"}"#),
            "GET accounts/acc/d1/database": FakeCloudflare.ok("[]"),
            "POST accounts/acc/d1/database": FakeCloudflare.ok(#"{"uuid":"db-new","name":"sozvon"}"#),
            "GET accounts/acc/storage/kv/namespaces": FakeCloudflare.ok("[]"),
            "POST accounts/acc/storage/kv/namespaces": FakeCloudflare.ok(#"{"id":"kv-new","title":"sozvon-oauth"}"#),
            "PUT accounts/acc/workers/scripts/sozvon": FakeCloudflare.ok(#"{"id":"sozvon"}"#),
            "POST accounts/acc/workers/scripts/sozvon/subdomain": FakeCloudflare.ok(#"{"enabled":true,"previews_enabled":false}"#),
        ])
        let api = CloudflareAPI(token: "tok", session: FakeCloudflare.session)
        let plan = try await CloudflareDeploy.prepare(api: api, account: account) { _ in }
        XCTAssertEqual(plan, .init(account: "acc", serverURL: URL(string: "https://sozvon.anna.workers.dev")!,
                                   databaseID: "db-new", namespaceID: "kv-new"))
        try await CloudflareDeploy.upload(api: api, plan: plan, bundle: bundle(), password: "pw") { _ in }
        XCTAssertEqual(FakeCloudflare.keys(), [
            "GET accounts/acc/workers/subdomain", "PUT accounts/acc/workers/subdomain",
            "GET accounts/acc/workers/scripts/sozvon/settings",
            "GET accounts/acc/d1/database", "GET accounts/acc/storage/kv/namespaces",
            "POST accounts/acc/d1/database", "POST accounts/acc/storage/kv/namespaces",
            "PUT accounts/acc/workers/scripts/sozvon", "POST accounts/acc/workers/scripts/sozvon/subdomain",
        ])
        let reqs = FakeCloudflare.requests
        XCTAssertTrue(reqs.allSatisfy { $0.headers["Authorization"] == "Bearer tok" })
        XCTAssertTrue(reqs.allSatisfy { $0.headers["User-Agent"]?.hasPrefix("Sozvon/") == true })
        let upload = try XCTUnwrap(reqs.first { $0.key == "PUT accounts/acc/workers/scripts/sozvon" })
        XCTAssertTrue(upload.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        let text = String(decoding: upload.body, as: UTF8.self)
        XCTAssertTrue(text.contains(#""id":"db-new""#) && text.contains(#""namespace_id":"kv-new""#) && text.contains(#""text":"pw""#))
        let sub = try XCTUnwrap(reqs.first { $0.key == "PUT accounts/acc/workers/subdomain" })
        XCTAssertEqual(try JSONSerialization.jsonObject(with: sub.body) as? [String: String], ["subdomain": "anna"])
        XCTAssertTrue(try XCTUnwrap(reqs.first { $0.key == "GET accounts/acc/d1/database" }).query.contains("name=sozvon"))
    }

    /// Connect again on an account with the server already there: nothing new is created.
    func testDeployAgainReusesEverything() async throws {
        FakeCloudflare.reset([
            "GET accounts/acc/workers/subdomain": FakeCloudflare.ok(#"{"subdomain":"anna"}"#),
            "GET accounts/acc/workers/scripts/sozvon/settings": FakeCloudflare.ok(
                #"{"bindings":[{"name":"DB","type":"d1","id":"db-1"},{"name":"OAUTH_KV","type":"kv_namespace","namespace_id":"kv-1"}]}"#),
            "GET accounts/acc/d1/database": FakeCloudflare.ok(#"[{"uuid":"db-1","name":"sozvon"}]"#),
            "GET accounts/acc/storage/kv/namespaces": FakeCloudflare.ok(#"[{"id":"kv-other","title":"sozvon-oauth"}]"#),
        ])
        let plan = try await CloudflareDeploy.prepare(api: CloudflareAPI(token: "t", session: FakeCloudflare.session), account: account) { _ in }
        XCTAssertEqual(plan.databaseID, "db-1")
        XCTAssertEqual(plan.namespaceID, "kv-1")
        XCTAssertFalse(FakeCloudflare.keys().contains { $0.hasPrefix("POST") || $0.hasPrefix("PUT") }, "\(FakeCloudflare.keys())")
    }

    func testAPIErrorsInPlainWords() async throws {
        FakeCloudflare.reset([
            "GET accounts": .init(status: 403, json: #"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}"#),
            "GET accounts/acc/workers/subdomain": .init(status: 400, json: #"{"success":false,"errors":[{"code":1,"message":"Bad thing"}]}"#),
        ])
        let api = CloudflareAPI(token: "t", session: FakeCloudflare.session)
        do { _ = try await api.accounts(); XCTFail() } catch {
            XCTAssertTrue((error as? CloudflareError)?.message.contains("разреши") == true, "\(error)")
        }
        do { _ = try await api.workersSubdomain(account: "acc"); XCTFail() } catch {
            XCTAssertEqual((error as? CloudflareError)?.message, "Cloudflare: Bad thing")
        }
        XCTAssertTrue(CloudflareAPI.logFile.path.hasPrefix(tmp.path), "tests never write to ~/Library/Logs/Sozvon")
        let log = try String(contentsOf: CloudflareAPI.logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("GET accounts -> 403 Authentication error"), log)
        XCTAssertFalse(log.contains("Bearer"), "no token in the log")
    }

    /// The password copy in the server's KV namespace: read raw, missing is nil, written raw.
    func testStoredPasswordInKV() async throws {
        let key = "accounts/acc/storage/kv/namespaces/kv-1/values/sozvon:password"
        FakeCloudflare.reset([
            "GET \(key)": .init(status: 200, json: "s3cret"),
            "PUT \(key)": FakeCloudflare.ok("null"),
        ])
        let api = CloudflareAPI(token: "t", session: FakeCloudflare.session)
        let plan = CloudflareDeploy.Plan(account: "acc", serverURL: URL(string: "https://sozvon.anna.workers.dev")!,
                                         databaseID: "db-1", namespaceID: "kv-1", replacesServer: true)
        let got = try await CloudflareDeploy.storedPassword(api: api, plan: plan)
        XCTAssertEqual(got, "s3cret")
        try await CloudflareDeploy.storePassword("new-pw", api: api, plan: plan)
        let put = try XCTUnwrap(FakeCloudflare.requests.first { $0.key == "PUT \(key)" })
        XCTAssertEqual(String(decoding: put.body, as: UTF8.self), "new-pw")
        XCTAssertEqual(put.headers["Authorization"], "Bearer t")
        XCTAssertTrue(CloudflareAPI.kvPath(account: "a", namespace: "n", key: "sozvon:password").hasSuffix("/values/sozvon%3Apassword"),
                      "the key name is percent-encoded")

        FakeCloudflare.reset([:])  // no such key: 404
        let missing = try await CloudflareDeploy.storedPassword(api: api, plan: plan)
        XCTAssertNil(missing)
        FakeCloudflare.reset(["PUT \(key)": .init(status: 403, json: #"{"success":false,"errors":[{"code":10000,"message":"no KV"}]}"#),
                              "GET \(key)": .init(status: 500, json: #"{"success":false,"errors":[{"code":1,"message":"boom"}]}"#)])
        do { try await CloudflareDeploy.storePassword("x", api: api, plan: plan); XCTFail("must throw") } catch {
            XCTAssertTrue((error as? CloudflareError)?.message.contains("no KV") == true, "\(error)")
        }
        do { _ = try await CloudflareDeploy.storedPassword(api: api, plan: plan); XCTFail("must throw") } catch {
            XCTAssertEqual((error as? CloudflareError)?.message, "Cloudflare: boom")
        }
    }

    func testWaitForHealthPollsUntilOK() async throws {
        let calls = Counter()
        let v = try await CloudflareDeploy.waitForHealth(URL(string: "https://x.dev")!, timeout: 5, interval: .milliseconds(10)) { _ in
            await calls.next() < 3 ? .failed("DNS") : .ok(version: "0.1.0")
        }
        XCTAssertEqual(v, "0.1.0")
        do {
            _ = try await CloudflareDeploy.waitForHealth(URL(string: "https://x.dev")!, timeout: 0.05, interval: .milliseconds(10)) { _ in .failed("DNS") }
            XCTFail("must time out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("DNS"))
        }
    }
}

private actor Counter {
    var n = 0
    func next() -> Int { n += 1; return n }
}
