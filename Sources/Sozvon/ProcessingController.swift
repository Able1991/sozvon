// Call transcription: the "what was the call about" prompt (answers go to call.json), the queue,
// running `bin/process_call.py <folder>`, and turning the result into clear notifications and actions.

import AppKit
import SozvonCore

@MainActor
final class ProcessingController {
    private var queue = ProcessingQueue()
    /// Running transcriptions by folder: on quit we stop them entirely (process group).
    private var running: [URL: RunningProcess] = [:]
    /// Sozvon is quitting: a finished run must not start the next one (it would outlive the app).
    private var quitting = false
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

    /// An engine run is going on now.
    var isProcessing: Bool { queue.running != nil }
    /// Something runs or waits for its turn: updates and the phone folder hold back.
    var hasWork: Bool { !queue.isEmpty }
    var isEngineUpdating: Bool { queue.engineUpdating }
    func contains(_ dir: URL) -> Bool { queue.contains(dir) }

    // MARK: Call prompt

    /// Recording saved: ask what the call was about, then transcribe (or "Later").
    func recorded(_ session: RecordingSession) {
        lastDir = session.dir
        onChange()
        Task {
            // The meeting from the calendar and the voices heard during the call fill what the user left empty;
            // saved right away so "Later" keeps it. Sure of the project and the people: the form goes ahead by
            // itself after a countdown, and touching it stops the countdown.
            let heard = await LiveVoices.shared.finish(session.dir)
            startNext()  // the match held the queue until now
            let event = await CalendarPrefill.meeting(at: session.startedAt)
            let guess = CallGuess.fill(session.info, defaultProfile: UserDefaults.standard.string(forKey: DefaultsKey.lastProfile) ?? "",
                                       startedAt: session.startedAt, event: event,
                                       heard: heard.map { HeardVoice(name: $0.name, profile: $0.profile, seconds: $0.seconds, unsure: $0.unsure) },
                                       projects: Project.all())
            let info = guess.info
            if info != session.info { CallFile.writeInfo(session.dir, info) }
            let answer = await CallInfoPrompt.answer(info, title: L("О чём был звонок?"), okTitle: L("Расшифровать"),
                                                     allowLater: true,
                                                     countdown: guess.sure && !info.reflection && CallGuess.skipForm() ? CallGuess.formCountdown : nil)
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
            UserDefaults.standard.set(info.profile, forKey: DefaultsKey.lastProfile)
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
        let initial = CallInfo(profile: UserDefaults.standard.string(forKey: DefaultsKey.lastProfile) ?? "",
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

    /// A new summary from the (edited) transcript, without transcribing again (`process_call.py --summary-only`).
    /// Goes through the same queue as transcription.
    func resummarize(_ dir: URL) {
        guard !queue.contains(dir), !calls.isEditLocked(dir) else { return }
        enqueue(dir, kind: .summaryOnly)
    }

    private func summaryFinished(_ dir: URL, outcome: RunOutcome) {
        let log = dir.appendingPathComponent("process.log")
        if outcome.isOK {
            notify(L("Саммари обновлено"), dir.lastPathComponent, action: .openCall, url: dir)
        } else {
            notify(L("Не получилось обновить саммари"), outcome.message.isEmpty ? L("Подробности в process.log") : outcome.message,
                   action: .openLog, url: log)
        }
    }

    /// Write the answers to call.json and enqueue.
    func transcribe(_ dir: URL, _ info: CallInfo) {
        // The engine reads the answers from call.json: without them a run would use stale ones.
        guard CallFile.writeInfo(dir, info) else { notifySaveFailure(dir); return }
        // No longer waiting for a description (the engine ignores the field either way).
        if CallFile.read(dir)[PendingInfo.key] != nil {
            CallFile.setInfoPending(dir, false)
            onPendingChange()
        }
        enqueue(dir)
    }

    // MARK: Queue

    private func enqueue(_ dir: URL, kind: ProcessingQueue.Kind = .transcribe) {
        guard queue.admit(dir, kind: kind) == .queued else {
            // Folder is already being transcribed: a second run and a rename underneath it broke the output.
            notify(L("Уже расшифровывается"), dir.lastPathComponent)
            syncCalls()
            return
        }
        CallFile.clearRetries(dir)  // asked for by the user (and admitted): a later crash gets its retry again
        if queue.engineUpdating && kind == .transcribe { notify(L("Расшифрую после обновления движка"), dir.lastPathComponent) }
        startNext()
        notifyIfEngineBlocks(dir)
        // The run still happens; only a restart would forget that this call was waiting.
        if queue.isWaiting(dir), !CallFile.setQueued(dir, at: Date(), summaryOnly: kind == .summaryOnly) { notifySaveFailure(dir) }
        syncCalls()
    }

    /// A call the user just queued waits for a working engine: say why and how to fix it, instead of a silent
    /// "Queued". It starts by itself once the engine is ready.
    private func notifyIfEngineBlocks(_ dir: URL) {
        guard queue.isWaiting(dir) else { return }
        let state = EngineState.evaluate(data: Paths.data, model: Settings.shared.model, isDevEngine: Paths.isDevEngine)
        switch state.waitReason {
        case .engine:
            notify(L("Движок сломан"), L("Расшифровка начнётся, когда движок заработает"), action: .reinstallEngine)
        case .model:
            notify(L("Модель не скачана"), L("Расшифровка начнётся, когда модель скачается"), action: .downloadModel)
        case nil:
            break
        }
    }

    /// Nothing may start now: a recording is starting, running or being saved, its voice match is finishing, or a
    /// call app holds the microphone (set by AppDelegate). The CPU and memory load would make the call stutter.
    var holdsQueue: () -> Bool = { false }

    /// Start the next waiting job if nothing runs and nothing holds the queue. Called whenever one of those changed:
    /// a run finished, an engine update ended, the recording state or the microphone's users changed.
    func startNext() {
        guard !quitting, queue.canStartNext else { return }
        while let job = queue.startNext(held: holdsQueue()) {
            guard FileManager.default.fileExists(atPath: job.dir.path) else {
                queue.finish(job.dir)  // deleted while waiting (Finder, a tombstone from sync)
                continue
            }
            CallFile.setQueued(job.dir, at: nil)
            run(job)
            syncCalls()
            return
        }
    }

    /// At launch: the calls that were waiting, and the one a crash interrupted, go back in the queue.
    /// Returns their folders: the launch sweep of `.work` leaves those alone.
    @discardableResult
    func restoreQueue() -> Set<URL> {
        let jobs = CallFile.recoverQueue(in: Paths.calls)
        guard !jobs.isEmpty else { return [] }
        for job in jobs { _ = queue.admit(job.dir, kind: job.kind) }
        startNext()
        syncCalls()
        return Set(jobs.map(\.dir))
    }

    /// "Remove from Queue" in the Calls window: a waiting call goes back to how it was.
    func removeFromQueue(_ dir: URL) {
        guard queue.remove(dir) else { return }
        CallFile.setQueued(dir, at: nil)
        // An interrupted call (it carries `retries`) was `processing` before: it ends `failed` as it always did.
        if CallFile.read(dir)[CallFile.retriesKey] != nil { CallFile.setStatus(dir, .failed) }
        CallFile.clearRetries(dir)
        syncCalls()
    }

    private func runningPaths(_ kind: ProcessingQueue.Kind) -> Set<String> {
        guard let r = queue.running, r.kind == kind else { return [] }
        return [r.dir.standardizedFileURL.path]
    }

    private func syncCalls() {
        calls.processing = runningPaths(.transcribe)
        calls.summarizing = runningPaths(.summaryOnly)
        calls.queued = Set(queue.waiting.map { $0.dir.standardizedFileURL.path })
        calls.reload()
        onChange()
    }

    /// The engine isn't driven from the folder: it takes everything about the call from call.json.
    private func run(_ job: ProcessingQueue.Job) {
        let dir = job.dir
        let log = dir.appendingPathComponent("process.log")
        let tracker = OutputTracker()
        let args = job.kind == .summaryOnly ? [dir.path, "--summary-only"] : [dir.path]
        let p = Engine.runScript("process_call.py", args, log: log, onLine: { tracker.consume($0) }) { [weak self] code in
            let outcome = RunOutcome.parse(exitCode: code, result: tracker.result, lastLine: tracker.lastLine)
            guard let self else { return }
            switch job.kind {
            case .transcribe: self.finished(dir, code: code, outcome: outcome)
            case .summaryOnly:
                self.queue.finish(dir)
                self.running[dir] = nil
                self.syncCalls()
                self.startNext()
                self.summaryFinished(dir, outcome: outcome)
            }
        }
        if let p, queue.contains(dir) { running[dir] = p }
    }

    /// App quit mid-transcription: stop the engine (otherwise it died from a closed pipe
    /// and call.json stayed `processing` forever) and mark the calls `failed` so they can be transcribed again.
    /// A call the engine already marked `done` stays done: only its optional listening file was still being written.
    /// Waiting calls keep `queued_at` and come back at the next launch.
    func abortAll() {
        quitting = true
        for (dir, p) in running {
            p.terminate()
            // A summary run leaves the status alone: the call stays as it was.
            if queue.running?.kind == .transcribe { CallFile.setFailedUnlessDone(dir) }
        }
        running = [:]
    }

    private func finished(_ dirIn: URL, code: Int32, outcome: RunOutcome) {
        queue.finish(dirIn)
        running[dirIn] = nil
        var dir = dirIn
        CallFile.clearRetries(dir)  // the run ended by itself, it was not interrupted
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
            CallFile.setFailedUnlessDone(dir)
            Engine.recordFailure(outcome.message.isEmpty ? L("Код завершения %@", code) : outcome.message, log: log)
        }
        syncCalls()
        startNext()
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
            if let why = CallWarnings.summary(CallFile.read(dir)) {
                // Done, but not as asked: the summary failed. The button runs the Update Summary path.
                notify(L("Готово, но саммари не получилось"), why.isEmpty ? L("Подробности в process.log") : why,
                       action: .resummarize, url: dir)
            } else {
                notify(L("Расшифровка готова"), dir.lastPathComponent, action: .openCall, url: dir)
            }
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

    /// After an app update, or while the optional echo model is missing (a failed download is retried here, at most
    /// once a day): refresh the engine environment (uv sync, models) in the background.
    /// Recording keeps working; transcriptions wait for the update to finish. Installs from the setup
    /// assistant go through the same owner (EngineInstaller), so two setup.sh never run at once.
    func updateEngineIfNeeded() {
        let state = EngineState.evaluate(data: Paths.data, model: Settings.shared.model, isDevEngine: Paths.isDevEngine)
        let d = UserDefaults.standard
        let retryEcho = state == .ready && EngineState.shouldRetryEchoModel(
            data: Paths.data, isDevEngine: Paths.isDevEngine, lastTry: d.object(forKey: DefaultsKey.echoModelTry) as? Date)
        guard state == .needsUpdate || retryEcho else { return }
        if retryEcho { d.set(Date(), forKey: DefaultsKey.echoModelTry) }
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
            self.queue.endEngineUpdate()
            self.startNext()
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
        case .resummarize:
            if let url { resummarize(url) }
        case .callPrompt, .record, .notNow, .openSoundSettings, .openCall:
            break  // AppDelegate handles these
        }
    }

    #if SOZVON_PREVIEW
    /// For screenshots: a "transcribing" state without the engine.
    func preview(processing dir: URL?, lastTranscript: URL? = nil) {
        if let dir { _ = queue.admit(dir); _ = queue.startNext(held: false) } else if let r = queue.running { queue.finish(r.dir) }
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
