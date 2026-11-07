// Call transcription: the "what was the call about" prompt (answers go to call.json), the queue,
// running `bin/process_call.py <folder>`, and turning the result into clear notifications and actions.

import AppKit
import SozvonCore

@MainActor
final class ProcessingController {
    private var queue = ProcessingQueue()
    /// Running transcriptions by folder: on quit we stop them entirely (process group).
    private var running: [URL: RunningProcess] = [:]
    private(set) var lastTranscript: URL?
    private(set) var lastDir: URL?
    let calls: CallsModel

    /// Queue or engine update changed: redraw the menu and panel.
    var onChange: () -> Void = {}
    /// Open the setup assistant at a given step (engine reinstall, model download).
    var showSetup: (SetupModel.Step) -> Void = { _ in }
    /// The call prompt was closed (for the recording machine: clear "Recorded").
    var onAnswered: (URL) -> Void = { _ in }
    /// A call started or stopped waiting for its description ("Later").
    var onPendingChange: () -> Void = {}

    init(calls: CallsModel) {
        self.calls = calls
        wireInstaller()
    }

    var isProcessing: Bool { queue.count > 0 }
    var isEngineUpdating: Bool { queue.engineUpdating }
    func contains(_ dir: URL) -> Bool { queue.contains(dir) }

    // MARK: Call prompt

    /// Recording saved: ask what the call was about, then transcribe (or "Later").
    func recorded(_ session: RecordingSession) {
        lastDir = session.dir
        onChange()
        Task {
            // The meeting from the calendar fills what the user left empty; saved right away so "Later" keeps it.
            let info = await CalendarPrefill.fill(session.info, startedAt: session.startedAt)
            if info != session.info { CallFile.writeInfo(session.dir, info) }
            let answer = await CallInfoPrompt.answer(info, title: L("О чём был звонок?"), okTitle: L("Расшифровать"),
                                                     allowLater: true)
            onAnswered(session.dir)
            apply(answer, to: session.dir)
        }
    }

    /// A call waiting for its description (menu, notification, Calls window): the same prompt again.
    func describe(_ dir: URL) {
        guard FileManager.default.fileExists(atPath: dir.path), !queue.contains(dir), !calls.isRecording(dir) else { return }
        let initial = CallFile.info(CallFile.read(dir), fallback: CallInfo(languages: Settings.shared.languages))
        Task {
            let answer = await CallInfoPrompt.answer(initial, title: L("О чём был звонок?"), okTitle: L("Расшифровать"),
                                                     allowLater: true)
            apply(answer, to: dir)
        }
    }

    private func apply(_ answer: CallInfoAnswer, to dir: URL) {
        switch answer {
        case .transcribe(let info):
            UserDefaults.standard.set(info.profile, forKey: "lastProfile")
            transcribe(dir, info)
        case .later(let info):
            if let info { CallFile.writeInfo(dir, info) }
            CallFile.setInfoPending(dir, true)
            calls.reload()
        case .cancel:
            CallFile.setInfoPending(dir, false)
            calls.reload()
        }
        onPendingChange()
    }

    /// A recording imported in the Calls window: the same prompt as after a recording (with "Later"), then transcribe.
    func imported(_ dir: URL) {
        let initial = CallInfo(profile: UserDefaults.standard.string(forKey: "lastProfile") ?? "",
                               languages: Settings.shared.languages)
        Task {
            let answer = await CallInfoPrompt.answer(initial, title: L("О чём был звонок?"), okTitle: L("Расшифровать"),
                                                     allowLater: true)
            apply(answer, to: dir)
        }
    }

