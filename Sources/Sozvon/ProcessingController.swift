// Расшифровка звонков: вопрос «о чём был звонок» (ответы пишутся в call.json), очередь,
// запуск `bin/process_call.py <папка>`, разбор итога в понятные уведомления и действия.

import AppKit
import SozvonCore

@MainActor
final class ProcessingController {
    private var queue = ProcessingQueue()
    /// Идущие расшифровки по папке: при выходе их останавливаем целиком (группа процессов).
    private var running: [URL: RunningProcess] = [:]
    private(set) var lastTranscript: URL?
    private(set) var lastDir: URL?
    let calls: CallsModel

    /// Очередь или обновление движка изменились: перерисовать меню и панель.
    var onChange: () -> Void = {}
    /// Открыть мастер настройки на шаге (переустановка движка, скачивание модели).
    var showSetup: (SetupModel.Step) -> Void = { _ in }
    /// Вопрос о звонке закрыт (для машины записи: убрать «Записано»).
    var onAnswered: (URL) -> Void = { _ in }

    init(calls: CallsModel) {
        self.calls = calls
        wireInstaller()
    }

    var isProcessing: Bool { queue.count > 0 }
    var isEngineUpdating: Bool { queue.engineUpdating }
    func contains(_ dir: URL) -> Bool { queue.contains(dir) }

    // MARK: Вопрос о звонке

    /// Запись сохранена: спросить, о чём был звонок, и расшифровать.
    func recorded(_ session: RecordingSession) {
        lastDir = session.dir
        onChange()
        Task {
            let answer = await CallInfoPrompt.ask(session.info, title: L("О чём был звонок?"), okTitle: L("Расшифровать"))
            onAnswered(session.dir)
            guard let info = answer else { return }
            UserDefaults.standard.set(info.profile, forKey: "lastProfile")
            transcribe(session.dir, info)
        }
    }

    /// «Расшифровать заново» для звонка: ответы берутся из его call.json.
    func retranscribe(_ dir: URL) {
        let defaults = CallInfo(languages: Settings.shared.languages)
        let initial = CallFile.exists(dir) ? CallFile.info(CallFile.read(dir), fallback: defaults)
            : (Call.load(dir)?.info ?? defaults)
        Task {
            guard let info = await CallInfoPrompt.ask(initial, title: L("Расшифровать заново"), okTitle: L("Расшифровать"))
            else { return }
            transcribe(dir, info)
        }
    }

    func retranscribeLast() {
        if let lastDir { retranscribe(lastDir) }
    }

    /// Записать ответы в call.json и поставить в очередь.
    func transcribe(_ dir: URL, _ info: CallInfo) {
        CallFile.writeInfo(dir, info)
        enqueue(dir)
    }

    // MARK: Очередь

    private func enqueue(_ dir: URL) {
        switch queue.admit(dir) {
        case .duplicate:
            // Папка уже расшифровывается: второй запуск и переименование под ним ломали вывод.
            notify(L("Уже расшифровывается"), dir.lastPathComponent)
        case .queued:
            notify(L("Расшифрую после обновления движка"), dir.lastPathComponent)
        case .start:
            run(dir)
        }
        syncCalls()
    }

    private func syncCalls() {
        calls.processing = queue.active
        calls.reload()
        onChange()
    }

    /// Движок не трогаем из папки: всё о звонке он берёт из call.json.
    private func run(_ dir: URL) {
        let log = dir.appendingPathComponent("process.log")
        let tracker = OutputTracker()
        let p = Engine.runScript("process_call.py", [dir.path], log: log, onLine: { tracker.consume($0) }) { [weak self] code in
            self?.finished(dir, code: code, outcome: RunOutcome.parse(exitCode: code, result: tracker.result,
                                                                       lastLine: tracker.lastLine))
        }
        if let p, queue.contains(dir) { running[dir] = p }
    }

    /// Выход из приложения посреди расшифровки: остановить движок (иначе он умирал от закрытой трубы,
    /// а call.json навсегда оставался `processing`) и пометить звонки `failed`, их можно расшифровать заново.
    func abortAll() {
        for (dir, p) in running {
            p.terminate()
            CallFile.setStatus(dir, .failed)
        }
        running = [:]
    }

    private func finished(_ dirIn: URL, code: Int32, outcome: RunOutcome) {
        queue.finish(dirIn)
        running[dirIn] = nil
        var dir = dirIn
        let log = dir.appendingPathComponent("process.log")
        if outcome.isOK {
            // Красивое имя папки только после успеха: пока движок пишет в папку, её не трогаем.
            // Имена берём из call.json: движок мог их уточнить.
            dir = renameCallDir(dir)
            if lastDir == dirIn { lastDir = dir }
        } else {
            CallFile.setStatus(dir, .failed)
            Engine.recordFailure(outcome.message.isEmpty ? L("Код завершения %@", code) : outcome.message, log: log)
        }
        syncCalls()
        report(outcome, dir: dir, log: dir.appendingPathComponent("process.log"))
    }

