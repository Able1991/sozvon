// Папка звонка: call.json (схема 1, контракт раздел 4), ответы «о чём был звонок», имя папки.

import Foundation

/// Что пользователь указал о звонке перед расшифровкой (поля call.json).
public struct CallInfo: Equatable, Sendable {
    public var profile: String
    /// Собеседники через запятую, в порядке, кто заговорит первым.
    public var names: String
    public var topic: String
    public var terms: String
    public var summary: Bool
    public var languages: [SpeechLanguage]

    public init(profile: String = "", names: String = "", topic: String = "", terms: String = "",
                summary: Bool = true, languages: [SpeechLanguage] = [.ru]) {
        self.profile = profile
        self.names = names
        self.topic = topic
        self.terms = terms
        self.summary = summary
        self.languages = languages
    }
}

/// Смещения и длительности дорожек по общим часам захвата (call.json → audio).
public struct AudioTimes: Equatable, Sendable {
    public var micStart: Double?
    public var systemStart: Double?
    public var micSeconds: Double = 0
    public var systemSeconds: Double = 0

    public init(micStart: Double? = nil, systemStart: Double? = nil, micSeconds: Double = 0, systemSeconds: Double = 0) {
        self.micStart = micStart
        self.systemStart = systemStart
        self.micSeconds = micSeconds
        self.systemSeconds = systemSeconds
    }

    public var dictionary: [String: Double] {
        var d: [String: Double] = [:]
        if let micStart { d["mic_start"] = micStart; d["mic_seconds"] = micSeconds }
        if let systemStart { d["system_start"] = systemStart; d["system_seconds"] = systemSeconds }
        return d
    }

    public init(_ d: [String: Any]) {
        micStart = d["mic_start"] as? Double
        systemStart = d["system_start"] as? Double
        micSeconds = d["mic_seconds"] as? Double ?? 0
        systemSeconds = d["system_seconds"] as? Double ?? 0
    }

    public var duration: Double { max(micSeconds, systemSeconds) }
}

public enum CallStatus: String, Sendable {
    case recorded, processing, done, failed
}

/// call.json: метаданные и постоянный id звонка. Пишется атомарно (временный файл и замена),
/// с сохранением полей, которые добавил движок.
public enum CallFile {
    public static let schema = 1
    public static let name = "call.json"

    /// id звонка по имени папки (для папок без id в call.json): «2026-11-04 15-01» или «2026-11-04 15-01-2».
    public static func id(of dir: URL) -> String { CallFolder.id(fromName: dir.lastPathComponent) }

    /// Постоянный id: из call.json, иначе по имени папки.
    public static func callID(_ dir: URL) -> String {
        if let id = read(dir)["id"] as? String, !id.isEmpty { return id }
        return id(of: dir)
    }

