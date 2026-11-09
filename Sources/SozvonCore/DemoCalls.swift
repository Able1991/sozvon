// Demo calls: a few fictional calls (text only, no audio) added from Settings > Assistants so that
// list_calls, search_calls, get_commitments and get_person have something to show before the first recording.
// The content is the fictional part of tools/demo_data.py (no real clients). Each call.json carries
// `"demo": true`; that flag alone decides what "Remove" touches, and the engine's sync skips such calls.
// No project and no voice print is created, so nothing is left behind after removal.

import Foundation

public enum DemoCalls {
    public static let key = "demo"

    /// A call is a demo only with a real JSON `true`.
    public static func isDemo(_ c: [String: Any]) -> Bool { c[key] as? Bool == true }

    struct Spec {
        let daysAgo: Int
        let hour: Int, minute: Int
        let topic: String
        let others: [String]
        let seconds: Int
        let languages: String
        let summary: String
        /// (seconds, speaker, text); "Я" is the user.
        let lines: [(Int, String, String)]
    }

    // l10n-ignore-start: fictional call content, written to files as it is (like tools/demo_data.py)
    static let specs: [Spec] = [
        Spec(daysAgo: 1, hour: 15, minute: 30, topic: "billing webhooks", others: ["Sarah Miller", "Tom Baker"],
             seconds: 22 * 60 + 43, languages: "ru,en", summary: """
             ## Коротко
             Договорились о схеме вебхуков для счетов: Northwind отправляет события с подписью в заголовке, повтор при ошибке до трёх раз с паузой. Ключи для песочницы придут в пятницу, боевые после приёмки.

             ## Решения
             - Подпись запроса: HMAC в заголовке `X-Signature`, ключ выдаёт Northwind.
             - Повторы: 3 попытки, пауза 30 с, 5 мин, 30 мин.
             - Событие invoice.paid уходит один раз, дубли режем по id.

             ## Задачи
             - [ ] Sarah Miller: Прислать ключи для песочницы, пятница
             - [ ] Tom Baker: Описать формат событий в документации
             - [ ] Я: Проверить повторы на тестовом стенде
             """, lines: [
                (3, "Я", "Привет, Sarah. Давай пройдёмся по вебхукам для счетов, у нас было три открытых вопроса."),
                (9, "Sarah Miller", "Sure. We need a retry policy and a signature header, and I want to agree on the event names before the sandbox keys go out."),
                (31, "Я", "По подписи предлагаю HMAC в заголовке, ключ выдаёте вы. Повторы: три попытки с растущей паузой."),
                (58, "Tom Baker", "Works for me. Thirty seconds, five minutes, thirty minutes. After that we flag it on our side."),
                (102, "Я", "Договорились: ключи для песочницы в пятницу, боевые после приёмки."),
                (135, "Sarah Miller", "One more thing: invoice.paid must be sent exactly once. If you retry, we dedupe by id, so keep the id stable."),
                (194, "Я", "Да, id не меняем между повторами. Tom, опишешь формат событий в документации к среде?"),
                (220, "Tom Baker", "Yes, I'll have a draft by Wednesday and share the link in the thread."),
             ]),
        Spec(daysAgo: 1, hour: 11, minute: 0, topic: "планирование спринта", others: ["Олег", "Иван Петров"],
             seconds: 48 * 60 + 12, languages: "ru", summary: """
             ## Коротко
             Спланировали спринт: API заказов, экран профиля и починка push-уведомлений. Олег берёт API, Иван экран профиля.

             ## Решения
             - Спринт две недели, демо в пятницу.
             - Push-уведомления чиним до новых фич.

             ## Задачи
             - [ ] Олег: API заказов, среда
             - [ ] Иван Петров: Экран профиля, пятница
             """, lines: [
                (4, "Я", "Начнём. Что берём в спринт?"),
                (11, "Олег", "Предлагаю API заказов и экран профиля, и сначала починить push-уведомления."),
                (27, "Иван Петров", "Экран профиля мой, к пятнице успею."),
             ]),
        Spec(daysAgo: 2, hour: 17, minute: 45, topic: "съёмка для каталога", others: ["Екатерина Лебедева"],
             seconds: 31 * 60 + 4, languages: "ru", summary: """
             ## Коротко
             Обсудили съёмку для каталога: 40 образов, два дня в студии, ретушь за неделю.

             ## Задачи
             - [ ] Екатерина Лебедева: Список образов, вторник
             """, lines: [
                (5, "Екатерина Лебедева", "Предлагаю снимать два дня: первый день одежда, второй аксессуары."),
                (19, "Я", "Подходит. Ретушь успеете за неделю?"),
             ]),
        Spec(daysAgo: 2, hour: 10, minute: 30, topic: "онбординг Sarah", others: ["Sarah Miller"],
             seconds: 14 * 60 + 2, languages: "en", summary: """
             ## Summary
             Walked Sarah through the API sandbox and the billing dashboard.

             ## Action Items
             - [ ] Sarah Miller: Share the test account list
             """, lines: [
                (3, "Я", "Sarah, welcome! Let me show you the sandbox first."),
                (12, "Sarah Miller", "Great, I mostly need the billing endpoints."),
             ]),
    ]
    // l10n-ignore-end