    /// Уведомление по итогу (контракт, раздел 5).
    private func report(_ outcome: RunOutcome, dir: URL, log: URL) {
        let transcript = dir.appendingPathComponent("transcript.md")
        switch outcome {
        case .ok:
            guard FileManager.default.fileExists(atPath: transcript.path) else {
                notify(L("Не получилось расшифровать"), L("Движок не оставил transcript.md"), action: .openLog, url: log)
                return
            }
            lastTranscript = transcript
            notify(L("Расшифровка готова"), dir.lastPathComponent, url: transcript)
            Sounds.play(.done)
            NSWorkspace.shared.open(transcript)
        case .noAudio:
            notify(L("В записи нет звука"), L("Ни одна дорожка не записалась. Проверь разрешения на микрофон и запись экрана."),
                   action: .permissions)
        case .engineBroken(let m):
            notify(L("Движок сломан"), m.isEmpty ? L("Переустанови движок в настройках") : m, action: .reinstallEngine)
        case .modelMissing(let m):
            notify(L("Модель не скачана"), m.isEmpty ? L("Скачай модель распознавания") : m, action: .downloadModel)
        case .damaged:
            notify(L("Запись повреждена"), L("Не удалось прочитать дорожки звонка. Подробности в process.log"),
                   action: .openLog, url: log)
        case .failed(_, let m):
            notify(L("Не получилось расшифровать"), m.isEmpty ? L("Подробности в process.log") : m, action: .openLog, url: log)
            NSWorkspace.shared.open(log)
        }
    }

    /// «2026-11-04 15-01 · Проект · тема · люди». Дата в начале (id звонка) не меняется.
    private func renameCallDir(_ dir: URL) -> URL {
        let info = CallFile.info(CallFile.read(dir))
        let newName = callDirName(dir.lastPathComponent, info, projects: Project.all())
        guard newName != dir.lastPathComponent else { return dir }
        let target = dir.deletingLastPathComponent().appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: target.path),
              (try? FileManager.default.moveItem(at: dir, to: target)) != nil else { return dir }
        return target
    }

    // MARK: Обновление движка

    /// После обновления приложения: подтянуть окружение движка (uv sync, модели) в фоне.
    /// Запись при этом работает; расшифровки ждут конца обновления. Установка из мастера
    /// идёт через того же владельца (EngineInstaller), поэтому две setup.sh не запускаются.
    func updateEngineIfNeeded() {
        let state = EngineState.evaluate(data: Paths.data, model: Settings.shared.model, isDevEngine: Paths.isDevEngine)
        guard state == .needsUpdate else { return }
        EngineInstaller.shared.run(.background)
    }

    /// Любая установка движка (фоновая или из мастера) держит очередь расшифровок.
    private func wireInstaller() {
        let installer = EngineInstaller.shared
        installer.willStart = { [weak self] in
            guard let self else { return }
            _ = self.queue.beginEngineUpdate()
            self.onChange()
        }
        installer.didFinish = { [weak self] owner, ok in
            guard let self else { return }
            if owner == .background && !ok {
                Engine.recordFailure(L("Не получилось обновить движок"), log: Paths.setupLog)
                notify(L("Не получилось обновить движок"), L("Подробности в setup.log"), action: .openLog, url: Paths.setupLog)
            }
            MCPServer.shared.restart()
            for dir in self.queue.endEngineUpdate() { self.enqueue(dir) }
            self.onChange()
        }
    }

    // MARK: Действия из уведомлений

    func handle(_ action: NotifyAction, url: URL?) {
        switch action {
        case .open, .openLog:
            if let url { NSWorkspace.shared.open(url) }
        case .permissions:
            Permissions.openPane(Permissions.screen ? "Privacy_Microphone" : "Privacy_ScreenCapture")
        case .reinstallEngine, .downloadModel:
            showSetup(.install)
        }
    }

    #if SOZVON_PREVIEW
    /// Для скриншотов: состояние «идёт расшифровка» без движка.
    func preview(processing dir: URL?, lastTranscript: URL? = nil) {
        if let dir { _ = queue.admit(dir) } else { for d in queue.active { queue.finish(URL(fileURLWithPath: d)) } }
        if let lastTranscript { self.lastTranscript = lastTranscript }
        onChange()
    }
    #endif
}

/// Последняя строка вывода и строка RESULT (на главном потоке, по мере вывода).
@MainActor
private final class OutputTracker {
    var lastLine: String?
    var result: RunOutcome.ResultLine?

    func consume(_ line: String) {
        if let r = RunOutcome.parseLine(line) { result = r }
        if !line.trimmingCharacters(in: .whitespaces).isEmpty { lastLine = line }
    }
}
