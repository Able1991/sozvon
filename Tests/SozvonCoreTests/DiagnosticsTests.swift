// Diagnostics archive: which files go in, what is scrubbed, and that no private data ever does.

import XCTest
@testable import SozvonCore

final class DiagnosticsTests: TempDirTestCase {
    private var logs: URL { tmp.appendingPathComponent("logs") }
    private let home = "/Users/anna"

    /// A call folder with the private files a real call has, and a process.log.
    @discardableResult
    private func makeCall(_ name: String, log: String = "[10:00:00] done\n", logDate: Date? = nil) throws -> URL {
        let dir = calls.appendingPathComponent(name)
        try write("{\"schema\":1,\"id\":\"x\"}", dir.appendingPathComponent("call.json"))
        try write("Anna: SECRET TRANSCRIPT", dir.appendingPathComponent("transcript.md"))
        try write("SECRET SUMMARY", dir.appendingPathComponent("summary.md"))
        try write("audio", dir.appendingPathComponent("system.m4a"))
        try write(log, dir.appendingPathComponent("process.log"))
        if let logDate {
            try FileManager.default.setAttributes([.modificationDate: logDate], ofItemAtPath: dir.appendingPathComponent("process.log").path)
        }
        return dir
    }

    // MARK: Selection

    func testSelectionTakesLogsAndTheLastFiveProcessLogsOnly() throws {
        try write("r", logs.appendingPathComponent("recorder.log"))
        try write("c", logs.appendingPathComponent("cloudflare.log"))
        try write("s", data.appendingPathComponent("setup.log"))
        try write("m", data.appendingPathComponent("mcp.log"))
        try write("TOKEN=abc", data.appendingPathComponent(".env"))
        try write("x", data.appendingPathComponent("voice.log"))
        try write("x", data.appendingPathComponent("voices/anna.json"))
        for i in 1...7 {
            try makeCall(String(format: "2026-11-0%d 10-00 Topic %d", i, i), logDate: Date(timeIntervalSince1970: Double(i) * 1000))
        }
        let picked = DiagnosticArchive.selection(logs: logs, data: data, calls: calls)
        let names = picked.map(\.name)
        XCTAssertEqual(Set(names.filter { !$0.hasPrefix("process-") }), ["recorder.log", "cloudflare.log", "setup.log", "mcp.log"])
        // The five newest by log time: 3 to 7, named by the date id, never by the folder title.
        XCTAssertEqual(Set(names.filter { $0.hasPrefix("process-") }),
                       (3...7).reduce(into: Set<String>()) { $0.insert("process-2026-11-0\($1) 10-00.log") })
        XCTAssertFalse(names.contains { $0.contains("Topic") || $0.contains(".env") || $0.contains("voice") || $0.contains("call.json") })
    }

    func testSelectionSkipsMissingLogsAndEmptyFolders() throws {
        XCTAssertTrue(DiagnosticArchive.selection(logs: logs, data: data, calls: calls).isEmpty)
        try FileManager.default.createDirectory(at: calls.appendingPathComponent("2026-11-01 10-00"), withIntermediateDirectories: true)
        XCTAssertTrue(DiagnosticArchive.selection(logs: logs, data: data, calls: calls).isEmpty)
    }

    func testTwoFoldersWithOneIdKeepDistinctNames() throws {
        try makeCall("2026-11-01 10-00 A")
        try makeCall("2026-11-01 10-00 B")
        let names = DiagnosticArchive.selection(logs: logs, data: data, calls: calls).map(\.name)
        XCTAssertEqual(Set(names).count, 2)
    }

    // MARK: Scrubbing

    func testHomeAndCallFolderNamesAreScrubbed() {
        let scrub = DiagnosticScrub(home: home, callFolders: ["2026-11-04 15-01 Acme pricing with Oleg", "Рабочий разговор"])
        let out = scrub.text("open /Users/anna/Documents/Calls/2026-11-04 15-01 Acme pricing with Oleg/system.m4a failed; "
                             + "/Users/anna/Documents/Calls/Рабочий разговор/mic.m4a; home=/Users/anna")
        XCTAssertEqual(out, "open ~/Documents/Calls/2026-11-04 15-01/system.m4a failed; "
                       + "~/Documents/Calls/call/mic.m4a; home=~")
        XCTAssertFalse(out.contains("Acme"))
        XCTAssertFalse(out.contains("anna"))
    }