    /// "Transcribe Again" for a call: answers come from its call.json.
    func retranscribe(_ dir: URL) {
        // Never transcribed and waiting for its description: the same prompt as after the recording.
        if PendingInfo.isPending(CallFile.read(dir)) { describe(dir); return }
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

    /// Show a call in the Calls window (a finished transcription, "Latest Transcript", a notification).
    var onOpenCall: (URL) -> Void = { _ in }

    /// Calls whose summary is being made again.
    private(set) var summarizing: Set<String> = []

    /// A new summary from the (edited) transcript, without transcribing again (`process_call.py --summary-only`).
    func resummarize(_ dir: URL) {
        let key = dir.standardizedFileURL.path
        guard !summarizing.contains(key), !queue.contains(dir), !calls.isEditLocked(dir) else { return }
        summarizing.insert(key)
        calls.summarizing = summarizing
        let log = dir.appendingPathComponent("process.log")
        let tracker = OutputTracker()
        Engine.runScript("process_call.py", [dir.path, "--summary-only"], log: log, onLine: { tracker.consume($0) }) { [weak self] code in
            guard let self else { return }
            self.summarizing.remove(key)
            self.calls.summarizing = self.summarizing
            self.calls.reload()
            let outcome = RunOutcome.parse(exitCode: code, result: tracker.result, lastLine: tracker.lastLine)
            if outcome.isOK {
                notify(L("Саммари обновлено"), dir.lastPathComponent, action: .openCall, url: dir)
            } else {
                notify(L("Не получилось обновить саммари"), outcome.message.isEmpty ? L("Подробности в process.log") : outcome.message,
                       action: .openLog, url: log)
            }
        }
    }

    /// Write the answers to call.json and enqueue.
    func transcribe(_ dir: URL, _ info: CallInfo) {
        CallFile.writeInfo(dir, info)
        // No longer waiting for a description (the engine ignores the field either way).
        if CallFile.read(dir)[PendingInfo.key] != nil {
            CallFile.setInfoPending(dir, false)
            onPendingChange()
        }
        enqueue(dir)
    }

    // MARK: Queue

    private func enqueue(_ dir: URL) {
        switch queue.admit(dir) {
        case .duplicate:
            // Folder is already being transcribed: a second run and a rename underneath it broke the output.
            notify(L("Уже расшифровывается"), dir.lastPathComponent)
        case .queued:
            notify(L("Расшифрую после обновления движка"), dir.lastPathComponent)
        case .start:
            // A new recording is running: the transcription would load the CPU and memory during the call
            // (the call's video and sound may stutter). It starts as soon as the recording stops.
            if isRecording() { deferred.append(dir) } else { run(dir) }
        }
        syncCalls()
    }

    /// A recording is in progress (set by AppDelegate).
    var isRecording: () -> Bool = { false }
    /// Transcriptions admitted during a recording, started when it stops.
    private var deferred: [URL] = []

    /// The recording stopped: start what waited for it.
    func recordingEnded() {
        let waiting = deferred
        deferred = []
        for dir in waiting where queue.contains(dir) { run(dir) }
    }

    private func syncCalls() {
        calls.processing = queue.active
        calls.reload()
        onChange()
    }

    /// The engine isn't driven from the folder: it takes everything about the call from call.json.
    private func run(_ dir: URL) {
        let log = dir.appendingPathComponent("process.log")
        let tracker = OutputTracker()
        let p = Engine.runScript("process_call.py", [dir.path], log: log, onLine: { tracker.consume($0) }) { [weak self] code in
            self?.finished(dir, code: code, outcome: RunOutcome.parse(exitCode: code, result: tracker.result,
                                                                       lastLine: tracker.lastLine))
        }
        if let p, queue.contains(dir) { running[dir] = p }
    }

    /// App quit mid-transcription: stop the engine (otherwise it died from a closed pipe
    /// and call.json stayed `processing` forever) and mark the calls `failed` so they can be transcribed again.
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
            // The pretty folder name only after success: while the engine writes to the folder, leave it alone.
            // People come from call.json `participants`, which the engine wrote from the transcript.
            dir = renameCallDir(dir)
            if lastDir == dirIn { lastDir = dir }
            // The engine already sent the call's text to the own server. The full sync in the background sends
            // its tracks (resumable) and the new folder name after a rename.
            ServerSync.shared.sync()
        } else {
            CallFile.setStatus(dir, .failed)
            Engine.recordFailure(outcome.message.isEmpty ? L("Код завершения %@", code) : outcome.message, log: log)
        }
        syncCalls()
        report(outcome, dir: dir, log: dir.appendingPathComponent("process.log"))
    }

    /// Notification for the result (contract, section 5).
    private func report(_ outcome: RunOutcome, dir: URL, log: URL) {
        let transcript = dir.appendingPathComponent("transcript.md")
        switch outcome {
        case .ok:
            guard FileManager.default.fileExists(atPath: transcript.path) else {
                notify(L("Не получилось расшифровать"), L("Движок не оставил transcript.md"), action: .openLog, url: log)
                return
            }
            lastTranscript = transcript
            notify(L("Расшифровка готова"), dir.lastPathComponent, action: .openCall, url: dir)
            Sounds.play(.done)
            onOpenCall(dir)
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

    /// "2026-11-04 15-01 · Project · topic · people". The leading date (the call id) never changes.
    private func renameCallDir(_ dir: URL) -> URL {
        let c = CallFile.read(dir)
        let newName = callDirName(dir.lastPathComponent, CallFile.info(c), projects: Project.all(),
                                  people: CallParticipants.list(c))
        guard newName != dir.lastPathComponent else { return dir }
        let target = dir.deletingLastPathComponent().appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: target.path),
              (try? FileManager.default.moveItem(at: dir, to: target)) != nil else { return dir }
        return target
    }

    // MARK: Engine update

    /// After an app update: refresh the engine environment (uv sync, models) in the background.
    /// Recording keeps working; transcriptions wait for the update to finish. Installs from the setup
    /// assistant go through the same owner (EngineInstaller), so two setup.sh never run at once.
    func updateEngineIfNeeded() {
        let state = EngineState.evaluate(data: Paths.data, model: Settings.shared.model, isDevEngine: Paths.isDevEngine)
        guard state == .needsUpdate else { return }
        EngineInstaller.shared.run(.background)
    }

    /// Any engine install (background or from the setup assistant) holds the transcription queue.
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

    // MARK: Notification actions

    func handle(_ action: NotifyAction, url: URL?) {
        switch action {
        case .open, .openLog:
            if let url { NSWorkspace.shared.open(url) }
        case .permissions:
            Permissions.openPane(Permissions.screen ? "Privacy_Microphone" : "Privacy_ScreenCapture")
        case .systemAudioPermission:
            Permissions.openPane("Privacy_ScreenCapture")  // "System Audio Recording Only" lives there
        case .reinstallEngine, .downloadModel:
            showSetup(.install)
        case .describeCall:
            if let url { describe(url) }
        case .callPrompt, .record, .notNow, .openSoundSettings, .openCall:
            break  // AppDelegate handles these
        }
    }

    #if SOZVON_PREVIEW
    /// For screenshots: a "transcribing" state without the engine.
    func preview(processing dir: URL?, lastTranscript: URL? = nil) {
        if let dir { _ = queue.admit(dir) } else { for d in queue.active { queue.finish(URL(fileURLWithPath: d)) } }
        if let lastTranscript { self.lastTranscript = lastTranscript }
        onChange()
    }
    #endif
}

/// Last output line and the RESULT line (on the main thread, as output arrives).
@MainActor
final class OutputTracker {
    var lastLine: String?
    var result: RunOutcome.ResultLine?

    func consume(_ line: String) {
        if let r = RunOutcome.parseLine(line) { result = r }
        if !line.trimmingCharacters(in: .whitespaces).isEmpty { lastLine = line }
    }
}
