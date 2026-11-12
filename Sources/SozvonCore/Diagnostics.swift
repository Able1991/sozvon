// Diagnostics for support: a list of checks and a zip with the logs.
//
// Privacy rule: the archive never holds transcripts, summaries, audio, call.json, .env, tokens, passwords or
// voice prints. Only a fixed list of log files goes in (never a directory scan), every file is scrubbed, and
// process.log is cut down to the lines that cannot carry what was said (see `DiagnosticScrub.processLog`).

import Foundation

// MARK: - Checks

public enum DiagnosticState: String, Equatable, Sendable {
    case ok, warning, problem
}

public struct DiagnosticCheck: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let state: DiagnosticState
    /// One line: what is wrong and what to do, or the value for a good check.
    public let hint: String

    public init(id: String, title: String, state: DiagnosticState, hint: String) {
        self.id = id
        self.title = title
        self.state = state
        self.hint = hint
    }
}

/// The checks. Each one takes what it looks at as arguments, so tests need no real install.
public enum DiagnosticChecks {
    /// Under 1 GB free a model or an environment update fails; under 5 GB is worth a warning.
    static let lowDisk: Int64 = 5_000_000_000
    static let criticalDisk: Int64 = 1_000_000_000

    public static func python(data: URL, isDevEngine: Bool) -> DiagnosticCheck {
        let title = L("Окружение Python")
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: data.appendingPathComponent(".venv/bin/python3").path) else {
            return DiagnosticCheck(id: "python", title: title, state: .problem,
                                   hint: L("Не установлено. Запусти установку в Настройках, раздел «Распознавание»."))
        }
        guard let lock = try? Data(contentsOf: data.appendingPathComponent("uv.lock")) else {
            return DiagnosticCheck(id: "python", title: title, state: isDevEngine ? .ok : .warning,
                                   hint: isDevEngine ? L("Своя папка движка, uv.lock не проверяется") : L("Нет файла uv.lock в папке движка"))
        }
        let expected = EngineState.lockHash(lock)
        if isDevEngine { return DiagnosticCheck(id: "python", title: title, state: .ok, hint: L("uv.lock %@ (своя папка движка)", expected)) }
        let installed = (try? String(contentsOf: data.appendingPathComponent(".venv-lock"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if installed == expected {
            return DiagnosticCheck(id: "python", title: title, state: .ok, hint: L("Готово, uv.lock %@", expected))
        }
        return DiagnosticCheck(id: "python", title: title, state: .warning,
                               hint: L("Окружение собрано для другого uv.lock, нужно обновить (ожидается %@, стоит %@)",
                                       expected, installed ?? "-"))
    }

    public static func model(_ model: WhisperModel, data: URL) -> DiagnosticCheck {
        let title = L("Модель распознавания")
        if model.isDownloaded(in: data) {
            return DiagnosticCheck(id: "model", title: title, state: .ok, hint: L("%@ скачана", model.title))
        }
        return DiagnosticCheck(id: "model", title: title, state: .problem,
                               hint: L("%@ не скачана. Скачай её в Настройках, раздел «Распознавание».", model.title))
    }

    /// The ffmpeg link setup.sh makes in `.venv/bin`; a link to a file that is gone counts as missing.
    public static func ffmpeg(data: URL) -> DiagnosticCheck {
        let title = "ffmpeg"
        if FileManager.default.isExecutableFile(atPath: data.appendingPathComponent(".venv/bin/ffmpeg").path) {
            return DiagnosticCheck(id: "ffmpeg", title: title, state: .ok, hint: L("Найден"))
        }
        return DiagnosticCheck(id: "ffmpeg", title: title, state: .problem,
                               hint: L("Не найден. Переустанови движок в Настройках, раздел «Распознавание»."))
    }

    public static func speakerModels(data: URL) -> DiagnosticCheck {
        let title = L("Модели разбиения по голосам")
        let cache = data.appendingPathComponent("hf-cache")
        let fm = FileManager.default
        let both = ["speaker-diarization-3.1", "wespeaker-voxceleb-resnet34-LM"].allSatisfy {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: cache.appendingPathComponent("models--pyannote--\($0)").path, isDirectory: &isDir) && isDir.boolValue
        }
        if both { return DiagnosticCheck(id: "speakers", title: title, state: .ok, hint: L("Есть в кэше")) }
        return DiagnosticCheck(id: "speakers", title: title, state: .warning,
                               hint: L("Нет в кэше: звонок расшифруется без разбиения по голосам. Переустанови движок."))
    }

    public static func permission(title: String, granted: Bool, hint: String) -> DiagnosticCheck {
        DiagnosticCheck(id: title, title: title, state: granted ? .ok : .problem, hint: granted ? L("Разрешено") : hint)
    }

    public static func mcp(_ health: MCPHealth) -> DiagnosticCheck {
        let title = L("MCP-сервер")
        switch health {
        case .listening:
            return DiagnosticCheck(id: "mcp", title: title, state: .ok, hint: L("Отвечает на порту %@", String(MCP.port)))
        case .notListening:
            return DiagnosticCheck(id: "mcp", title: title, state: .problem, hint: L("Не отвечает. Подробности в mcp.log."))
        case .unauthorized:
            return DiagnosticCheck(id: "mcp", title: title, state: .problem, hint: L("На порту другой сервер или другой пароль"))
        case .unexpected(let code):
            return DiagnosticCheck(id: "mcp", title: title, state: .problem, hint: L("Неожиданный ответ, код %@", String(code)))
        case .error(let message):
            return DiagnosticCheck(id: "mcp", title: title, state: .problem, hint: message)
        }
    }

    public static func disk(freeBytes: Int64?) -> DiagnosticCheck {
        let title = L("Свободное место")
        guard let free = freeBytes else {
            return DiagnosticCheck(id: "disk", title: title, state: .warning, hint: L("Не удалось узнать"))
        }
        let text = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        if free < criticalDisk { return DiagnosticCheck(id: "disk", title: title, state: .problem, hint: L("Почти нет места: %@", text)) }
        if free < lowDisk { return DiagnosticCheck(id: "disk", title: title, state: .warning, hint: L("Мало места: %@", text)) }
        return DiagnosticCheck(id: "disk", title: title, state: .ok, hint: L("Свободно %@", text))
    }

    public static func versions(app: String, engineBundled: String, engineInstalled: String?) -> DiagnosticCheck {
        let title = L("Версии")
        let installed = engineInstalled ?? "-"
        let state: DiagnosticState = engineInstalled == nil || engineInstalled == engineBundled ? .ok : .warning
        return DiagnosticCheck(id: "versions", title: title, state: state,
                               hint: L("Приложение %@, движок %@ (в приложении %@)", app, installed, engineBundled))
    }

    /// Free space on the volume of `url`, for important data (what the Finder shows).
    public static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The engine version stamp in the data folder (written by EngineSync).
    public static func installedEngineVersion(data: URL) -> String? {
        (try? String(contentsOf: data.appendingPathComponent(EngineSync.stamp), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The file-based checks, in the order the sheet shows them. Permissions, MCP and the app version come from the app.
    public static func local(data: URL, model chosen: WhisperModel, isDevEngine: Bool) -> [DiagnosticCheck] {
        [python(data: data, isDevEngine: isDevEngine), model(chosen, data: data), ffmpeg(data: data),
         speakerModels(data: data), disk(freeBytes: freeBytes(at: data))]
    }

    /// The checks as plain text, one per line: `[state] title: hint`.
    public static func text(_ checks: [DiagnosticCheck]) -> String {
        checks.map { "[\($0.state.rawValue)] \($0.title): \($0.hint)\n" }.joined()
    }
}

// MARK: - Scrubbing

/// Rewrites log text for support: home folder to `~`, call folder names to their date id, secrets removed.
public struct DiagnosticScrub: Sendable {
    let home: String
    /// Longest first, so a folder named like another's prefix is replaced whole.
    let folders: [(name: String, id: String)]

    public init(home: String, callFolders: [String]) {
        self.home = home
        folders = Set(callFolders).filter { $0.count >= 4 }
            .map { (name: $0, id: Self.id(ofFolder: $0)) }
            .filter { $0.name != $0.id }
            .sorted { $0.name.count > $1.name.count }
    }

    /// "2026-11-04 15-01 Acme pricing" -> "2026-11-04 15-01". A folder without a date in its name is just "call":
    /// the first characters of its name would be the title.
    public static func id(ofFolder name: String) -> String {
        Call.parseID(name) != nil ? CallFolder.id(fromName: name) : "call"
    }

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Only ever called with the constant patterns below: a bad one is a programming error, caught by any test.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    // Privacy filter: too much removed is fine, too little is not. A call id starts the match wherever it stands;
    // what follows is its title up to a delimiter, and nothing but the delimiter ends it (never "(", ")", ",", "'", "·").
    // Plain name: "/" or ":" (callDirName never leaves them in a name) or the end of the line.
    private static let dateFolder = regex(#"(\d{4}-\d{2}-\d{2} \d{2}-\d{2}(?:-\d+)?) [^/:\n]+(?=[/:]|$)"#, options: .anchorsMatchLines)
    // Percent-encoded name: "/", whitespace (a real space is never literal in such a URL) or a quote, or the end of the text.
    // A ")" closing a surrounding log expression goes with the title.
    private static let encodedDateFolder = regex(#"(\d{4}-\d{2}-\d{2})%20(\d{2}-\d{2}(?:-\d+)?)(?:%20[^/\s"]*)?"#)

    private static let secrets: [(NSRegularExpression, String)] = [
        (regex(#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#), "$1[removed]"),
        (regex(#"(?i)\b([\w.-]*(?:token|secret|password|passwd|pwd|api[_-]?key|authorization|cookie)[\w.-]*)(["']?\s*[:=]\s*["']?)[^\s"',;}]+"#),
         "$1$2[removed]"),
        (regex(#"\b(?:sk-[A-Za-z0-9_-]{10,}|cfut_[A-Za-z0-9]{10,}|hf_[A-Za-z0-9]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{20,})"#),
         "[removed]"),
        (regex(#"\b[A-Fa-f0-9]{32,}\b"#), "[removed]"),
        (regex(#"\b[A-Za-z0-9_-]{40,}\b"#), "[removed]"),
        (regex(#"[\w.+-]+@[\w-]+\.[\w.-]+"#), "[removed]"),
    ]

    public func text(_ input: String) -> String {
        var s = input
        // The marker keeps the text after a listed folder: its title is already gone, so the next pass must not take that text for one.
        let done = "\u{1}"
        for f in folders { s = s.replacingOccurrences(of: f.name, with: f.id + done) }
        // A folder that was renamed or deleted is not in the list: a call id loses its title all the same.
        s = Self.dateFolder.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        s = s.replacingOccurrences(of: done, with: "")
        // A Cocoa error prints a URL: "…/2026-10-01%2009-00%20Title/mic.m4a". After the plain pass: what follows
        // the id this pass leaves must not look like a plain title.
        s = Self.encodedDateFolder.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1 $2")
        if !home.isEmpty, home != "/" {
            let pattern = NSRegularExpression.escapedPattern(for: home) + "(?![A-Za-z0-9_-])"
            s = Self.regex(pattern).stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                                              withTemplate: "~")
        }
        for (re, template) in Self.secrets {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    // MARK: process.log

    // The patterns below match the engine's own log lines in both languages (engine/sozvon_engine/i18n.py).
    // l10n-ignore-start

    /// A line the engine writes whose variable part is a name, a project, an assistant's error or anything else
    /// that can repeat the conversation: only the label (group 1) stays.
    private static let stubs: [NSRegularExpression] = [
        #"^(project|профиль): "#,
        #"^(added to project|в проект) "#,
        #"^(speaker names|имена собеседников)"#,
        #"^(voice|голос): "#,
        #"^(voice prints failed|образцы голосов не сработали)"#,
        #"^(summary failed|саммари не получилось)"#,
        #"^((?:microphone )?diarization failed|диаризация(?: микрофона)? не удалась)"#,
        #"^(echo: cancellation failed|эхо: подавление не удалось)"#,
        #"^(could not save the cleaned microphone|не получилось сохранить очищенный микрофон)"#,
        #"^(could not make the listening file|не получилось сделать файл для прослушивания)"#,
        #"^(invalid project name|недопустимое имя проекта)"#,
    ].map { regex($0) }

    /// Lines made of fixed words and numbers only (file and model names, counts), matched whole.
    private static let keeps: [NSRegularExpression] = [
        #"^[\w.-]+: (?:~\d+ s of speech|речи ~\d+ с)$"#,
        #"^[\w.-]+: (?:the track is very quiet|дорожка очень тихая), .*\d+ (?:dB|дБ)$"#,
        #"^(?:transcribing|транскрибация) \w+(?: \([\w./:-]+\))? …$"#,
        #"^\w+: \d+ (?:segments|сегментов)$"#,
        #"^\w+: (?:language|язык) [A-Za-z-]+ \(\d+% .*\)$"#,
        #"^\w+: (?:phrases in another language|фраз на другом языке): \d+$"#,
        #"^(?:microphone diarization|diarization|диаризация микрофона|диаризация): (?:\d+ speakers|собеседников \d+)$"#,
        #"^(?:summary|саммари) …$"#,
        #"^(?:summary|саммари): [\w .-]+ \([\w .-]+\)$"#,
        #"^(?:done|готово): .+ \(\d+ (?:paragraphs|реплик)\)$"#,
        #"^(?:echo: removed ~-?\d+ dB from the microphone \(delay \d+ ms\)|эхо: из микрофона убрано ~-?\d+ дБ \(задержка \d+ мс\))$"#,
        #"^(?:echo: the microphone is left as is, [^:]+|эхо: микрофон оставлен как есть, [^:]+)$"#,
        #"^(?:listening file ready in \d+ s|файл для прослушивания готов за \d+ с)$"#,
        #"^(?:speaker echo: dropped \d+ microphone segments|эхо из динамиков: выкинуто \d+ сегментов микрофона)$"#,
        #"^(?:system audio was missing for \d+ s, separating speakers on the microphone there|системный звук пропадал на \d+ с, там собеседники разводятся по микрофону)$"#,
        #"^(?:the prompt with terms confused the model, retrying with a short prompt|подсказка с терминами сбила модель, повтор с короткой подсказкой)$"#,
        #"^(?:model [\w./:-]+: no Whisper prompt, project terms are not used, only replacements|модель [\w./:-]+: без подсказки Whisper, термины проекта не используются, только автозамены)$"#,
        #"^(?:GigaAM understands only Russian: other languages will be recognized poorly|GigaAM понимает только русский: нерусская речь распознается плохо)$"#,
        #"^(?:another run is still processing this call, waiting for it to end|этот звонок ещё обрабатывает другой запуск, жду, пока он закончится)$"#,
        #"^voices: \d+ voice print\(s\) of another model skipped \(they stay saved\)$"#,
    ].map { regex($0) }

    // l10n-ignore-end

    /// mcp.log is the MCP server's stderr. Its errors can quote what an assistant sent: a search query (SQLite's FTS
    /// syntax error repeats a fragment of it), a tool argument (validation errors print the input). So it is filtered
    /// closed like process.log: the start marker, uvicorn's fixed status lines and traceback scaffolding stay,
    /// lines that carry an exception message keep their label only, the rest is dropped.
    private static let mcpStubs: [NSRegularExpression] = [
        #"^(sozvon: search index unavailable, substring search)"#,
        #"^(sozvon: note not sent to the server yet)"#,
        #"^(ERROR:\s+Exception in ASGI application)"#,
    ].map { regex($0) }

    private static let mcpKeeps: [NSRegularExpression] = [
        #"^=== \S+ server\.py --http$"#,
        #"^(?:INFO|WARNING):\s+(?:Started server process \[\d+\]|Waiting for application startup\.|Application startup complete\.|Uvicorn running on http://127\.0\.0\.1:\d+(?: \(Press CTRL\+C to quit\))?|Finished server process \[\d+\]|Shutting down)$"#,
        #"^ERROR:\s+\[Errno 48\] error while attempting to bind on address \('127\.0\.0\.1', \d+\): (?:\[errno 48\] )?address already in use$"#,
    ].map { regex($0) }

    /// Traceback scaffolding shared by every log with Python output (the exception message itself never stays).
    private static let traceKeeps: [NSRegularExpression] = [
        #"^Traceback \(most recent call last\):$"#,
        #"^\s+File ".*", line \d+(?:, in \S+)?$"#,
        #"^(?:During handling of the above exception, another exception occurred:|The above exception was the direct cause of the following exception:)$"#,
    ].map { regex($0) }

    private static let exceptionLine = regex(#"^([A-Za-z_][\w.]*(?:Error|Exception|Exit|Interrupt)):(?: .*)?$"#)
    private static let stamped = regex(#"^\[\d{2}:\d{2}:\d{2}\] (.*)$"#)
    private static let result = regex(#"^RESULT: (ok|error \d+)(?: .*)?$"#)

    /// process.log holds the engine's stderr. Most of it is safe counts, but some lines carry speaker names, the
    /// project and what the assistant answered or choked on, and tracebacks can quote anything. So the filter is
    /// closed by default: a line stays only when it matches a known shape made of fixed words and numbers;
    /// a line with a variable part keeps its label; everything else is counted and dropped.
    public func processLog(_ input: String) -> String {
        filter(input, stubs: Self.stubs, keeps: Self.keeps)
    }

    /// The MCP server's stderr, filtered closed (see `mcpStubs`).
    public func mcpLog(_ input: String) -> String {
        filter(input, stubs: Self.mcpStubs, keeps: Self.mcpKeeps)
    }

    private func filter(_ input: String, stubs: [NSRegularExpression], keeps: [NSRegularExpression]) -> String {
        var out: [String] = []
        var omitted = 0
        func match(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
            re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        }
        func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String {
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
        for raw in input.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(raw)
            var prefix = ""
            var body = line
            if let m = match(Self.stamped, line) {
                prefix = String(line.prefix(11))
                body = group(m, 1, in: line)
            } else if let m = match(Self.result, line) {
                out.append("RESULT: " + group(m, 1, in: line) + (group(m, 1, in: line).hasPrefix("error") ? " [message removed]" : ""))
                continue
            } else if let m = match(Self.exceptionLine, line) {
                out.append(group(m, 1, in: line) + ": [removed]")
                continue
            }
            if let re = stubs.first(where: { match($0, body) != nil }), let m = match(re, body) {
                out.append(prefix + group(m, 1, in: body) + ": [removed]")
            } else if (keeps + Self.traceKeeps).contains(where: { match($0, body) != nil }) {
                out.append(text(prefix + body))
            } else {
                omitted += 1
            }
        }
        if omitted > 0 { out.append("[\(omitted) lines omitted]") }
        return out.joined(separator: "\n") + (out.isEmpty ? "" : "\n")
    }
}

// MARK: - Archive

public enum DiagnosticArchive {
    /// One log goes in at most this long (its end: the newest lines).
    public static let maxLogBytes = 200_000
    /// How many calls' process.log go in.
    public static let processLogCount = 5

    public struct Item: Equatable, Sendable {
        /// The file name inside the zip.
        public let name: String
        public let url: URL
        public let isProcessLog: Bool
        /// The MCP server's log: filtered closed, like process.log.
        public var isMCPLog: Bool { name == "mcp.log" }
    }

    /// The only files that may go in: five named logs and the process.log of the newest calls.
    /// Nothing else from these folders is ever looked at, so a transcript, call.json or `.env` cannot slip in.
    public static func selection(logs: URL, data: URL, calls: URL, count: Int = processLogCount) -> [Item] {
        let fm = FileManager.default
        var items: [Item] = []
        for (folder, name) in [(logs, "recorder.log"), (logs, "cloudflare.log"), (data, "setup.log"), (data, "mcp.log"), (data, "assistant.log")] {
            let url = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { items.append(Item(name: name, url: url, isProcessLog: false)) }
        }
        let dirs = (try? fm.contentsOfDirectory(at: calls, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let found: [(URL, URL, Date)] = dirs.filter(\.hasDirectoryPath).compactMap { dir in
            let log = dir.appendingPathComponent("process.log")
            guard let date = try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return (dir, log, date)
        }
        var used = Set<String>()
        for (dir, log, _) in found.sorted(by: { $0.2 > $1.2 }).prefix(count) {
            let base = "process-" + DiagnosticScrub.id(ofFolder: dir.lastPathComponent)
            var name = base + ".log"
            var n = 2
            while !used.insert(name).inserted { name = "\(base) (\(n)).log"; n += 1 }
            items.append(Item(name: name, url: log, isProcessLog: true))
        }
        return items
    }

    /// Names of all call folders: the scrubber turns them into ids.
    public static func callFolderNames(in calls: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: calls, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter(\.hasDirectoryPath).map(\.lastPathComponent)
    }

    public static func fileName(for date: Date = Date(), calendar: Calendar = .current, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "Sozvon-diagnostics-\(f.string(from: date)).zip"
    }

    /// The end of a file as text, from a line start; reads at most `limit` bytes.
    static func tail(_ url: URL, limit: Int) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let cut = size > UInt64(limit)
        try? h.seek(toOffset: cut ? size - UInt64(limit) : 0)
        var text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        if cut {
            if let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
            text = "[earlier lines cut]\n" + text
        }
        return text
    }

    /// Cut to `maxLogBytes` from the end, at a line start.
    static func limited(_ text: String) -> String {
        guard text.utf8.count > maxLogBytes else { return text }
        let bytes = Array(text.utf8.suffix(maxLogBytes))
        var s = String(decoding: bytes, as: UTF8.self)
        if let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
        return s.hasPrefix("[earlier lines cut]") ? s : "[earlier lines cut]\n" + s
    }

    /// checks.txt and the selected logs, scrubbed, written into `folder`. -> their names.
    static func writeFiles(checks: [DiagnosticCheck], logs: URL, data: URL, calls: URL, scrub: DiagnosticScrub,
                           into folder: URL) throws -> [String] {
        var names = ["checks.txt"]
        try scrub.text(DiagnosticChecks.text(checks)).write(to: folder.appendingPathComponent("checks.txt"), atomically: true, encoding: .utf8)
        for item in selection(logs: logs, data: data, calls: calls) {
            let raw = tail(item.url, limit: maxLogBytes * 5)
            let clean = item.isProcessLog ? scrub.processLog(raw) : item.isMCPLog ? scrub.mcpLog(raw) : scrub.text(raw)
            try limited(clean).write(to: folder.appendingPathComponent(item.name), atomically: true, encoding: .utf8)
            names.append(item.name)
        }
        return names
    }

    /// "Show Logs": the files the zip would hold, scrubbed the same way, in `folder` (emptied first) to look at in
    /// Finder and send. Run it off the main thread.
    public static func writeFolder(checks: [DiagnosticCheck], logs: URL, data: URL, calls: URL, home: String,
                                   to folder: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try writeFiles(checks: checks, logs: logs, data: data, calls: calls,
                           scrub: DiagnosticScrub(home: home, callFolders: callFolderNames(in: calls)), into: folder)
    }

    public enum Failure: Error { case zipFailed(Int32) }

    /// Write the zip: `checks.txt` and the selected logs, all scrubbed. Run it off the main thread.
    public static func build(checks: [DiagnosticCheck], logs: URL, data: URL, calls: URL, home: String, to destination: URL,
                             stagingRoot: URL = FileManager.default.temporaryDirectory) throws {
        let fm = FileManager.default
        let scrub = DiagnosticScrub(home: home, callFolders: callFolderNames(in: calls))
        let staging = stagingRoot.appendingPathComponent("sozvon-diagnostics-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let names = try writeFiles(checks: checks, logs: logs, data: data, calls: calls, scrub: scrub, into: staging)

        let zip = staging.appendingPathComponent("archive.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = staging
        p.arguments = ["-q", "-X", zip.path] + names
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure.zipFailed(p.terminationStatus) }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: zip)
        } else {
            try fm.moveItem(at: zip, to: destination)
        }
    }
}