    func testRenamedOrDeletedCallFolderIsScrubbedToo() {
        // Not in the list: the call was renamed or deleted after the line was logged.
        let scrub = DiagnosticScrub(home: home, callFolders: ["2026-11-04 15-01 Other"])
        XCTAssertEqual(scrub.text("cannot open /Users/anna/Documents/Calls/2026-10-01 09-00 Old renamed deal/mic.m4a"),
                       "cannot open ~/Documents/Calls/2026-10-01 09-00/mic.m4a")
        XCTAssertEqual(scrub.text("gone: /Users/anna/Documents/Calls/2026-10-01 09-00-3 Deal with Oleg"),
                       "gone: ~/Documents/Calls/2026-10-01 09-00-3")
        XCTAssertEqual(scrub.text("2026-11-08 12:00:00 +0000 level -20 dB"), "2026-11-08 12:00:00 +0000 level -20 dB")
    }

    func testPercentEncodedCallFolderIsScrubbedLikeThePlainOne() {
        // How a Cocoa error prints its URL: NSURL=file:///...%20...
        let scrub = DiagnosticScrub(home: home, callFolders: ["2026-11-04 15-01 Acme Приём"])
        let deleted = scrub.text("Error NSURL=file:///Users/anna/Documents/Calls/2026-10-01%2009-00%20Old%20deal%20with%20Oleg/mic.m4a UserInfo")
        XCTAssertEqual(deleted, "Error NSURL=file://~/Documents/Calls/2026-10-01 09-00/mic.m4a UserInfo")
        let second = scrub.text("file:///Users/anna/Documents/Calls/2026-10-01%2009-00-2%20%D0%A1%D0%B4%D0%B5%D0%BB%D0%BA%D0%B0/x")
        XCTAssertEqual(second, "file://~/Documents/Calls/2026-10-01 09-00-2/x")
        let listed = scrub.text("file:///Users/anna/Documents/Calls/2026-11-04%2015-01%20Acme%20%D0%9F%D1%80%D0%B8%D1%91%D0%BC/mic.m4a")
        XCTAssertEqual(listed, "file://~/Documents/Calls/2026-11-04 15-01/mic.m4a")
        for out in [deleted, second, listed] {
            for leak in ["Old", "Oleg", "Acme", "%D0", "Сделка", "anna"] { XCTAssertFalse(out.contains(leak), out) }
        }
    }

    func testEncodedTitleWithPunctuationIsScrubbedWhole() {
        let scrub = DiagnosticScrub(home: home, callFolders: [])
        let base = "file:///Users/anna/Documents/Calls/2026-10-01%2009-00"
        let cases: [(String, String)] = [
            ("\(base)%20Deal,%20Oleg/mic.m4a", "Oleg"),
            ("\(base)%20Anna's%20deal/mic.m4a", "deal"),
            ("\(base)%20Plan%20(Oleg%20draft)/mic.m4a", "Oleg"),
            ("\(base)%20Plan%20(Oleg%20draft)\" end", "Oleg"),
            ("\(base)%20\u{0421}\u{0434}\u{0435}\u{043B}\u{043A}\u{0430},%20\u{041E}\u{043B}\u{0435}\u{0433}/mic.m4a", "%20"),
            ("(\(base)%20Deal%20Oleg)", "Oleg"),
        ]
        for (input, leak) in cases {
            let out = scrub.text(input)
            XCTAssertFalse(out.contains(leak), "\(leak) survived in \(out)")
            XCTAssertTrue(out.contains("2026-10-01 09-00"), out)
            XCTAssertFalse(out.contains("%"), out)
        }
        XCTAssertEqual(scrub.text("\(base)%20Deal,%20Oleg/mic.m4a UserInfo"), "file://~/Documents/Calls/2026-10-01 09-00/mic.m4a UserInfo")
        XCTAssertEqual(scrub.text("\(base)%20Anna's%20deal\" end"), "file://~/Documents/Calls/2026-10-01 09-00\" end")
    }

