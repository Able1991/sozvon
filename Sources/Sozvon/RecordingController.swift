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
    /// "Important" presses during this recording (wall clock, seconds since 1970).
    private var marks: [Double] = []
    /// The start in progress (permissions, then the capture), for a quit that comes meanwhile.
    private var startTask: Task<Void, Never>?
    private var micWatch = SilenceWatch()
    private var systemWatch = SilenceWatch(patient: true)
    private var quietWatch = QuietMicWatch()
    private var zeroWatch = ZeroWatch()
    private var startedAt = Date()

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

    /// Setup is finished (AppDelegate.requireSetup, which brings the assistant back otherwise).
    var canStart: () -> Bool = { true }

    func start() {
        guard state.canBegin, canStart() else { return }  // a double click doesn't start two recordings
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
        startTask = Task {
            guard await checkPermissions() else {
                CallFolder.discardIfUnused(dir)
                machine.startFailed()
                onChange()
                return
            }
            do {
                let capture: Recorder.SystemCapture
                // Someone else's voice is saved: the other side's track also goes to the live match.
                let live = LiveVoices.useful
                do {
                    capture = try await recorder.start(into: dir, live: live)
                } catch where !Recorder.isTimeout(error) {
                    // Right after the permissions are granted the first start can fail ("Stream failed to
                    // start microphone") and the next one works: try once more before saying so. A start
                    // that ran out of time is not retried: that would be another 10 seconds into the call.
                    RecorderLog.write("start failed (\(error.localizedDescription)), trying once more")
                    try await Task.sleep(for: .seconds(1))
                    capture = try await recorder.start(into: dir, live: live)
                }
                machine.started(RecordingSession(dir: dir, startedAt: Date(), info: initialInfo()))
                if live { LiveVoices.shared.start(dir) }
                remindConsentIfChosen()
                marks = []
                panel.marks = 0
                startLevelTimer()
                Sounds.play(.start)
                onChange()
                if capture == .screenCapture { explainSystemAudioFallback() }
            } catch {
                // Failed to start: don't leave our empty folder behind, it would look like a recording in "Calls".
                CallFolder.discardIfUnused(dir)
                machine.startFailed()
                onChange()
                showFailure(started: false, error.localizedDescription)
            }
        }
    }


    /// Settings: "Remind me to say the call is recorded": a few seconds on the capsule, or a notification without it.
    private func remindConsentIfChosen() {
        guard CallAutomation.remindConsent() else { return }
        let text = L("Скажи собеседникам, что идёт запись")
        guard FloatingPanel.enabled else { Notifier.shared.post(text, "", sound: false); return }
        panel.hint = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.panel.hint = nil
        }
    }

    /// The other side's track has sound right now (above room noise, from a live stream).
    var otherSideAudible: Bool {
        let m = recorder.meters.system
        guard let at = m.lastBufferAt, Date().timeIntervalSince(at) < 2, !m.zero else { return false }
        return m.level > 0.15
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

    /// "Important": remember this moment; the transcript highlights it and the summary says what was said.
    func mark() {
        guard state.isRecording else { return }
        let now = Date().timeIntervalSince1970
        if let last = marks.last, now - last < CallMarks.minGap { return }
        marks.append(now)
        panel.marked()
        Sounds.play(.mark)
    }

    /// Change the call details during recording ("Project and Participants").
    func updateInfo(_ info: CallInfo) {
        machine.updateInfo(info)
    }

    /// Call prompt closed: the panel no longer shows "Recorded".
    func dismissSaved(_ dir: URL) {
        if machine.dismissSaved(dir) { onChange() }
    }

    /// App quit: the task to wait for (recording starting, running or finalizing), otherwise nil.
    /// A start in progress is waited for (it ends within Recorder.startTimeout) and then stopped: quitting
    /// past it would leave its ScreenCaptureKit stream, and the microphone, open.
    func finalizeForTermination() -> Task<Void, Never>? {
        if let t = state.finalizeTask { return t }
        if state.isStarting, let start = startTask {
            return Task { @MainActor in
                await start.value
                await self.beginStop()?.finalize.value
            }
        }
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
        let (audio, wall) = await recorder.stop()
        let dir = session.dir
        // call.json right at stop: the call has metadata and a permanent id even before transcription.
        if !CallFile.saveStopped(dir, startedAt: session.startedAt, audio: audio, info: session.info) {
            notifySaveFailure(dir)
        }
        CallMarks.write(dir, CallMarks.offsets(marks, audio: wall))
        marks = []
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

    private static var toldSystemAudioFallback = false

    /// The process tap didn't start: the other side is still recorded (ScreenCaptureKit), but not FaceTime.
    /// Said once per launch, at the start of the recording, with the way to fix it.
    private func explainSystemAudioFallback() {
        guard !Self.toldSystemAudioFallback else { return }
        Self.toldSystemAudioFallback = true
        if SystemAudioPermission.status == .denied {
            notify(L("Запись системного аудио выключена"),
                   L("Собеседников запишу через запись экрана, но звонок FaceTime так не слышно. Включи Sozvon в Системных настройках → Конфиденциальность и безопасность → «Только запись системного аудио»."),
                   action: .systemAudioPermission)
        } else {
            notify(L("Системный звук пишется через запись экрана"),
                   L("Не удалось включить запись системного аудио, собеседников запишу через запись экрана, но звонок FaceTime так не слышно. Подробности в recorder.log."),
                   action: .systemAudioPermission)
        }
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
        // Not required (ScreenCaptureKit stands in), but fixed in the same visit: FaceTime needs it.
        if SystemAudioPermission.status == .denied { missing.append(L("«Только запись системного аудио»")) }
        alert.informativeText = L("Включи Sozvon в Системных настройках → Конфиденциальность и безопасность → %@. После записи экрана перезапусти Sozvon.",
                                  missing.count > 2 ? missing.dropLast().joined(separator: ", ") + L(" и ") + missing[missing.count - 1]
                                    : missing.joined(separator: L(" и ")))
        alert.addButton(withTitle: L("Открыть настройки"))
        alert.addButton(withTitle: L("Отмена"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            // The person asked for System Settings: open the pane, not the system prompt.
            Permissions.openPane(Permissions.screen ? "Privacy_Microphone" : "Privacy_ScreenCapture")
        }
        return false
    }

    // MARK: Panel levels

    /// 10 times a second: levels for the panel and tracking of missing audio.
    private func startLevelTimer() {
        monitor = SignalMonitor()
        micWatch = SilenceWatch()
        systemWatch = SilenceWatch(patient: true)
        quietWatch = QuietMicWatch()
        zeroWatch = ZeroWatch()
        startedAt = Date()
        // A low input volume (often set by a browser call) makes your voice very quiet: say it right away
        // (unless sound warnings are off in Settings).
        if SilenceAlerts.enabled, let v = InputVolume.current(), v < 0.5 {
            notify(L("Громкость микрофона %@%%", Int((v * 100).rounded())),
                   L("Тебя будет тихо слышно в записи. Подними громкость входа в Системных настройках → Звук."),
                   action: .openSoundSettings)
        }
        levelTimer = Timer.repeatingOnMain(every: 0.1) { [weak self] in self?.sampleLevels() }
    }

    private func sampleLevels() {
        let now = Date()
        let m = recorder.meters
        let r = monitor.update(now: now, mic: (m.mic.level, m.mic.lastBufferAt),
                               system: (m.system.level, m.system.lastBufferAt), micZero: m.mic.zero)
        func fresh(_ t: TrackWriter.Meter) -> Bool {
            t.lastBufferAt.map { now.timeIntervalSince($0) < SignalMonitor.freshness } ?? false
        }
        // The waveform uses the wider display scale; a stale track shows nothing.
        panel.push(mic: fresh(m.mic) ? m.mic.display : 0, sys: fresh(m.system) ? m.system.display : 0)

        recover(.mic, micWatch.update(silent: r.micSilent), seconds: r.micSilent)
        recover(.system, systemWatch.update(silent: r.systemSilent, sound: r.system > SignalMonitor.silenceLevel),
                seconds: r.systemSilent)
        // The capsule warns together with the notification; no packets from the mic at all is told sooner.
        let warning: PanelModel.Warning?
        if r.micMissing >= 8 || micWatch.warns(silent: r.micSilent) {
            warning = .mic(seconds: r.micSilent)
        } else if systemWatch.warns(silent: r.systemSilent) {
            warning = .them(seconds: r.systemSilent)
        } else {
            warning = nil
        }
        if panel.warning != warning { panel.warning = warning }

        // Only while the mic delivers real sound: a dead mic is the "can't hear you" warning, not a quiet one.
        if r.micSilent == 0, quietWatch.update(level: r.mic, seconds: Int(now.timeIntervalSince(startedAt))),
           SilenceAlerts.enabled {
            let v = InputVolume.current().map { L(" Громкость входа сейчас %@%%.", Int(($0 * 100).rounded())) } ?? ""
            notify(L("Тебя очень тихо слышно"),
                   L("Три минуты твой голос почти не слышен в микрофоне.%@ Подними громкость входа или сядь ближе к Mac.", v),
                   action: .openSoundSettings)
        }
        // Digital zeros from the system track (a FaceTime call moved the audio, the tap went deaf): a new tap
        // within seconds, not after the two minutes a quiet call gets. Always a tap: ScreenCaptureKit can't
        // hear FaceTime, so it stands in only when the tap can't start (recapture falls back by itself).
        if zeroWatch.update(now: now, zero: fresh(m.system) && m.system.zero) == .newTap {
            Task { await recorder.recapture(.system) }
        }
        onLevels()
    }

    /// A source silent for two minutes is captured again (quietly, always); still silent at the watch's
    /// `tellAfter`: tell the user, if sound warnings are on.
    private func recover(_ source: Recorder.Source, _ action: SilenceWatch.Action, seconds: Int) {
        switch action {
        case .none: return
        case .restart:
            Task { await recorder.recapture(source) }
        case .tell:
            guard SilenceAlerts.enabled else { return }
            let time = Call.clock(seconds, empty: "0:00")
            if source == .mic {
                notify(L("Тебя не слышно %@", time),
                       L("Микрофон молчит, и переподключение не помогло. Проверь, какой микрофон выбран в Системных настройках → Звук, и не отключились ли наушники."),
                       action: .openSoundSettings)
            } else {
                notify(L("Их не слышно %@", time),
                       L("Звук собеседников не приходит, и переподключение не помогло. Если они говорят, проверь, что звук звонка идёт через этот Mac, а не через телефон или другое устройство."),
                       action: .openSoundSettings)
            }
        }
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
