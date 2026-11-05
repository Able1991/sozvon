// Запись звонка: машина состояний (SozvonCore.RecordingMachine), захват, уровни в панель.
// Остановка, сбой захвата и выход из приложения дописывают файлы одной и той же задачей.

import AppKit
import AVFoundation
import SozvonCore

@MainActor
final class RecordingController {
    private(set) var machine = RecordingMachine()
    var state: RecordingState { machine.state }

    private let recorder = Recorder()
    private let panel: PanelModel
    private var levelTimer: Timer?
    private var monitor = SignalMonitor()

    /// Состояние сменилось: перерисовать меню и панель.
    var onChange: () -> Void = {}
    /// Запись дописана на диск: спросить «о чём был звонок» и расшифровать.
    var onSaved: (RecordingSession) -> Void = { _ in }
    /// Ответы для новой записи (последний проект, языки из настроек).
    var initialInfo: () -> CallInfo = { CallInfo() }

    init(panel: PanelModel) {
        self.panel = panel
        recorder.onError = { [weak self] message in self?.captureFailed(message) }
    }

    // MARK: Переходы

    func toggle() {
        state.isRecording ? stop() : start()
    }

    func start() {
        guard state.canBegin else { return }  // двойной клик не запускает две записи
        // Своя новая папка сразу: чужую (запись в ту же минуту) не затираем и не удаляем.
        let dir: URL
        do {
            dir = try CallFolder.create(in: Paths.calls)
        } catch {
            showFailure(started: false, error.localizedDescription)
            return
        }
        guard machine.begin(dir) else { CallFolder.discardIfUnused(dir); return }
        onChange()
        Task {
            guard await checkPermissions() else {
                CallFolder.discardIfUnused(dir)
                machine.startFailed()
                onChange()
                return
            }
            do {
                try await recorder.start(into: dir)
                machine.started(RecordingSession(dir: dir, startedAt: Date(), info: initialInfo()))
                startLevelTimer()
                Sounds.play(.start)
                onChange()
            } catch {
                // Не стартовала: свою пустую папку не оставляем, в «Звонках» она выглядела бы записью.
                CallFolder.discardIfUnused(dir)
                machine.startFailed()
                onChange()
                showFailure(started: false, error.localizedDescription)
            }
        }
    }

    /// «Стоп»: дописать файлы, потом вопрос о звонке.
    func stop() {
        guard let stopped = beginStop() else { return }
        Sounds.play(.stop)
        Task {
            await stopped.finalize.value
            onSaved(stopped.session)
        }
    }

    /// Поменять ответы о звонке во время записи («Проект и собеседники»).
    func updateInfo(_ info: CallInfo) {
        machine.updateInfo(info)
    }

    /// Вопрос о звонке закрыт: панель больше не показывает «Записано».
    func dismissSaved(_ dir: URL) {
        if machine.dismissSaved(dir) { onChange() }
    }

    /// Выход из приложения: задача, которую надо дождаться (запись идёт или дописывается), иначе nil.
    func finalizeForTermination() -> Task<Void, Never>? {
        if let t = state.finalizeTask { return t }
        return beginStop()?.finalize
    }

    /// Остановить захват и запустить задачу дописывания (общая для «Стоп», сбоя и выхода).
    private func beginStop() -> (session: RecordingSession, finalize: Task<Void, Never>)? {
        guard state.isRecording else { return nil }
        stopLevelTimer()
        // Задача начнёт работу не раньше, чем мы отдадим главный поток: машина уже будет в stopping.
        let finalize = Task { @MainActor in
            await self.finalize()
        }
        guard let session = machine.stop(finalize: finalize) else { return nil }
        onChange()
        return (session, finalize)
    }

    /// Закрыть файлы (иначе m4a без индекса не читается) и записать call.json.
    private func finalize() async {
        guard let session = state.session else { return }
        let audio = await recorder.stop()
        let dir = session.dir
        // call.json сразу при остановке: у звонка есть метаданные и постоянный id ещё до расшифровки.
        CallFile.recordStopped(dir, startedAt: session.startedAt, audio: audio)
        CallFile.writeInfo(dir, session.info)
        machine.finalized()
        onChange()
    }

    /// Захват оборвался сам: сохранить записанное тем же путём, что и «Стоп», и спросить как обычно.
    private func captureFailed(_ message: String) {
        guard let stopped = beginStop() else { return }
        showFailure(started: true, message)
        Task {
            await stopped.finalize.value
            onSaved(stopped.session)
        }
    }

    private func showFailure(started: Bool, _ message: String) {
        let alert = NSAlert()
        alert.messageText = started ? L("Запись прервалась") : L("Не удалось начать запись")
        alert.informativeText = L("%@\n\nПроверь разрешения: Системные настройки → Конфиденциальность и безопасность → «Запись экрана и системного аудио» и «Микрофон». После включения перезапусти Sozvon.", message)
        alert.addButton(withTitle: L("Открыть настройки"))
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { Permissions.openPane("Privacy_ScreenCapture") }
    }

    private func checkPermissions() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if Permissions.mic && Permissions.screen { return true }
        let alert = NSAlert()
        alert.messageText = L("Нужны разрешения")
        var missing: [String] = []
        if !Permissions.screen { missing.append(L("«Запись экрана и системного аудио»")) }
        if !Permissions.mic { missing.append(L("«Микрофон»")) }
        alert.informativeText = L("Включи Sozvon в Системных настройках → Конфиденциальность и безопасность → %@. После записи экрана перезапусти Sozvon.",
                                  missing.joined(separator: L(" и ")))
        alert.addButton(withTitle: L("Открыть настройки"))
        alert.addButton(withTitle: L("Отмена"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if !Permissions.screen { Permissions.requestScreen() } else { Permissions.openPane("Privacy_Microphone") }
        }
        return false
    }

    // MARK: Уровни для панели

    /// 10 раз в секунду: уровни в панель и учёт пропавшего звука.
    private func startLevelTimer() {
        monitor = SignalMonitor()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleLevels() }
        }
        RunLoop.main.add(t, forMode: .common)
        levelTimer = t
    }

    private func sampleLevels() {
        let m = recorder.meters
        let r = monitor.update(now: Date(), mic: (m.mic.level, m.mic.lastBufferAt),
                               system: (m.system.level, m.system.lastBufferAt))
        panel.push(mic: r.mic, sys: r.system)
        panel.systemSilent = r.systemSilent
        panel.micMissing = r.micMissing
        onLevels()
    }

    /// Уровни обновились (панель подгоняет размер под предупреждение).
    var onLevels: () -> Void = {}

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        panel.resetLevels()
    }

    #if SOZVON_PREVIEW
    /// Для скриншотов: переходы машины без настоящего захвата.
    func preview(_ change: (inout RecordingMachine) -> Void) {
        change(&machine)
        onChange()
    }
    #endif
}