    /// What real folder names look like: any of these can be a title, whatever punctuation it holds.
    private static let realFolderNames: [(name: String, id: String)] = [
        ("2026-10-01 09-00 Deal (Oleg) Ivanov", "2026-10-01 09-00"),
        ("2026-10-01 09-00-2 Plan, Oleg, Ivanov", "2026-10-01 09-00-2"),
        ("2026-10-01 09-00 Anna's (draft), Ivanov", "2026-10-01 09-00"),
        ("2026-11-04 15-01 · Globex.io · кабинет автора · Олег, Пётр", "2026-11-04 15-01"),
    ]

    func testEncodedTitleRunsToTheSeparatorWhateverItHolds() {
        let scrub = DiagnosticScrub(home: home, callFolders: [])
        for (name, id) in Self.realFolderNames {
            // absoluteString is exactly what NSURL prints in a Cocoa error.
            let url = URL(fileURLWithPath: "/x/\(name)/mic.m4a").absoluteString
            XCTAssertEqual(scrub.text(url), "file:///x/\(id)/mic.m4a", url)
            let folder = String(url.dropLast("/mic.m4a".count))
            XCTAssertEqual(scrub.text("NSURL=\(folder) UserInfo"), "NSURL=file:///x/\(id) UserInfo", url)
            XCTAssertEqual(scrub.text("\"\(folder)\" next"), "\"file:///x/\(id)\" next", url)
        }
        XCTAssertEqual(scrub.text("file:///x/2026-10-01%2009-00%20Deal%20(Oleg)%20Ivanov/mic.m4a"), "file:///x/2026-10-01 09-00/mic.m4a")
        // The closing ")" of a surrounding expression goes with the title: never the other way round.
        XCTAssertEqual(scrub.text("(file:///x/2026-10-01%2009-00%20Deal%20Oleg) next"), "(file:///x/2026-10-01 09-00 next")
    }

    func testEncodedCallIdIsFoundWithoutALiteralSlashBeforeIt() {
        let scrub = DiagnosticScrub(home: home, callFolders: [])
        // NSURL with a base prints "relative -- base"; a URL in a query has %2F separators.
        XCTAssertEqual(scrub.text("2026-10-01%2009-00%20Deal%20Oleg/mic.m4a -- file:///x/"), "2026-10-01 09-00/mic.m4a -- file:///x/")
        XCTAssertEqual(scrub.text("?path=%2Fx%2F2026-10-01%2009-00%20Deal%20Oleg%2Fmic.m4a end"), "?path=%2Fx%2F2026-10-01 09-00 end")
    }

    func testPlainTitleRunsToTheSeparatorWhateverItHolds() {
        for folders in [[], Self.realFolderNames.map(\.name)] {
            let scrub = DiagnosticScrub(home: home, callFolders: folders)
            for (name, id) in Self.realFolderNames {
                XCTAssertEqual(scrub.text("cannot open /x/\(name)/mic.m4a"), "cannot open /x/\(id)/mic.m4a")
                XCTAssertEqual(scrub.text("gone: /x/\(name)"), "gone: /x/\(id)")
                XCTAssertEqual(scrub.text("open /x/\(name): no such file"), "open /x/\(id): no such file")
                XCTAssertEqual(scrub.text("(/x/\(name))"), folders.isEmpty ? "(/x/\(id)" : "(/x/\(id))")
            }
        }
    }

    func testPlainCallNameWithoutASlashLosesItsTitleToo() {
        let scrub = DiagnosticScrub(home: home, callFolders: [])
        for (name, id) in Self.realFolderNames {
            XCTAssertEqual(scrub.text("renaming \(name)"), "renaming \(id)")
            XCTAssertEqual(scrub.text("\(name): busy"), "\(id): busy")
        }
        XCTAssertEqual(scrub.text("2026-11-08 12:00:00 +0000 level -20 dB"), "2026-11-08 12:00:00 +0000 level -20 dB")
    }

    func testTitleWithoutSlashStopsAtTheColon() {
        let scrub = DiagnosticScrub(home: home, callFolders: [])
        XCTAssertEqual(scrub.text("open /Users/anna/Documents/Calls/2026-10-01 09-00 Old deal: no such file"),
                       "open ~/Documents/Calls/2026-10-01 09-00: no such file")
    }

