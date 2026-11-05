// Call recording: the state machine (SozvonCore.RecordingMachine), capture, levels for the panel.
// Stop, capture failure and app quit all finalize the files through one and the same task.

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

    /// State changed: redraw the menu and panel.
    var onChange: () -> Void = {}
    /// Recording written to disk: ask "what was the call about" and transcribe.
    var onSaved: (RecordingSession) -> Void = { _ in }
    /// Answers for a new recording (last project, languages from settings).
    var initialInfo: () -> CallInfo = { CallInfo() }

    init(panel: PanelModel) {
        self.panel = panel
        recorder.onError = { [weak self] message in self?.captureFailed(message) }
    }

    // MARK: Transitions

    func toggle() {
        state.isRecording ? stop() : start()
    }

    func start() {
        guard state.canBegin else { return }  // a double click doesn't start two recordings
        // A new folder of our own right away: never overwrite or
        // delete someone else's (a recording in the same minute).
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
                // Failed to start: don't leave our empty folder behind, it would look like a recording in "Calls".
                CallFolder.discardIfUnused(dir)
                machine.startFailed()
                onChange()
                showFailure(started: false, error.localizedDescription)
            }
        }
    }

    /// "Stop": finalize the files, then the call prompt.
    func stop() {
        guard let stopped = beginStop() else { return }
        Sounds.play(.stop)
        Task {
            await stopped.finalize.value
            onSaved(stopped.session)
        }
    }

    /// Change the call details during recording ("Project and Participants").
    func updateInfo(_ info: CallInfo) {
        machine.updateInfo(info)
    }

    /// Call prompt closed: the panel no longer shows "Recorded".
    func dismissSaved(_ dir: URL) {
        if machine.dismissSaved(dir) { onChange() }
    }

    /// App quit: the task to wait for (recording running or finalizing), otherwise nil.
    func finalizeForTermination() -> Task<Void, Never>? {
        if let t = state.finalizeTask { return t }
        return beginStop()?.finalize
    }

    /// Stop capture and start the finalize task (shared by "Stop", failure and quit).
    private func beginStop() -> (session: RecordingSession, finalize: Task<Void, Never>)? {
        guard state.isRecording else { return nil }
        stopLevelTimer()
        // The task won't start until we yield the main thread, so the machine is already in stopping.
        let finalize = Task { @MainActor in
            await self.finalize()
        }
        guard let session = machine.stop(finalize: finalize) else { return nil }
        onChange()
        return (session, finalize)
    }

    /// Close the files (an m4a without an index can't be read) and write call.json.
    private func finalize() async {
        guard let session = state.session else { return }
        let audio = await recorder.stop()
        let dir = session.dir
        // call.json right at stop: the call has metadata and a permanent id even before transcription.
        CallFile.recordStopped(dir, startedAt: session.startedAt, audio: audio)
        CallFile.writeInfo(dir, session.info)
        machine.finalized()
        onChange()
    }

    /// Capture ended on its own: save what was recorded the same way as "Stop" and ask as usual.
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

    // MARK: Panel levels

    /// 10 times a second: levels for the panel and tracking of missing audio.
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

    /// Levels updated (the panel resizes to fit a warning).
    var onLevels: () -> Void = {}

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        panel.resetLevels()
    }

    #if SOZVON_PREVIEW
    /// For screenshots: machine transitions without real capture.
    func preview(_ change: (inout RecordingMachine) -> Void) {
        change(&machine)
        onChange()
    }
    #endif
}
