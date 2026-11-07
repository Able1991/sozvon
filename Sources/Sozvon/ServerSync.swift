// Copies of finished calls on the user's own server: runs `bin/sync_server.py` in the background,
// one run at a time, and keeps a one-line status for Settings (docs/CONTRACT.md).

import Foundation
import SozvonCore

@MainActor
final class ServerSync: ObservableObject {
    static let shared = ServerSync()

    @Published private(set) var isRunning = false
    /// One line for Settings: progress, the result or the error.
    @Published private(set) var status = ""
    @Published private(set) var failed = false
    /// MCP address of the server for a Claude or ChatGPT connector: set once /api/health answered.
    @Published private(set) var connectorURL: URL?
    /// Version from /api/health of the checked server ("" when it did not say).
    @Published private(set) var serverVersion: String?

    private var again = false
    private var pending: Task<Void, Never>?
    /// Address and password of the last successful check: the same values saved again (Connect Cloudflare
    /// saves them and checks right away) don't start a second check.
    private var checked: (url: String, password: String)?

    /// Address or password saved by hand (Enter or "Save" in the Cloud tab, never per keystroke: every wrong
    /// password counts towards the server's lockout). One health check, one password check, then a sync.
    func settingsChanged() {
        let s = Settings.shared
        if let c = checked, c.url == s.serverURL, c.password == s.serverPassword { return }
        pending?.cancel()
        connectorURL = nil
        serverVersion = nil
        checked = nil
        guard s.hasServer, let url = OwnServer.normalize(s.serverURL) else {
            set(s.serverURL.isEmpty ? "" : (OwnServer.normalize(s.serverURL) == nil
                ? L("Адрес должен начинаться с https://") : L("Укажи пароль сервера")), failed: !s.serverURL.isEmpty)
            return
        }
        pending = Task { await checkAndSync(url, verifyPassword: true) }
    }

    /// Connect Cloudflare: the address and password it just set on the server, saved right away (before the
    /// server is up), so a timeout later never loses them. Throws when `.env` can't be written.
    func adopt(url: URL, password: String) throws {
        let s = Settings.shared
        pending?.cancel()
        s.serverURL = url.absoluteString
        s.serverPassword = password
        try s.write()
    }

    /// "Check": the server answers like ours, then a full sync. `verifyPassword`: a password typed by hand,
    /// checked once before the sync (GET /api/calls), so a wrong one never starts the sync.
    func checkAndSync(_ url: URL? = nil, verifyPassword: Bool = false) async {
        guard let url = url ?? OwnServer.normalize(Settings.shared.serverURL) else { return }
        set(L("Проверяю сервер…"), failed: false)
        switch await OwnServer.checkHealth(url) {
        case .ok(let version):
            if verifyPassword {
                let ok = await OwnServer.accepts(url, password: Settings.shared.serverPassword)
                guard !Task.isCancelled else { return }
                guard ok else {
                    connectorURL = nil
                    serverVersion = nil
                    checked = nil
                    set(L("Сервер не принял пароль"), failed: true)
                    return
                }
            }
            connectorURL = url.appendingPathComponent("mcp")
            serverVersion = version
            checked = (Settings.shared.serverURL, Settings.shared.serverPassword)
            set(version.isEmpty ? L("Сервер на связи") : L("Сервер на связи, версия %@", version), failed: false)
            sync()
        case .failed(let m):
            connectorURL = nil
            serverVersion = nil
            checked = nil
            set(m, failed: true)
        }
    }

    /// Settings opened: check the saved server once, to show the connector address (no sync).
    func refresh() async {
        guard connectorURL == nil, let url = OwnServer.normalize(Settings.shared.serverURL), Settings.shared.hasServer
        else { return }
        switch await OwnServer.checkHealth(url) {
        case .ok(let version):
            connectorURL = url.appendingPathComponent("mcp")
            serverVersion = version
            checked = (Settings.shared.serverURL, Settings.shared.serverPassword)
        case .failed(let m): if status.isEmpty { set(m, failed: true) }
        }
    }

    /// Full sync in the background (after a transcription, a deletion, a settings change).
    /// Asked again while running: one more run after this one.
    func sync() {
        guard Settings.shared.hasServer else { return }
        guard !isRunning else { again = true; return }
        isRunning = true
        let out = SyncOutput()
        Engine.runScript("sync_server.py", log: Paths.data.appendingPathComponent("server-sync.log"), onLine: { [weak self] line in
            out.consume(line)
            if line.hasPrefix("STATUS: ") { self?.set(String(line.dropFirst("STATUS: ".count)), failed: false) }
        }) { [weak self] code in
            self?.finished(code: code, out: out)
        }
    }

    private func finished(code: Int32, out: SyncOutput) {
        isRunning = false
        let last = out.last
        switch out.result {
        case .ok(let sent, let deleted, let downloaded, let trashed, let notSent)?:
            set(OwnServer.syncSummary(sent: sent, deleted: deleted, downloaded: downloaded, trashed: trashed, failed: notSent,
                                      time: Date().formatted(date: .omitted, time: .shortened)), failed: notSent > 0)
        case .failed(_, let m)?:
            set(m, failed: true)
        case nil:
            set(last.isEmpty ? L("Код завершения %@", code) : last, failed: true)
        }
        if again {
            again = false
            sync()
        }
    }

    private func set(_ text: String, failed: Bool) {
        status = text
        self.failed = failed
    }
}

/// Output of one sync run: the RESULT line and the last line (for an unexpected crash).
@MainActor
private final class SyncOutput {
    var result: OwnServer.SyncResult?
    var last = ""

    func consume(_ line: String) {
        if let r = OwnServer.parseSyncResult(line) { result = r }
        if !line.trimmingCharacters(in: .whitespaces).isEmpty { last = line }
    }
}