    func testMCPLogDropsWhatAnAssistantSent() {
        let log = """
            === 2026-11-08T10:00:00Z server.py --http
            INFO:     Started server process [4242]
            sozvon: search index unavailable, substring search: fts5: syntax error near "pay Oleg 5000"
            ERROR:    Exception in ASGI application
            Traceback (most recent call last):
              File "/Users/anna/x.py", line 3, in call
            pydantic_core._pydantic_core.ValidationError: 1 validation error for search
              Input should be a valid string [input_value='what did Maria promise', input_type=int]
            127.0.0.1:5000 - "POST /mcp?token=abc HTTP/1.1" 200
            """
        let out = DiagnosticScrub(home: home, callFolders: []).mcpLog(log)
        for secret in ["Oleg", "5000", "Maria", "promise", "token=abc", "anna"] {
            XCTAssertFalse(out.contains(secret), "\(secret) survived:\n\(out)")
        }
        for kept in ["=== 2026-11-08T10:00:00Z server.py --http", "Started server process", "search index unavailable",
                     "Exception in ASGI application", "ValidationError", "File \"~/x.py\""] {
            XCTAssertTrue(out.contains(kept), "\(kept) missing:\n\(out)")
        }
    }

    func testFolderIdKeepsTheSecondRecordingSuffix() {
        let scrub = DiagnosticScrub(home: home, callFolders: ["2026-11-04 15-01-2 Topic"])
        XCTAssertEqual(scrub.text("in 2026-11-04 15-01-2 Topic now"), "in 2026-11-04 15-01-2 now")
    }

    func testHomeOnlyMatchesAtPathBoundary() {
        let scrub = DiagnosticScrub(home: home, callFolders: [])
        XCTAssertEqual(scrub.text("/Users/anna2/x and /Users/anna/x"), "/Users/anna2/x and ~/x")
    }

    func testSecretsAreRemoved() {
        let scrub = DiagnosticScrub(home: home, callFolders: [])
        let samples = [
            "Authorization: Bearer abcdefghijklmnop12345",
            "token=cfut_abcdefghijklmnopqrstuvwxyz0123456789ABCD",
            "HF_TOKEN=hf_abcdefghijklmnopqrstuvwxyz",
            "key sk-ant-api03-abcdefghijklmnopqrstuvwxyz",
            "password: hunter2hunter2",
            #"{"api_token": "0123456789abcdef0123456789abcdef"}"#,
            "mcp 0123456789abcdef0123456789abcdef01234567",
        ]
        for s in samples {
            let out = scrub.text(s)
            XCTAssertTrue(out.contains("[removed]"), s)
            for secret in ["abcdefghijklmnop12345", "cfut_abc", "hf_abc", "sk-ant", "hunter2", "0123456789abcdef"] {
                XCTAssertFalse(out.contains(secret), "\(secret) survived in \(out)")
            }
        }
        XCTAssertEqual(scrub.text("model turbo, 3 segments, 12.5 s"), "model turbo, 3 segments, 12.5 s")
    }

    // MARK: process.log

    /// What the engine really writes to process.log (see engine i18n): names, project, assistant errors.
    static let sampleProcessLog = """
        [10:00:01] project: Acme pricing; participants: Oleg Petrov, Anna; prompt 120 tokens
        [10:00:01] added to project Acme pricing: Oleg Petrov
        [10:00:02] mic.wav: ~42 s of speech
        [10:00:03] transcribing mic …
        [10:00:09] mic: 31 segments
        [10:00:10] voice: Speaker 1 → Oleg Petrov (0.81)
        [10:00:11] diarization: 2 speakers
        [10:00:12] speaker names: Speaker 2 → Maria Ivanova
        [10:00:13] summary failed (claude): Error: could not summarize "we agreed to pay 5000 to Oleg on Friday" token=sk-ant-api03-abcdefghijklmnopqrstuvwxyz
        [10:00:14] speaker names: assistant error (timeout after the phrase we will sign the contract), names in order of appearance
        [10:00:15] echo: cancellation failed, the microphone is left as is: boom
        [10:00:16] done: /Users/anna/Documents/Calls/2026-11-04 15-01 Acme pricing/transcript.md (12 paragraphs)
        Traceback (most recent call last):
          File "/Users/anna/x.py", line 3, in run
            text = "Привет, это секретная реплика"
        ValueError: bad value: Привет, это секретная реплика
        Привет, это сырая строка без метки времени
        RESULT: error 5 ffmpeg could not read mic.wav: invalid data
        """

