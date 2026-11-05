// Звонок для списка «Звонки»: всё о нём берётся из call.json. Имя папки разбирается только
// для старых звонков без call.json, и только для показа.

import Foundation

public struct Call: Identifiable, Sendable {
    public let url: URL
    public var id: String { url.path }
    /// Постоянный id звонка: «2026-11-04 15-01» (вторая запись той же минуты «2026-11-04 15-01-2»).
    public var callID: String
    public var date: Date?
    /// Тема, иначе проект, иначе «Звонок».
    public var title: String
    public var project: String
    public var topic: String
    public var languages: [SpeechLanguage]
    public var people: String
    public var duration: TimeInterval
    public var bytes: Int64
    public var hasTranscript: Bool
    public var hasSummary: Bool
    public var hasAudio: Bool
    public var info: CallInfo
    public var status: CallStatus?
    /// Старый звонок без call.json: проект и тема угаданы по имени папки.
    public var isLegacy: Bool

    public var transcriptURL: URL { url.appendingPathComponent("transcript.md") }
    public var summaryURL: URL { url.appendingPathComponent("summary.md") }
    public var logURL: URL { url.appendingPathComponent("process.log") }

    /// «2026-11-04 15-01» -> дата в текущем часовом поясе; иначе nil.
    public static func parseID(_ s: String) -> Date? {
        let s = String(s.prefix(16))
        let c = s.unicodeScalars.map { Character($0) }
        guard c.count == 16, c[4] == "-", c[7] == "-", c[10] == " ", c[13] == "-" else { return nil }
        func num(_ r: Range<Int>) -> Int? { Int(String(c[r])) }
        guard let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10), let h = num(11..<13), let mi = num(14..<16),
              (1...12).contains(mo), (1...31).contains(d), (0...23).contains(h), (0...59).contains(mi) else { return nil }
        return Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))
    }

    /// Загрузить папку звонка. `projects`: короткие названия по slug.
    /// `withSize`: посчитать размер папки (обход всех файлов, через FolderSizeCache); без него `bytes` = 0.
    public static func load(_ url: URL, projects: [String: String] = [:], defaults: CallInfo = CallInfo(),
                            withSize: Bool = false) -> Call? {
        let fm = FileManager.default
        let name = url.lastPathComponent
        func has(_ f: String) -> Bool { fm.fileExists(atPath: url.appendingPathComponent(f).path) }
        let legacy = !has(CallFile.name)

        var call = Call(url: url, callID: CallFolder.id(fromName: name), date: nil, title: "", project: "", topic: "",
                        languages: [], people: "", duration: 0, bytes: 0,
                        hasTranscript: has("transcript.md"), hasSummary: has("summary.md"),
                        hasAudio: has("mic.m4a") || has("system.m4a"), info: defaults, status: nil, isLegacy: legacy)

        if !legacy {
            let c = CallFile.read(url)
            if let id = c["id"] as? String, !id.isEmpty { call.callID = id }
            call.date = parseID(call.callID)
                ?? (c["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            call.info = CallFile.info(c, fallback: defaults)
            call.status = (c["status"] as? String).flatMap(CallStatus.init(rawValue:))
            call.duration = AudioTimes((c["audio"] as? [String: Any]) ?? [:]).duration
            call.languages = (c["languages"] as? String).map(SpeechLanguage.parse) ?? []
            call.topic = call.info.topic.isEmpty ? call.info.terms : call.info.topic
            call.project = call.info.profile.isEmpty ? "" : (projects[call.info.profile] ?? call.info.profile)
            call.people = splitList(call.info.names).joined(separator: ", ")
        } else {
            // До контракта 1: «дата · проект · тема · люди» в имени папки, длительность в meta.json.
            call.date = parseID(name)
            guard call.date != nil || has("meta.json") else { return nil }
            if let d = try? Data(contentsOf: url.appendingPathComponent("meta.json")),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                call.duration = AudioTimes(o).duration
            }
            let parts = Array(name.components(separatedBy: " · ").dropFirst())
            call.project = parts.count >= 2 ? parts[0] : ""
            call.topic = parts.count >= 2 ? parts[1] : (parts.count == 1 ? parts[0] : "")
            call.people = parts.count >= 3 ? parts[2...].joined(separator: " · ") : ""
            call.info.names = call.people
        }
        call.title = !call.topic.isEmpty ? call.topic : (!call.project.isEmpty ? call.project : L("Звонок"))
        if withSize { call.bytes = FolderSizeCache.shared.size(url) }
        return call
    }

    static func folderSize(_ url: URL) -> Int64 {
        var bytes: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e { bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return bytes
    }

    /// Все звонки папки, новые первыми. Размеры папок только с `withSizes` (это обход всех файлов).
    public static func all(in dir: URL = Paths.calls, projects: [String: String] = [:],
                           defaults: CallInfo = CallInfo(), withSizes: Bool = false) -> [Call] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.filter { $0.hasDirectoryPath }
            .compactMap { load($0, projects: projects, defaults: defaults, withSize: withSizes) }
            .sorted {
                let a = $0.date ?? .distantPast, b = $1.date ?? .distantPast
                // Две записи в одну минуту: «…15-01-2» новее «…15-01».
                return a != b ? a > b : $0.callID.compare($1.callID, options: .numeric) == .orderedDescending
            }
    }

    /// «37 МБ», «1,2 ГБ»: размер всей папки звонка.
    public var sizeText: String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : ""
    }

    public var durationText: String { Call.clock(Int(duration)) }

    /// «12:34» или «1:02:03»; пусто для нуля.
    public static func clock(_ t: Int, empty: String = "") -> String {
        guard t > 0 else { return empty }
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