    public static func exists(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    public static func read(_ dir: URL) -> [String: Any] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    @discardableResult
    public static func update(_ dir: URL, _ change: (inout [String: Any]) -> Void) -> Bool {
        var c = read(dir)
        change(&c)
        guard let data = try? JSONSerialization.data(withJSONObject: c, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? data.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil
    }

    /// При остановке записи: схема, id, время начала, дорожки, статус «записано».
    @discardableResult
    public static func recordStopped(_ dir: URL, startedAt: Date, audio: AudioTimes) -> Bool {
        update(dir) { c in
            c["schema"] = schema
            // id выдан при создании папки (CallFolder.create): не перетираем его разбором имени.
            if (c["id"] as? String)?.isEmpty ?? true { c["id"] = id(of: dir) }
            c["created_at"] = ISO8601DateFormatter().string(from: startedAt)
            c["audio"] = audio.dictionary
            c["status"] = CallStatus.recorded.rawValue
        }
    }

    /// Ответы окна «О чём был звонок»: движок берёт их из call.json, а не из аргументов.
    @discardableResult
    public static func writeInfo(_ dir: URL, _ i: CallInfo) -> Bool {
        update(dir) { c in
            if (c["id"] as? String)?.isEmpty ?? true { c["id"] = id(of: dir) }
            apply(i, to: &c)
        }
    }

    public static func apply(_ i: CallInfo, to c: inout [String: Any]) {
        c["schema"] = schema
        c["profile"] = i.profile
        c["names"] = splitList(i.names)
        c["topic"] = i.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        c["terms"] = i.terms.trimmingCharacters(in: .whitespacesAndNewlines)
        c["languages"] = SpeechLanguage.serialize(i.languages)
        c["summary"] = i.summary
    }

    /// После сбоя или выхода приложения посреди расшифровки статус навсегда оставался `processing`.
    /// При запуске (вторая копия исключена блокировкой) такие звонки помечаются `failed`:
    /// в окне «Звонки» их можно расшифровать заново. -> сколько исправлено.
    @discardableResult
    public static func failStaleProcessing(in root: URL) -> Int {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var n = 0
        for d in dirs where d.hasDirectoryPath && exists(d) {
            if read(d)["status"] as? String == CallStatus.processing.rawValue, setStatus(d, .failed) { n += 1 }
        }
        return n
    }

    @discardableResult
    public static func setStatus(_ dir: URL, _ s: CallStatus) -> Bool {
        update(dir) { $0["status"] = s.rawValue }
    }

    /// Ответы из call.json. Поле не задано: значение по умолчанию (`fallback`).
    public static func info(_ c: [String: Any], fallback: CallInfo = CallInfo()) -> CallInfo {
        var i = fallback
        if let p = c["profile"] as? String { i.profile = p }
        if let n = c["names"] as? [String] { i.names = n.joined(separator: ", ") }
        else if let n = c["names"] as? String { i.names = n }
        if let t = c["topic"] as? String { i.topic = t }
        if let t = c["terms"] as? String { i.terms = t }
        if let l = c["languages"] as? String { i.languages = SpeechLanguage.parse(l) }
        if let s = c["summary"] as? Bool { i.summary = s }
        return i
    }
}

/// Папка новой записи. Две записи в одну минуту не должны делить папку: дорожки второй затирали
/// первую, а сбой запуска удалял чужую папку. Поэтому id второй записи получает суффикс
/// «2026-11-04 15-01-2» (третьей «-3» и т. д.). Первая запись минуты сохраняет прежний формат,
/// старые папки и их id не меняются. id пишется в call.json сразу при создании папки.
public enum CallFolder {
    /// «2026-11-04 15-01» по местному времени.
    public static func baseID(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// id из начала имени папки: дата «yyyy-MM-dd HH-mm» и необязательный суффикс «-N»,
    /// за ними конец имени или пробел. Не дата: первые 16 символов, как раньше.
    public static func id(fromName name: String) -> String {
        let c = Array(name)
        guard c.count >= 16, Call.parseID(name) != nil else { return String(name.prefix(16)) }
        var end = 16
        if c.count > 17, c[16] == "-" {
            var j = 17
            while j < c.count, c[j].isASCII, c[j].isNumber { j += 1 }
            if j > 17, j == c.count || c[j] == " " { end = j }
        }
        return String(c[0..<end])
    }

    /// id всех звонков папки (из call.json, иначе по имени).
    public static func ids(in root: URL) -> Set<String> {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return Set(dirs.filter(\.hasDirectoryPath).map { CallFile.callID($0) })
    }

    /// Создать папку с новым id и call.json (схема, id, время начала). Существующую папку не
    /// принимает: mkdir без промежуточных папок падает, тогда пробуем следующий суффикс.
    public static func create(in root: URL, at date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = baseID(for: date)
        let taken = ids(in: root)
        for n in 1...999 {
            let id = n == 1 ? base : "\(base)-\(n)"
            if taken.contains(id) { continue }
            let dir = root.appendingPathComponent(id, isDirectory: true)
            guard mkdir(dir.path, 0o755) == 0 else {
                if errno == EEXIST { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let ok = CallFile.update(dir) { c in
                c["schema"] = CallFile.schema
                c["id"] = id
                c["created_at"] = ISO8601DateFormatter().string(from: date)
            }
            guard ok else {
                discardIfUnused(dir)
                throw POSIXError(.EIO)
            }
            return dir
        }
        throw POSIXError(.EEXIST)
    }

    /// Запись не началась: убрать только что созданную папку, если в ней нет ничего, кроме call.json.
    /// Папку с дорожками или чужими файлами не трогаем. -> удалена ли.
    @discardableResult
    public static func discardIfUnused(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path),
              items.allSatisfy({ $0 == CallFile.name || $0 == ".DS_Store" }) else { return false }
        for i in items { try? fm.removeItem(at: dir.appendingPathComponent(i)) }
        return rmdir(dir.path) == 0
    }
}

/// Имя папки звонка: «2026-11-04 15-01 · Acme · запуск · Анна, Иван». Начало (id) не меняется,
/// поэтому повторное переименование берёт из старого имени только дату.
/// Без «/», «:» и «\» (ломают пути и Finder), без переводов строк, не длиннее 120 символов.
public func callDirName(_ current: String, _ i: CallInfo, projectTitle: String?) -> String {
    var parts = [CallFolder.id(fromName: current)]
    if let t = projectTitle?.trimmingCharacters(in: .whitespaces), !t.isEmpty { parts.append(t) }
    let topic = i.topic.trimmingCharacters(in: .whitespacesAndNewlines)
    if !topic.isEmpty { parts.append(topic) }
    let names = splitList(i.names).joined(separator: ", ")
    if !names.isEmpty { parts.append(names) }
    let bad = CharacterSet(charactersIn: "/:\\")
    let joined = parts.joined(separator: " · ")
        .components(separatedBy: bad).joined(separator: "-")
        .components(separatedBy: .newlines).joined(separator: " ")
        .replacingOccurrences(of: "\t", with: " ")
    var name = String(joined.prefix(120))
    // Обрезка могла оставить висящий разделитель «… ·».
    while let last = name.last, last == " " || last == "·" { name.removeLast() }
    return name
}

/// То же по списку проектов (название по slug из `i.profile`).
public func callDirName(_ current: String, _ i: CallInfo, projects: [Project]) -> String {
    callDirName(current, i, projectTitle: projects.first { $0.slug == i.profile }?.shortTitle)
}