    func testProcessLogKeepsOnlyLinesThatCannotCarryPrivateText() {
        let scrub = DiagnosticScrub(home: home, callFolders: ["2026-11-04 15-01 Acme pricing"])
        let out = scrub.processLog(Self.sampleProcessLog)
        for secret in ["Acme", "Oleg", "Maria", "Anna", "5000", "contract", "секретная", "Привет", "сырая",
                       "sk-ant", "anna", "boom", "Friday"] {
            XCTAssertFalse(out.contains(secret), "\(secret) survived:\n\(out)")
        }
        // Support still sees what happened and where it failed.
        for kept in ["transcribing mic", "mic: 31 segments", "diarization: 2 speakers", "mic.wav: ~42 s of speech",
                     "summary failed", "echo: cancellation failed", "voice:", "Traceback", "ValueError",
                     "~/Documents/Calls/2026-11-04 15-01/transcript.md", "RESULT: error 5"] {
            XCTAssertTrue(out.contains(kept), "\(kept) missing:\n\(out)")
        }
    }

    func testListeningFileLinesKeepOnlyWhatIsSafe() {
        let scrub = DiagnosticScrub(home: home, callFolders: [])
        let ok = scrub.processLog("[10:00:00] listening file ready in 41 s\n[10:00:01] файл для прослушивания готов за 41 с\n")
        XCTAssertTrue(ok.contains("listening file ready in 41 s") && ok.contains("файл для прослушивания готов за 41 с"), ok)
        let failed = scrub.processLog("[10:00:02] could not make the listening file: /Users/anna/Calls/secret title\n[10:00:03] не получилось сделать файл для прослушивания: секрет\n")
        XCTAssertFalse(failed.contains("secret") || failed.contains("секрет"), failed)
        XCTAssertTrue(failed.contains("could not make the listening file") && failed.contains("не получилось сделать файл для прослушивания"), failed)
    }

    func testProcessLogMessagesWithAnExtraTailAreDropped() {
        let ok = """
            [10:00:01] system audio was missing for 12 s, separating speakers on the microphone there
            [10:00:02] the prompt with terms confused the model, retrying with a short prompt
            [10:00:03] model large-v3: no Whisper prompt, project terms are not used, only replacements
            [10:00:04] GigaAM understands only Russian: other languages will be recognized poorly
            [10:00:05] another run is still processing this call, waiting for it to end
            [10:00:06] voices: 2 voice print(s) of another model skipped (they stay saved)
            """
        let scrub = DiagnosticScrub(home: home, callFolders: [])
        let kept = scrub.processLog(ok)
        XCTAssertFalse(kept.contains("omitted"), kept)
        let leaky = ok.split(separator: "\n").map { $0 + " SECRET" }.joined(separator: "\n")
        let out = scrub.processLog(leaky)
        XCTAssertFalse(out.contains("SECRET"), out)
        XCTAssertTrue(out.contains("6 lines omitted"), out)
    }

    func testProcessLogSaysHowManyLinesWereLeftOut() {
        let out = DiagnosticScrub(home: home, callFolders: []).processLog("[10:00:00] mic: 3 segments\nsome free text\nmore text\n")
        XCTAssertTrue(out.contains("2 lines omitted"), out)
    }

    func testProcessLogHandlesRussianEngineMessages() {
        let ru = """
            [10:00:01] профиль: Рога и копыта; собеседники: Олег; подсказка 10 ток.
            [10:00:02] имена собеседников: Спикер 1 → Олег
            [10:00:03] саммари не получилось (claude): сказал заплатить Олегу
            [10:00:04] голос: Спикер 1 → Олег (0.80)
            [10:00:05] mic: 3 сегментов
            """
        let out = DiagnosticScrub(home: home, callFolders: []).processLog(ru)
        for secret in ["Рога", "Олег", "заплатить"] { XCTAssertFalse(out.contains(secret), out) }
        XCTAssertTrue(out.contains("саммари не получилось"))
        XCTAssertTrue(out.contains("3 сегментов"))
    }

