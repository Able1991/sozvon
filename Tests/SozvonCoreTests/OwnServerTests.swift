import Foundation
import XCTest
@testable import SozvonCore

@MainActor
final class OwnServerTests: TempDirTestCase {
    func testAddressRule() {
        XCTAssertEqual(OwnServer.normalize(" https://x.workers.dev/ ")?.absoluteString, "https://x.workers.dev")
        XCTAssertEqual(OwnServer.normalize("https://x.dev/base//")?.absoluteString, "https://x.dev/base")
        XCTAssertEqual(OwnServer.normalize("http://localhost:8787")?.absoluteString, "http://localhost:8787")
        XCTAssertEqual(OwnServer.normalize("http://127.0.0.1:1/")?.absoluteString, "http://127.0.0.1:1")
        for bad in ["http://x.workers.dev", "x.workers.dev", "", "ftp://x.dev", "https://u:p@x.dev", "https://x.dev/?a=1",
                    "https://x.dev/#a"] {
            XCTAssertNil(OwnServer.normalize(bad), bad)
        }
        XCTAssertTrue(OwnServer.isConfigured(url: "https://x.dev", password: "pw"))
        XCTAssertFalse(OwnServer.isConfigured(url: "https://x.dev", password: " "))
        XCTAssertFalse(OwnServer.isConfigured(url: "http://x.dev", password: "pw"))
    }