    /// Folders of the demo calls in `root`: only those whose call.json says `"demo": true`.
    public static func existing(in root: URL = Paths.calls) -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.filter { $0.hasDirectoryPath && isDemo(CallFile.read($0)) }.sorted { $0.path < $1.path }
    }

    /// Write the demo calls, dated relative to `now` (the calls of "yesterday" and the day before).
    /// Does nothing when they are already there. -> the new folders.
    @discardableResult
    public static func add(to root: URL = Paths.calls, now: Date = Date()) throws -> [URL] {
        guard existing(in: root).isEmpty else { return [] }
        let cal = Calendar.current
        var out: [URL] = []
        for s in specs {
            let day = cal.date(byAdding: .day, value: -s.daysAgo, to: cal.startOfDay(for: now)) ?? now
            let at = cal.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: day) ?? day
            let dir = try CallFolder.create(in: root, at: at)
            let id = CallFile.callID(dir)
            let ok = CallFile.update(dir) { c in
                c["status"] = CallStatus.done.rawValue
                c[key] = true
                c["topic"] = s.topic
                c["names"] = s.others
                c["languages"] = s.languages
                c["summary"] = true
                c["audio"] = ["mic_start": 0.0, "system_start": 0.0,
                              "mic_seconds": Double(s.seconds), "system_seconds": Double(s.seconds)]
                c["engine"] = ["version": "demo"]
            }
            guard ok else { throw POSIXError(.EIO) }
            try s.summary.trimmingCharacters(in: .whitespacesAndNewlines).appending("\n")
                .write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
            try (s.lines.map { "[\(clock($0.0))] \($0.1): \($0.2)" }.joined(separator: "\n") + "\n")
                .write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
            try markdown(s, id: id).write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            out.append(dir)
        }
        return out
    }

    /// Hand each demo call folder to `recycle` (the app moves it to the Trash). Never anything else.
    public static func remove(in root: URL = Paths.calls, recycle: (URL) throws -> Void) throws {
        for dir in existing(in: root) { try recycle(dir) }
    }

    private static func clock(_ t: Int) -> String { String(format: "%02d:%02d", t / 60, t % 60) }

    // l10n-ignore-start: transcript.md is an engine file format, not UI
    /// transcript.md in the shape the engine writes it, summary first; newer than summary.md.
    private static func markdown(_ s: Spec, id: String) -> String {
        let people = (["Я"] + s.others).joined(separator: ", ")
        var md = ["# Звонок \(id) · \(s.topic)", "", "Длительность: \(clock(s.seconds)) · Участники: \(people)", "",
                  s.summary.trimmingCharacters(in: .whitespacesAndNewlines), "", "---", "", "## Расшифровка", ""]
        md += s.lines.map { "**[\(clock($0.0))] \($0.1):** \($0.2)\n" }
        return md.joined(separator: "\n")
    }
    // l10n-ignore-end
}