    // MARK: The archive

    func testBuildWritesAZipWithScrubbedLogsAndNothingPrivate() throws {
        let folder = "2026-11-04 15-01 Acme pricing"
        try makeCall(folder, log: Self.sampleProcessLog.replacingOccurrences(of: "/Users/anna", with: home))
        try write("2026-11-04 15-01 \(home)/Library/x failed\n", logs.appendingPathComponent("recorder.log"))
        try write("Bearer abcdefghijklmnop12345 \(home)\n", logs.appendingPathComponent("cloudflare.log"))
        try write("=== 2026-11-08T10:00:00Z server.py --http\nCOOKIE password=hunter2hunter2\nsozvon: search index unavailable, substring search: near \"Oleg\"\n", data.appendingPathComponent("mcp.log"))
        try write("2026-11-04 15-01 open /Users/anna/Documents/Calls/2026-01-01 08-00 Gone title/mic.m4a\n", logs.appendingPathComponent("recorder.log"))
        try write("TOKEN=abc", data.appendingPathComponent(".env"))
        try write("{}", data.appendingPathComponent("voices/anna.json"))
        let zip = tmp.appendingPathComponent("out.zip")
        let checks = [DiagnosticCheck(id: "ffmpeg", title: "ffmpeg", state: .ok, hint: "found at \(home)/x")]
        try DiagnosticArchive.build(checks: checks, logs: logs, data: data, calls: calls, home: home, to: zip)

        let listing = try Self.unzip(["-Z1", zip.path])
        let entries = listing.split(separator: "\n").map(String.init).sorted()
        XCTAssertEqual(entries, ["checks.txt", "cloudflare.log", "mcp.log", "process-2026-11-04 15-01.log", "recorder.log"])

        let dest = tmp.appendingPathComponent("unpacked")
        _ = try Self.unzip(["-q", zip.path, "-d", dest.path])
        var all = ""
        for e in entries { all += try String(contentsOf: dest.appendingPathComponent(e), encoding: .utf8) }
        for secret in ["SECRET", "Acme", "anna", "hunter2", "abcdefghijklmnop", "Oleg", "TOKEN=abc", "Gone title"] {
            XCTAssertFalse(all.contains(secret), "\(secret) in the archive:\n\(all)")
        }
        let checksText = try String(contentsOf: dest.appendingPathComponent("checks.txt"), encoding: .utf8)
        XCTAssertTrue(checksText.contains("ffmpeg"))
        XCTAssertTrue(checksText.contains("found at ~/x"))
    }

    func testBuildReplacesAnExistingFileAndKeepsNoStaging() throws {
        let zip = tmp.appendingPathComponent("out.zip")
        try write("old", zip)
        try DiagnosticArchive.build(checks: [], logs: logs, data: data, calls: calls, home: home, to: zip)
        XCTAssertNotEqual(try Data(contentsOf: zip), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: zip).prefix(2), Data("PK".utf8))
        let left = try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0.contains("diagnostics") }
        XCTAssertTrue(left.isEmpty, "\(left)")
    }

    func testBigLogsAreCutToTheirEnd() throws {
        let big = (0..<60_000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try write(big, logs.appendingPathComponent("recorder.log"))
        let zip = tmp.appendingPathComponent("out.zip")
        try DiagnosticArchive.build(checks: [], logs: logs, data: data, calls: calls, home: home, to: zip)
        let dest = tmp.appendingPathComponent("unpacked")
        _ = try Self.unzip(["-q", zip.path, "-d", dest.path])
        let text = try String(contentsOf: dest.appendingPathComponent("recorder.log"), encoding: .utf8)
        XCTAssertLessThan(text.utf8.count, DiagnosticArchive.maxLogBytes + 200)
        XCTAssertTrue(text.contains("line 59999"))
        XCTAssertFalse(text.contains("line 0\n"))
        XCTAssertTrue(text.hasPrefix("[earlier lines cut]"))
    }

    func testDefaultFileName() {
        let d = Date(timeIntervalSince1970: 1_793_000_000)
        XCTAssertEqual(DiagnosticArchive.fileName(for: d, calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC")!),
                       "Sozvon-diagnostics-2026-10-26.zip")
    }

    private static func unzip(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "unzip \(args)")
        return String(decoding: data, as: UTF8.self)
    }
}