    func testHealthReply() {
        XCTAssertEqual(OwnServer.health(status: 200, body: Data(#"{"ok":true,"version":"0.1.0","schema":1}"#.utf8)),
                       .ok(version: "0.1.0"))
        XCTAssertNotEqual(OwnServer.health(status: 200, body: Data(#"{"ok":true,"schema":2}"#.utf8)), .ok(version: ""))
        XCTAssertNotEqual(OwnServer.health(status: 200, body: Data("<html>".utf8)), .ok(version: ""))
        XCTAssertNotEqual(OwnServer.health(status: 404, body: Data()), .ok(version: ""))
    }

    func testSyncResultLine() {
        XCTAssertEqual(OwnServer.parseSyncResult("RESULT: ok 3 1 12 2 1"),
                       .ok(sent: 3, deleted: 1, downloaded: 12, trashed: 2, failed: 1))
        XCTAssertEqual(OwnServer.parseSyncResult("RESULT: ok 3 1 12 2"), .ok(sent: 3, deleted: 1, downloaded: 12, trashed: 2, failed: 0),
                       "an engine from before per-call upload errors")
        XCTAssertEqual(OwnServer.parseSyncResult("RESULT: ok 3 1 12"), .ok(sent: 3, deleted: 1, downloaded: 12, trashed: 0, failed: 0),
                       "an engine from before call tombstones")
        XCTAssertEqual(OwnServer.parseSyncResult("RESULT: ok 3 1"), .ok(sent: 3, deleted: 1, downloaded: 0, trashed: 0, failed: 0),
                       "an engine from before downloads")
        XCTAssertEqual(OwnServer.parseSyncResult("RESULT: ok 1 2 3 4 5 6"),
                       .ok(sent: 1, deleted: 2, downloaded: 3, trashed: 4, failed: 5), "a newer engine: the extra number is ignored")
        XCTAssertNil(OwnServer.parseSyncResult("RESULT: ok 3 x 1"))
        XCTAssertNil(OwnServer.parseSyncResult("RESULT: ok 1 2 3 x"))
        XCTAssertNil(OwnServer.parseSyncResult("RESULT: ok 1 2 3 4 x"))
        XCTAssertNil(OwnServer.parseSyncResult("RESULT: ok 1 2 3 4 5 6 7"))
        XCTAssertNil(OwnServer.parseSyncResult("RESULT: ok 1"))
        XCTAssertEqual(OwnServer.parseSyncResult("RESULT: error 2 сервер не принял пароль"),
                       .failed(code: 2, message: "сервер не принял пароль"))
        XCTAssertNil(OwnServer.parseSyncResult("STATUS: Проверяю сервер"))
        XCTAssertNil(OwnServer.parseSyncResult("RESULT: ok"))
    }

    func testSyncSummary() {
        XCTAssertEqual(OwnServer.callsCount(1, language: "ru"), "1 звонок")
        XCTAssertEqual(OwnServer.callsCount(3, language: "ru"), "3 звонка")
        XCTAssertEqual(OwnServer.callsCount(12, language: "ru"), "12 звонков")
        XCTAssertEqual(OwnServer.callsCount(21, language: "ru"), "21 звонок")
        XCTAssertEqual(OwnServer.callsCount(111, language: "ru"), "111 звонков")
        XCTAssertEqual(OwnServer.callsCount(1, language: "en"), "1 call")
        XCTAssertEqual(OwnServer.callsCount(12, language: "en"), "12 calls")
        // The test bundle has no translations: L() returns the Russian keys.
        XCTAssertEqual(OwnServer.syncSummary(sent: 3, deleted: 0, downloaded: 12, time: "10:42", language: "ru"),
                       "Синхронизировано 10:42: скачано 12 звонков, отправлено 3")
        XCTAssertEqual(OwnServer.syncSummary(sent: 0, deleted: 2, downloaded: 0, time: "10:42", language: "ru"),
                       "Синхронизировано 10:42: отправлено 0, удалено 2")
        XCTAssertEqual(OwnServer.syncSummary(sent: 1, deleted: 0, downloaded: 0, trashed: 1, time: "10:42", language: "ru"),
                       "Синхронизировано 10:42: отправлено 1, убрано в Корзину 1 звонок")
        XCTAssertEqual(OwnServer.syncSummary(sent: 0, deleted: 0, downloaded: 0, trashed: 3, time: "10:42", language: "ru"),
                       "Синхронизировано 10:42: отправлено 0, убрано в Корзину 3 звонка")
        XCTAssertEqual(OwnServer.syncSummary(sent: 2, deleted: 0, downloaded: 0, failed: 1, time: "10:42", language: "ru"),
                       "Синхронизировано 10:42: отправлено 2. Не отправились: 1 звонок")
        XCTAssertEqual(OwnServer.syncSummary(sent: 0, deleted: 0, downloaded: 0, failed: 5, time: "10:42", language: "ru"),
                       "Синхронизировано 10:42: отправлено 0. Не отправились: 5 звонков")
    }

    func testServerKeysInEnv() throws {
        try write("CUSTOM=keep\n", Paths.env)
        let s = Settings()
        XCTAssertFalse(s.hasServer)
        s.serverURL = "https://x.workers.dev"
        s.serverPassword = "p#1 \"q\""
        s.save()
        let env = try String(contentsOf: Paths.env, encoding: .utf8)
        XCTAssertTrue(env.contains(#"SOZVON_SERVER_URL="https://x.workers.dev""#))
        XCTAssertTrue(env.contains(#"SOZVON_SERVER_PASSWORD="p#1 \"q\"""#), "the password is quoted and escaped")
        let s2 = Settings()
        XCTAssertEqual(s2.serverPassword, "p#1 \"q\"")
        XCTAssertTrue(s2.hasServer)
        s2.serverURL = ""
        s2.serverPassword = ""
        s2.save()
        let cleared = try String(contentsOf: Paths.env, encoding: .utf8)
        XCTAssertFalse(cleared.contains("SOZVON_SERVER"), "cleared fields remove the keys")
        XCTAssertTrue(cleared.contains("CUSTOM=keep"))
    }

    // MARK: Password reuse on a new Mac

    func testPasswordChoice() async {
        let mine = "mine-typed-long-enough-0123", stored = "stored-in-the-account-0123"
        let url = URL(string: "https://sozvon.ann.workers.dev")!
        let accepted: @Sendable (URL, String) async -> Bool = { _, pw in pw == stored }
        let reads = Counter()
        func choose(savedURL: String = "", saved: String = "", replaces: Bool = true,
                    stored: String? = nil) async -> (String, ServerPasswords.Choice) {
            let r = await ServerPasswords.choose(server: url, savedURL: savedURL, savedPassword: saved, replacesServer: replaces,
                                                 stored: { await reads.next(); return stored }, accepts: accepted,
                                                 generate: { "generated" })
            return (r.password, r.choice)
        }
        var r = await choose(savedURL: "https://sozvon.ann.workers.dev/", saved: mine, stored: stored)
        XCTAssertEqual(r.0, mine); XCTAssertEqual(r.1, .saved)  // an update from this Mac
        let readsAfterSaved = await reads.n
        XCTAssertEqual(readsAfterSaved, 0, "the account copy is not read when this Mac has the password")
        r = await choose()
        XCTAssertEqual(r.0, "generated"); XCTAssertEqual(r.1, .new(signInAgain: true))  // nothing stored
        r = await choose(stored: stored + "\n")
        XCTAssertEqual(r.0, stored); XCTAssertEqual(r.1, .stored)  // a new Mac, the copy in the account
        r = await choose(stored: "stale")
        XCTAssertEqual(r.0, "generated"); XCTAssertEqual(r.1, .new(signInAgain: true))  // the server does not take it
        r = await choose(replaces: false, stored: stored)
        XCTAssertEqual(r.1, .new(signInAgain: false))  // a brand-new server: nobody to sign out
        r = await choose(savedURL: "https://other.workers.dev", saved: mine)
        XCTAssertEqual(r.0, "generated", "a password saved for another server is never sent to this one")
        // The server refuses a password under 20 characters: a short one typed by hand is replaced, not uploaded.
        r = await choose(savedURL: "https://sozvon.ann.workers.dev", saved: "only-19-characters!")
        XCTAssertEqual(r.0, "generated"); XCTAssertEqual(r.1, .new(signInAgain: true))
        XCTAssertEqual(ServerPassword.minimumLength, 20)
        XCTAssertGreaterThanOrEqual(ServerPassword.generate().count, ServerPassword.minimumLength)
    }
}

private actor Counter {
    var n = 0
    func next() { n += 1 }
}
