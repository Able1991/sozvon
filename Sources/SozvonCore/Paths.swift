// Пути приложения и локализация строк.

import Foundation

/// Локализованная строка. Ключ: русский текст, %@ на месте подстановок.
/// Переводы лежат в бандле приложения (Sources/Sozvon/Resources/<язык>.lproj/Localizable.strings),
/// поэтому берём Bundle.main, а не бандл модуля. Проверка: tools/l10n.py check.
public func L(_ key: String, _ args: Any...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    guard !args.isEmpty else { return format }
    return String(format: format, arguments: args.map { "\($0)" as NSString })
}

public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Путь из настроек (defaults write io.github.able1991.sozvon <ключ> <путь>), если задан.
    private static func override(_ key: String) -> URL? {
        guard let p = UserDefaults.standard.string(forKey: key), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }

    /// Папка данных движка (SOZVON_DATA_DIR): venv, модели, .env, словарь, проекты.
    /// Для разработки можно указать свою: defaults write io.github.able1991.sozvon engineDir <путь>
    public static var data: URL {
        override("engineDir") ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sozvon")
    }

    /// Свой движок разработчика: код не перезаписываем из бандла.
    public static var isDevEngine: Bool { override("engineDir") != nil }

    public static var python: URL { data.appendingPathComponent(".venv/bin/python3") }
    public static var profiles: URL { data.appendingPathComponent("profiles") }
    public static var env: URL { data.appendingPathComponent(".env") }
    public static var setupLog: URL { data.appendingPathComponent("setup.log") }
    public static var mcpLog: URL { data.appendingPathComponent("mcp.log") }

    /// Папка звонков (SOZVON_CALLS_DIR). Для демо и скриншотов: defaults write … callsDir <путь>
    public static var calls: URL {
        override("callsDir") ?? home.appendingPathComponent("Documents/Calls")
    }

    /// Журналы самого приложения (формат дорожек записи и т.п.).
    public static var logs: URL { home.appendingPathComponent("Library/Logs/Sozvon") }

    /// Движок, вложенный в бандл приложения.
    public static var bundledEngine: URL? { Bundle.main.resourceURL?.appendingPathComponent("engine") }

    /// Скрипт движка (контракт, раздел 3): `<data>/bin/<имя>`.
    /// Разработчик может указать свою папку: defaults write … scriptsDir <путь>
    public static func engineScript(_ name: String) -> URL {
        engineScript(name, data: data, override: override("scriptsDir"))
    }

    public static func engineScript(_ name: String, data: URL, override: URL? = nil) -> URL {
        (override ?? data.appendingPathComponent("bin")).appendingPathComponent(name)
    }
}

/// Файл с секретом (.env, пароль MCP): права 600 с момента создания, а не chmod после записи,
/// когда содержимое уже успело полежать открытым. Запись атомарная: временный файл рядом и rename.
public enum PrivateFile {
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = fchmod(fd, 0o600) == 0  // umask мог урезать, но не расширить; на всякий случай явно
        data.withUnsafeBytes { buf in
            var off = 0
            while ok, off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { ok = false } else { off += n }
            }
        }
        if ok { ok = fsync(fd) == 0 }
        close(fd)
        guard ok, rename(tmp.path, url.path) == 0 else {
            let e = errno
            unlink(tmp.path)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
    }
}
