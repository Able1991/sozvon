// "Connect Cloudflare" in the Cloud tab: sign in, set up the server in the user's account, save it, sync.
// The logic is in SozvonCore (Cloudflare.swift); this is the state for the UI.

import AppKit
import SozvonCore

@MainActor
final class CloudflareConnector: ObservableObject {
    static let shared = CloudflareConnector()

    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
        case done
    }

    @Published private(set) var phase = Phase.idle
    /// Lines after Connect: the connectors must sign in again (a new password on an existing server),
    /// or the password copy for the user's other Macs could not be saved in the Cloudflare account.
    @Published private(set) var notice: String?
    /// Several accounts: the sheet to pick one is shown while this is not empty.
    @Published private(set) var accounts: [CloudflareAPI.Account] = []

    private var task: Task<Void, Never>?
    private var choice: CheckedContinuation<CloudflareAPI.Account?, Never>?

    /// The Worker is bundled only when build.sh found Node.js.
    let bundle = WorkerBundle.bundled
    var isAvailable: Bool { bundle != nil }
    var isWorking: Bool { if case .working = phase { return true } else { return false } }
    var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    /// The bundled server is newer than the one that answered /api/health.
    func canUpdate(serverVersion: String?) -> Bool {
        guard let bundle, let v = serverVersion, !v.isEmpty else { return false }
        return Updates.isNewer(bundle.manifest.version, than: v)
    }

    func start() {
        guard task == nil, let bundle else { return }
        task = Task {
            await run(bundle)
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        choose(nil)
    }

    func choose(_ account: CloudflareAPI.Account?) {
        accounts = []
        choice?.resume(returning: account)
        choice = nil
    }

    private func run(_ bundle: WorkerBundle) async {
        let show: @MainActor @Sendable (String) -> Void = { [weak self] in self?.phase = .working($0) }
        do {
            show(L("Вход в Cloudflare…"))
            let token = try await CloudflareOAuth.signIn { url in
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            NSApp.activate()
            // Cooperative activation (macOS 14+) may keep the browser frontmost: at least show the window on top.
            WindowsRegistry.shared.window("settings")?.orderFrontRegardless()
            let api = CloudflareAPI(token: token)
            let all = try await api.accounts()
            guard !all.isEmpty else { throw CloudflareError(L("В Cloudflare не выбран ни один аккаунт: войди ещё раз и отметь аккаунт")) }
            let account: CloudflareAPI.Account
            if all.count == 1 {
                account = all[0]
            } else {
                guard let a = await pick(all) else { throw CancellationError() }
                account = a
            }
            try Task.checkCancellation()
            let plan = try await CloudflareDeploy.prepare(api: api, account: account, progress: show)
            // The same server again (update, repair): keep its password, so connectors stay signed in.
            // A new Mac taking over the server: the copy kept in the server's KV namespace, if the server
            // still takes it. Otherwise a new one, and the connectors sign in again.
            let s = Settings.shared
            notice = nil
            var notes: [String] = []
            let (password, choice) = await ServerPasswords.choose(
                server: plan.serverURL, savedURL: s.serverURL, savedPassword: s.serverPassword,
                replacesServer: plan.replacesServer,
                stored: {
                    do { return try await CloudflareDeploy.storedPassword(api: api, plan: plan) } catch { return nil }
                },
                accepts: { await OwnServer.accepts($0, password: $1) })
            try Task.checkCancellation()
            try await CloudflareDeploy.upload(api: api, plan: plan, bundle: bundle, password: password, progress: show)
            // The server has this password now: save it before anything else can fail or time out.
            do {
                try ServerSync.shared.adopt(url: plan.serverURL, password: password)
            } catch {
                throw CloudflareError(L("Сервер настроен, но пароль не сохранился в настройках (%@). Нажми «Подключить Cloudflare» ещё раз",
                                        error.localizedDescription))
            }
            do {
                try await CloudflareDeploy.storePassword(password, api: api, plan: plan)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                notes.append(L("Копия пароля для других Mac не сохранилась в Cloudflare (%@): на другом Mac подключение сменит пароль",
                               error.localizedDescription))
            }
            if choice == .new(signInAgain: true) {
                notes.insert(L("Пароль сервера новый: войди в коннекторах Claude и ChatGPT ещё раз"), at: 0)
            }
            notice = notes.isEmpty ? nil : notes.joined(separator: "\n")
            show(L("Жду, пока сервер запустится…"))
            _ = try await CloudflareDeploy.waitForHealth(plan.serverURL)
            show(L("Синхронизирую звонки…"))
            await ServerSync.shared.checkAndSync(plan.serverURL)
            phase = .done
        } catch {
            // "Cancel" at any step (also during the token exchange) returns to the start quietly.
            if error is CancellationError || Task.isCancelled {
                phase = .idle
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func pick(_ list: [CloudflareAPI.Account]) async -> CloudflareAPI.Account? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                choice = c
                accounts = list
            }
        } onCancel: {
            Task { @MainActor in self.choose(nil) }
        }
    }
}