final class DiagnosticChecksTests: TempDirTestCase {
    func testFreeSpaceStates() {
        XCTAssertEqual(DiagnosticChecks.disk(freeBytes: 50_000_000_000).state, .ok)
        XCTAssertEqual(DiagnosticChecks.disk(freeBytes: 3_000_000_000).state, .warning)
        XCTAssertEqual(DiagnosticChecks.disk(freeBytes: 200_000_000).state, .problem)
        XCTAssertEqual(DiagnosticChecks.disk(freeBytes: nil).state, .warning)
    }

    func testPythonAndLockHash() throws {
        var c = DiagnosticChecks.python(data: data, isDevEngine: false)
        XCTAssertEqual(c.state, .problem)
        try write("#!/bin/sh\n", data.appendingPathComponent(".venv/bin/python3"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data.appendingPathComponent(".venv/bin/python3").path)
        try write("lock", data.appendingPathComponent("uv.lock"))
        c = DiagnosticChecks.python(data: data, isDevEngine: false)
        XCTAssertEqual(c.state, .warning)  // no .venv-lock yet: the environment is for another uv.lock
        let hash = EngineState.lockHash(Data("lock".utf8))
        XCTAssertTrue(c.hint.contains(hash), c.hint)
        try write(hash + "\n", data.appendingPathComponent(".venv-lock"))
        c = DiagnosticChecks.python(data: data, isDevEngine: false)
        XCTAssertEqual(c.state, .ok)
        XCTAssertTrue(c.hint.contains(hash))
    }

    func testModelFfmpegAndSpeakerCache() throws {
        XCTAssertEqual(DiagnosticChecks.model(.turbo, data: data).state, .problem)
        let d = data.appendingPathComponent("models/\(WhisperModel.turbo.dir)/weights.safetensors")
        try write("w", d)
        XCTAssertEqual(DiagnosticChecks.model(.turbo, data: data).state, .ok)

        XCTAssertEqual(DiagnosticChecks.ffmpeg(data: data).state, .problem)
        let real = tmp.appendingPathComponent("ffmpeg-real")
        try write("#!/bin/sh\n", real)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
        try FileManager.default.createDirectory(at: data.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: data.appendingPathComponent(".venv/bin/ffmpeg"), withDestinationURL: real)
        XCTAssertEqual(DiagnosticChecks.ffmpeg(data: data).state, .ok)
        try FileManager.default.removeItem(at: real)  // a dangling link
        XCTAssertEqual(DiagnosticChecks.ffmpeg(data: data).state, .problem)

        XCTAssertEqual(DiagnosticChecks.speakerModels(data: data).state, .warning)
        for n in ["speaker-diarization-3.1", "wespeaker-voxceleb-resnet34-LM"] {
            try FileManager.default.createDirectory(at: data.appendingPathComponent("hf-cache/models--pyannote--\(n)"), withIntermediateDirectories: true)
        }
        XCTAssertEqual(DiagnosticChecks.speakerModels(data: data).state, .ok)
    }

    func testMCPAndPermissions() {
        XCTAssertEqual(DiagnosticChecks.mcp(.listening).state, .ok)
        XCTAssertEqual(DiagnosticChecks.mcp(.notListening).state, .problem)
        XCTAssertEqual(DiagnosticChecks.mcp(.unauthorized).state, .problem)
        XCTAssertEqual(DiagnosticChecks.permission(title: "Mic", granted: true, hint: "x").state, .ok)
        XCTAssertEqual(DiagnosticChecks.permission(title: "Mic", granted: false, hint: "x").state, .problem)
    }

    func testReportText() {
        let text = DiagnosticChecks.text([
            DiagnosticCheck(id: "a", title: "Python", state: .ok, hint: "ready"),
            DiagnosticCheck(id: "b", title: "ffmpeg", state: .problem, hint: "missing"),
            DiagnosticCheck(id: "c", title: "Disk", state: .warning, hint: "low"),
        ])
        XCTAssertEqual(text, "[ok] Python: ready\n[problem] ffmpeg: missing\n[warning] Disk: low\n")
    }
}
