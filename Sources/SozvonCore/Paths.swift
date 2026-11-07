// App paths and string localization.

import Foundation

/// Localized string. The key is the Russian text, with %@ for substitutions.
/// Translations live in the app bundle (Sources/Sozvon/Resources/<lang>.lproj/Localizable.strings),
/// so we use Bundle.main rather than the module bundle. Check with: tools/l10n.py check.
public func L(_ key: String, _ args: Any...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    guard !args.isEmpty else { return format }
    return String(format: format, arguments: args.map { "\($0)" as NSString })
}

public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Path from defaults (defaults write io.github.able1991.sozvon <key> <path>), if set.
    private static func override(_ key: String) -> URL? {
        guard let p = UserDefaults.standard.string(forKey: key), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }

    /// Engine data folder (SOZVON_DATA_DIR): venv, models, .env, dictionary, projects.
    /// For development you can point it elsewhere: defaults write io.github.able1991.sozvon engineDir <path>
    public static var data: URL {
        override("engineDir") ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sozvon")
    }

    /// Developer's own engine: don't overwrite its code from the bundle.
    public static var isDevEngine: Bool { override("engineDir") != nil }

    public static var python: URL { data.appendingPathComponent(".venv/bin/python3") }
    public static var profiles: URL { data.appendingPathComponent("profiles") }
    public static var env: URL { data.appendingPathComponent(".env") }
    public static var setupLog: URL { data.appendingPathComponent("setup.log") }
    public static var mcpLog: URL { data.appendingPathComponent("mcp.log") }

    /// Calls folder (SOZVON_CALLS_DIR). For demos and screenshots: defaults write … callsDir <path>
    public static var calls: URL {
        override("callsDir") ?? home.appendingPathComponent("Documents/Calls")
    }

    /// The app's own logs (recording track formats, failed Cloudflare requests). Tests point it elsewhere (logsDir).
    public static var logs: URL { override("logsDir") ?? home.appendingPathComponent("Library/Logs/Sozvon") }

    /// Engine embedded in the app bundle.
    public static var bundledEngine: URL? { Bundle.main.resourceURL?.appendingPathComponent("engine") }

    /// Engine script (contract, section 3): `<data>/bin/<name>`.
    /// Developers can point to their own folder: defaults write … scriptsDir <path>
    public static func engineScript(_ name: String) -> URL {
        engineScript(name, data: data, override: override("scriptsDir"))
    }

    public static func engineScript(_ name: String, data: URL, override: URL? = nil) -> URL {
        (override ?? data.appendingPathComponent("bin")).appendingPathComponent(name)
    }
}

/// Secret file (.env, MCP password): mode 600 from creation, not a chmod after writing
/// when the contents have already sat exposed. The write is atomic: a temp file alongside, then rename.
public enum PrivateFile {
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = fchmod(fd, 0o600) == 0  // umask could narrow but not widen the mode; set it explicitly just in case
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
