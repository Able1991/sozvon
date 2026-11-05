// Проверка обновлений: раз в день смотрим последний релиз на GitHub.
// Ничего не скачиваем сами: показываем пункт в меню и одно уведомление, ссылка ведёт на страницу релиза.

import Foundation

public enum Updates {
    public static let repo = "Able1991/sozvon"
    public static let enabledKey = "checkUpdates"
    public static let lastCheckKey = "updatesLastCheck"
    public static let notifiedKey = "updatesNotifiedVersion"

    public static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    public static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Новее ли версия a, чем b: «0.10.1» > «0.9.3». Нечисловые хвосты (хеш сборки) игнорируются.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".")
                .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    public struct Release: Equatable, Sendable {
        public let version: String
        public let url: URL
        public init(version: String, url: URL) { self.version = version; self.url = url }
    }

    /// Ответ API «последний релиз»: новая версия, если она новее `current`; черновики пропускаем.
    public static func parseRelease(_ data: Data, current: String) -> Release? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = o["tag_name"] as? String, let html = (o["html_url"] as? String).flatMap(URL.init(string:)),
              o["draft"] as? Bool != true else { return nil }
        let v = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        return isNewer(v, than: current) ? Release(version: v, url: html) : nil
    }

    /// Проверить (не чаще раза в сутки, если не force): новая версия или nil.
    public static func check(force: Bool = false) async -> Release? {
        guard enabled || force else { return nil }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard force || Date().timeIntervalSince1970 - last > 86_400 else { return nil }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Sozvon/\(current)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let data = try? await URLSession.shared.data(for: req).0
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        return data.flatMap { parseRelease($0, current: current) }
    }
}
