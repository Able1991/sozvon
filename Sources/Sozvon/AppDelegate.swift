// Sozvon: a menu bar button that records a call (Zoom, Google Meet, anything) as two tracks
// via ScreenCaptureKit, with no virtual audio drivers:
//   system.m4a  computer audio (the other participants)
//   mic.m4a     microphone (me)
// After stopping, it saves the call details to call.json and runs the engine: bin/process_call.py <folder>.
//
// AppDelegate only wires the parts together: recording (RecordingController), transcription
// (ProcessingController), menu (MenuController), windows (WindowsRegistry), panel (FloatingPanel),
// "A call is on. Record?" (CallPromptController), calls waiting for a description (PendingInfoController).

import AppKit
import SozvonCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let panel = FloatingPanel()
    let calls = CallsModel()
    private(set) lazy var recording = RecordingController(panel: panel.model)
    private(set) lazy var processing = ProcessingController(calls: calls)
    private(set) var menu: MenuController!
    let callPrompt = CallPromptController()
    let pendingInfo = PendingInfoController()
    private let phoneInbox = PhoneInboxWatcher()
    /// Cached in stateChanged: the call prompt asks often while a call holds the mic.
    private var engineUsable = false
    private var updateTimer: Timer?
    private var tickTimer: Timer?
    /// ⌃⌥I "important", system-wide while recording.
    private lazy var importantKey = HotKey.important { [weak self] in self?.recording.mark() }
    /// Single-instance lock, held until the app quits.
    private var instanceLock: InstanceLock?

    var engineState: EngineState { EngineState.current }

    /// sozvon://settings/cloud: the browser hands control back after "Подключить Cloudflare".
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "sozvon" else { return }
        if url.host == "settings" {
            let name = url.pathComponents.dropFirst().first ?? ""
            let tab = name == "cloud" ? SettingsView.Tab.allCases.firstIndex(of: .server) : nil
            showSettings(tab: tab)
            NSApp.activate()
            WindowsRegistry.shared.window("settings")?.orderFrontRegardless()
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        guard takeInstanceLock() else { return }
        try? FileManager.default.createDirectory(at: Paths.calls, withIntermediateDirectories: true)
        // An import that crashed left a call folder without audio or a temp file: to the Trash.
        AudioImport.cleanLeftovers()
        Engine.syncCode()
        Notifier.shared.setup()
        Notifier.shared.onAction = { [weak self] action, url in
            guard let self else { return }
            switch action {
            case .record: self.callPrompt.record()
            case .notNow: self.callPrompt.notNow()
            case .callPrompt: break  // a click on the notification is not consent to record
            case .openCall:
                self.showCalls(select: url)
            case .openSoundSettings:
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
            default: self.processing.handle(action, url: url)
            }
        }
        MenuController.installMainMenu(settings: { [weak self] in self?.showSettings() },
                                       calls: { [weak self] in self?.showCalls() },
                                       quit: { NSApp.terminate(nil) })
        wire()
        MCPServer.shared.start()
        pendingInfo.start()
        processing.updateEngineIfNeeded()
        // After the check above, so an engine update holds them; a crashed run comes back once.
        let restored = processing.restoreQueue()
        startUpdates()
        // Working files of runs that were killed outright; off the main thread, next to the live pieces sweep.
        let callsRoot = Paths.calls
        Task.detached(priority: .utility) { WorkFiles.sweep(in: callsRoot, keeping: restored) }
        AudioCleanup.isBusy = { [weak self] dir in
            guard let self else { return true }
            return self.processing.contains(dir) || self.calls.recordingDir?.standardizedFileURL == dir.standardizedFileURL
        }
        AudioCleanup.onChange = { [weak self] in self?.calls.reload() }
        CallsFolderChanger.isBusy = { [weak self] in
            guard let self else { return true }
            return self.processing.isProcessing || self.calls.recordingDir != nil
        }
        CallsFolderChanger.onChanged = { [weak self] in
            MCPServer.shared.restart()   // its SOZVON_CALLS_DIR is the old folder
            self?.calls.followCallsFolder()
        }
        // Not in the first seconds after launch: the app is busy enough then.
        mainAfter(60) { _ = AudioCleanup.run() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { _ = AudioCleanup.run() }
        }
        stateChanged()

        #if SOZVON_PREVIEW
        if PreviewDriver.run(self) { return }
        #endif

        // A relaunch after granting screen recording permission resumes the setup assistant at the same step.
        // integer(forKey:) reads both a number from defaults and a string from launch arguments (-setupResumeStep 3).
        var resume = UserDefaults.standard.object(forKey: DefaultsKey.setupResumeStep) != nil
            ? UserDefaults.standard.integer(forKey: DefaultsKey.setupResumeStep) : nil
        UserDefaults.standard.removeObject(forKey: DefaultsKey.setupResumeStep)
        // Setup not finished: back on the step it was on (whatever relaunched us). Without a working engine
        // nothing past the model step makes sense: start from the model then.
        if resume == nil, UserDefaults.standard.object(forKey: Self.setupDoneKey) != nil, !Self.setupDone,
           UserDefaults.standard.object(forKey: SetupModel.stepKey) != nil {
            resume = SetupFlow.resume(saved: UserDefaults.standard.integer(forKey: SetupModel.stepKey), engine: engineState)
        }
        // Installs from before the flag existed: set up if the engine works and setup isn't being resumed.
        if UserDefaults.standard.object(forKey: Self.setupDoneKey) == nil {
            Self.setupDone = engineState.isUsable && resume == nil
            stateChanged()
        }
        if let resume {
            showSetup(step: SetupModel.Step(rawValue: resume) ?? .welcome)
        } else if !Self.setupDone || !engineState.isUsable {
            openSetup()
        } else if !Permissions.mic || !Permissions.screen {
            // Set up, but a required permission is missing (never granted, or macOS dropped it after an update):
            // ask now, not when a call has already started and the recording can't. System audio is left out:
            // without it ScreenCaptureKit records the other side (all but FaceTime), a choice some make.
            showSetup(step: .permissions)
        }
    }

    /// The setup assistant was finished once. Until then nothing else opens and nothing records: the menu's
    /// items, the capsule, the call prompt and deep links bring the assistant back instead.
    static let setupDoneKey = "setupDone"
    static var setupDone: Bool {
        get { UserDefaults.standard.bool(forKey: setupDoneKey) }
        set { UserDefaults.standard.set(newValue, forKey: setupDoneKey) }
    }

    /// true when setup is done; otherwise brings the assistant to the front and returns false.
    @discardableResult
    func requireSetup() -> Bool {
        if Self.setupDone { return true }
        #if SOZVON_PREVIEW
        if CommandLine.arguments.contains("--preview") { return true }  // screenshots and UI tests open any screen
        #endif
        openSetup()
        return false
    }

    /// "Finish Setup…" (menu, Settings, anything that needs setup): an unfinished setup continues on the step it
    /// was closed on; after setup, a missing engine or model opens the model choice and comes back to Settings.
    func openSetup() {
        if Self.setupDone {
            showSetup(step: .model, repair: true)
        } else {
            let saved = UserDefaults.standard.object(forKey: SetupModel.stepKey) == nil
                ? nil : UserDefaults.standard.integer(forKey: SetupModel.stepKey)
            showSetup(step: SetupModel.Step(rawValue: SetupFlow.resume(saved: saved, engine: engineState)) ?? .welcome)
        }
    }

    /// A second copy of Sozvon (different .app path, so LSMultipleInstancesProhibited doesn't catch it):
    /// show a clear message and quit. Screenshot mode doesn't take the lock.
    private func takeInstanceLock() -> Bool {
        #if SOZVON_PREVIEW
        if CommandLine.arguments.contains("--preview") { return true }
        #endif
        if let lock = InstanceLock.acquire(in: Paths.data) {
            instanceLock = lock
            return true
        }
        let alert = NSAlert()
        alert.messageText = L("Sozvon уже запущен")
        alert.informativeText = L("Другая копия Sozvon уже работает с этой папкой данных. Её значок в строке меню. Эта копия закроется.")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        exit(0)
    }

    private func wire() {
        menu = MenuController(actions: MenuActions(
            toggleRecording: { [weak self] in self?.recording.toggle() },
            editInfo: { [weak self] in self?.editInfo() },
            mark: { [weak self] in self?.recording.mark() },
            showSetup: { [weak self] in self?.openSetup() },
            openLast: { [weak self] in
                guard let self, let dir = self.processing.lastTranscript?.deletingLastPathComponent() ?? self.processing.lastDir else { return }
                self.showCalls(select: dir)
            },
            redoLast: { [weak self] in self?.processing.retranscribeLast() },
            showCalls: { [weak self] in self?.showCalls() },
            showProjects: { [weak self] in self?.showProjects() },
            showSettings: { [weak self] in self?.showSettings() },
            togglePanel: { [weak self] in
                FloatingPanel.enabled.toggle()
                self?.stateChanged()
            },
            openUpdate: { AppUpdater.shared.checkNow() },
            describePending: { [weak self] in
                if let dir = self?.pendingInfo.pending.first?.dir { self?.processing.describe(dir) }
            },
            quit: { NSApp.terminate(nil) }
        ), snapshot: { [unowned self] in self.menuSnapshot })

        recording.initialInfo = {
            CallInfo(profile: UserDefaults.standard.string(forKey: DefaultsKey.lastProfile) ?? "", languages: Settings.shared.languages)
        }
        recording.onChange = { [weak self] in self?.stateChanged() }
        recording.canStart = { [weak self] in self?.requireSetup() ?? false }
        recording.onLevels = { [weak self] in self?.panel.fit() }
        recording.onSaved = { [weak self] session in
            guard let self else { return }
            self.processing.recorded(session)
        }
        processing.onAnswered = { [weak self] dir in self?.recording.dismissSaved(dir) }
        processing.onChange = { [weak self] in self?.stateChanged() }
        processing.showSetup = { [weak self] _ in self?.openSetup() }
        calls.onRetranscribe = { [weak self] call in
            guard let self, !self.calls.isRecording(call.url) else { NSSound.beep(); return }
            self.processing.retranscribe(call.url)
        }
        calls.onImported = { [weak self] dir in self?.processing.imported(dir) }

        processing.onPendingChange = { [weak self] in self?.pendingInfo.refresh() }
        processing.onOpenCall = { [weak self] dir in self?.showCalls(select: dir) }
        processing.holdsQueue = { [weak self] in
            guard let self else { return true }
            let s = self.recording.state
            // A broken engine would fail a restored call and spend its only retry.
            return !self.engineUsable || s.isCapturing || s.isStarting || LiveVoices.shared.isActive || CallApps.inCall()
        }
        callPrompt.onMicChange = { [weak self] in self?.processing.startNext() }
        calls.onRemoveFromQueue = { [weak self] call in self?.processing.removeFromQueue(call.url) }
        calls.onResummarize = { [weak self] call in self?.processing.resummarize(call.url) }
        pendingInfo.isBusy = { [weak self] in
            guard let self else { return false }
            if case .idle = self.recording.state { return CallInfoPrompt.isOpen }
            return true
        }
        pendingInfo.onChange = { [weak self] in self?.menu?.stateChanged() }

        // Only while idle and able to transcribe; the prompt never records by itself.
        callPrompt.isBusy = { [weak self] in
            guard let self else { return true }
            if case .idle = self.recording.state { return !self.engineUsable || !Self.setupDone }
            return true
        }
        callPrompt.onRecord = { [weak self] in self?.recording.start() }
        callPrompt.isRecording = { [weak self] in self?.recording.state.isCapturing ?? false }
        callPrompt.onStop = { [weak self] in self?.recording.stop() }
        callPrompt.otherSideAudible = { [weak self] in self?.recording.otherSideAudible ?? false }
        panel.model.onKeepRecording = { [weak self] in self?.callPrompt.keepRecording() }
        callPrompt.onChange = { [weak self] in self?.stateChanged() }
        panel.model.onPromptRecord = { [weak self] in self?.callPrompt.record() }
        panel.model.onPromptDismiss = { [weak self] in self?.callPrompt.notNow() }

        panel.model.onRecord = { [weak self] in self?.recording.start() }
        panel.model.onStop = { [weak self] in self?.recording.stop() }
        panel.model.onMark = { [weak self] in self?.recording.mark() }
        panel.model.onHide = { [weak self] in
            FloatingPanel.enabled = false
            self?.stateChanged()
        }
    }

    private var menuSnapshot: MenuSnapshot {
        let lastDir = processing.lastDir
        return MenuSnapshot(recording: recording.state, processing: processing.isProcessing,
                            engineUpdating: processing.isEngineUpdating, engine: engineState, update: AppUpdater.shared.available,
                            hasLastTranscript: processing.lastTranscript != nil,
                            canRedoLast: lastDir.map { !recording.state.isCapturing && !processing.contains($0) } ?? false,
                            panelEnabled: FloatingPanel.enabled, pendingInfo: pendingInfo.pending.count,
                            setupDone: Self.setupDone)
    }

    /// Recording or transcription state changed: update the icon, panel and timer.
    func stateChanged() {
        AppUpdater.shared.installIfQuiet()
        let s = recording.state
        let p = panel.model
        engineUsable = engineState.isUsable
        // Recording started or stopped: re-check the call prompt (may call back into stateChanged once).
        callPrompt.sync()
        pendingInfo.activity()
        p.callPrompt = callPrompt.prompt.map(callPrompt.text)
        p.startIn = callPrompt.startIn
        p.stopIn = callPrompt.stopIn
        // Folder of the recording in progress in "Calls": shown as recording, can't be deleted or transcribed.
        let recDir: URL? = s.isCapturing || s.isStarting ? s.dir : nil
        if calls.recordingDir != recDir { calls.recordingDir = recDir }
        if s.isCapturing {
            p.state = .recording
        } else if s.isStarting {
            p.state = .starting
        } else if processing.isProcessing {
            p.state = .processing
        } else if case .saved = s {
            p.state = .saved
        } else {
            p.state = .idle
        }
        p.elapsed = s.session?.elapsed() ?? "0:00"
        importantKey.setActive(s.isRecording)
        processing.startNext()
        // Without a ready engine, don't show the "Record" capsule: the recording couldn't be transcribed anyway.
        var showPanel = (engineUsable && Self.setupDone) || s.isCapturing || processing.isProcessing
        #if SOZVON_PREVIEW
        // The demo data has no engine: the capsule screens show it anyway.
        if PreviewDriver.panelAlways { showPanel = true }
        #endif
        if showPanel { panel.sync() } else { panel.hide() }
        menu?.stateChanged()
        if s.isRecording, tickTimer == nil {
            // In .common mode the timer keeps running while the menu is open.
            tickTimer = Timer.repeatingOnMain(every: 1) { [weak self] in self?.tick() }
        } else if !s.isRecording {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    /// Once a second while recording: update only the time, don't rebuild the menu.
    private func tick() {
        panel.model.elapsed = recording.state.session?.elapsed() ?? "0:00"
        menu.tick()
    }

    // MARK: Windows

    func showSetup(step: SetupModel.Step = .welcome, repair: Bool = false) {
        WindowsRegistry.shared.show(.hosting("setup", width: 600) {
            SetupView(m: SetupModel(step: step, repair: repair)) { [weak self] in
                WindowsRegistry.shared.close("setup")
                if !repair {
                    Self.setupDone = true
                    UserDefaults.standard.removeObject(forKey: SetupModel.stepKey)
                }
                // Opened from Settings: go back to its Recognition pane instead of leaving it buried under
                // other windows, and restart the MCP server so it runs the reinstalled server.py.
                if repair {
                    self?.showSettings(tab: SettingsView.Tab.allCases.firstIndex(of: .recognition))
                    MCPServer.shared.restart()
                } else {
                    MCPServer.shared.start()
                }
                self?.stateChanged()
            }
        }, onClose: {
            // Closed mid-download: stop it. Reopening continues on the model step, the download resumes from there.
            EngineInstaller.shared.cancel(.setup)
        })
    }

    /// The standard Mac preferences window: toolbar tabs, each pane a grouped form, the window takes the
    /// pane's height (up to a cap, the form scrolls beyond).
    func showSettings(tab: Int? = nil) {
        guard requireSetup() else { return }
        let nav = SettingsNav.shared
        let isOpen = WindowsRegistry.shared.window("settings") != nil
        // Already open (e.g. sozvon://settings/cloud while it is on screen): just switch to the requested tab.
        if let tab, SettingsView.Tab.allCases.indices.contains(tab) {
            nav.tab = SettingsView.Tab.allCases[tab]
        } else if !isOpen {
            nav.tab = .general
        }
        let spec = WindowSpec(key: "settings", title: nav.tab.title, style: [.titled, .closable],
                              toolbarStyle: .preference) { [weak self] in
            SettingsTabController(nav: nav, reinstall: {
                self?.showSetup(step: .model, repair: true)
            }, onPanelChange: {
                self?.stateChanged()
            })
        }
        WindowsRegistry.shared.show(spec, onClose: { [weak self] in self?.stateChanged() })
    }

    func showProjects() {
        guard requireSetup() else { return }
        // A native list window: SwiftUI's toolbar (Liquid Glass on macOS 26), title and subtitle go to the window.
        let spec = WindowSpec(key: "projects", title: L("Проекты"),
                              style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              contentSize: NSSize(width: 640, height: 460), toolbarStyle: .unified,
                              autosaveName: "SozvonProjects") {
            let h = NSHostingController(rootView: ProjectsView())
            h.sceneBridgingOptions = [.toolbars, .title]
            return h
        }
        WindowsRegistry.shared.show(spec)
    }

    /// The Calls window, optionally with a call selected (by its folder).
    func showCalls(select dir: URL? = nil) {
        guard requireSetup() else { return }
        if let dir {
            calls.reload()
            let path = dir.standardizedFileURL.path
            if let c = calls.calls.first(where: { $0.url.standardizedFileURL.path == path }) { calls.selection = c.id }
        }
        // A native split view window: SwiftUI's toolbar (Liquid Glass on macOS 26) and title go to the window.
        let spec = WindowSpec(key: "calls", title: L("Звонки"),
                              style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              contentSize: NSSize(width: 960, height: 640), toolbarStyle: .unified,
                              autosaveName: "SozvonCalls") { [calls] in
            let h = NSHostingController(rootView: CallsView(m: calls))
            h.sceneBridgingOptions = [.toolbars, .title]
            return h
        }
        if WindowsRegistry.shared.window("calls") == nil { calls.startWatching() }
        WindowsRegistry.shared.show(spec, onClose: { [calls] in calls.stopWatching() })
    }

    func editInfo() {
        guard requireSetup() else { return }
        if CallInfoPrompt.isOpen { CallInfoPrompt.bringToFront(); return }
        guard let session = recording.state.session else { return }
        Task {
            if let i = await CallInfoPrompt.ask(session.info, title: L("Проект и собеседники"), okTitle: L("Сохранить")) {
                recording.updateInfo(i)
            }
        }
    }

    // MARK: Updates

    private func startUpdates() {
        AppUpdater.announceIfUpdated()
        LiveVoices.sweep()
        phoneInbox.calls = calls
        phoneInbox.isBusy = { [weak self] in
            guard let self else { return true }
            return !self.isIdle || !self.engineUsable || !Self.setupDone || self.processing.hasWork
                || AppUpdater.shared.updateReady  // the quiet install would meet the modal
        }
        phoneInbox.onImported = { [weak self] dir, info in self?.processing.transcribe(dir, info) }
        phoneInbox.start()
        AppUpdater.shared.activity = { [weak self] in
            guard let self else { return .init() }
            let windowOpen = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
            return Updates.Activity(recording: !self.isIdle, processing: self.processing.hasWork,
                                    inCall: CallApps.inCall(), windowOpen: windowOpen, settingUp: !Self.setupDone)
        }
        AppUpdater.shared.onChange = { [weak self] in self?.stateChanged() }
        AppUpdater.shared.start()
    }

    private var isIdle: Bool {
        if case .idle = recording.state { return true }
        return false
    }

    // MARK: Quit

    func applicationWillTerminate(_ n: Notification) {
        LiveVoices.shared.abandon()
        MCPServer.shared.stop()
        // The search runs in its own process group: it would outlive the app.
        ProjectDiscovery.shared.stop()
    }

    /// Quit, restart or log out while recording: finish writing the files first
    /// (an m4a without an index can't be read), then quit. It can be transcribed later from "Calls".
    /// We wait on the same task as "Stop", whether recording is still running or already stopping.
    /// Transcription in progress: ask (except on shutdown and logout), stop the engine,
    /// and mark the call "not transcribed".
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if processing.isProcessing {
            if !Self.isSystemQuit {
                let alert = NSAlert()
                alert.messageText = L("Идёт расшифровка")
                alert.informativeText = L("Если выйти, расшифровка прервётся. Её можно будет запустить заново в окне «Звонки».")
                alert.addButton(withTitle: L("Выйти"))
                alert.addButton(withTitle: L("Отмена"))
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            }
        }
        processing.abortAll()  // also with nothing running: no waiting call may start while the app quits
        guard let finalize = recording.finalizeForTermination() else { return .terminateNow }
        Task {
            await finalize.value
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Quit caused by shutdown, restart or logout (the reason is in the quit event).
    private static var isSystemQuit: Bool {
        guard let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return false }
        let system = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown]
        return system.map { OSType($0) }.contains(reason)
    }
}
