// Sozvon: a menu bar button that records a call (Zoom, Google Meet, anything) as two tracks
// via ScreenCaptureKit, with no virtual audio drivers:
//   system.m4a  computer audio (the other participants)
//   mic.m4a     microphone (me)
// After stopping, it saves the call details to call.json and runs the engine: bin/process_call.py <folder>.
//
// AppDelegate only wires the parts together: recording (RecordingController), transcription
// (ProcessingController), menu (MenuController), windows (WindowsRegistry), panel (FloatingPanel).

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
    private var update: Updates.Release?
    private var updateTimer: Timer?
    private var tickTimer: Timer?
    /// Single-instance lock, held until the app quits.
    private var instanceLock: InstanceLock?

    var engineState: EngineState {
        EngineState.evaluate(data: Paths.data, model: Settings.shared.model, isDevEngine: Paths.isDevEngine)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        guard takeInstanceLock() else { return }
        try? FileManager.default.createDirectory(at: Paths.calls, withIntermediateDirectories: true)
        // The previous run quit mid-transcription: the call must not stay "transcribing" forever.
        let calls = Paths.calls
        Task.detached(priority: .utility) { CallFile.failStaleProcessing(in: calls) }
        Engine.syncCode()
        Notifier.shared.setup()
        Notifier.shared.onAction = { [weak self] action, url in self?.processing.handle(action, url: url) }
        MenuController.installMainMenu(settings: { [weak self] in self?.showSettings() },
                                       calls: { [weak self] in self?.showCalls() },
                                       quit: { NSApp.terminate(nil) })
        wire()
        MCPServer.shared.start()
        processing.updateEngineIfNeeded()
        checkUpdates()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkUpdates() }
        }
        stateChanged()

        #if SOZVON_PREVIEW
        if PreviewDriver.run(self) { return }
        #endif

        // A relaunch after granting screen recording permission resumes the setup assistant at the same step.
        // integer(forKey:) reads both a number from defaults and a string from launch arguments (-setupResumeStep 3).
        let resume = UserDefaults.standard.object(forKey: "setupResumeStep") != nil
            ? UserDefaults.standard.integer(forKey: "setupResumeStep") : nil
        UserDefaults.standard.removeObject(forKey: "setupResumeStep")
        if !engineState.isUsable || resume != nil {
            showSetup(step: resume.flatMap(SetupModel.Step.init(rawValue:)) ?? .welcome)
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
            showSetup: { [weak self] in self?.showSetup() },
            openLast: { [weak self] in if let t = self?.processing.lastTranscript { NSWorkspace.shared.open(t) } },
            redoLast: { [weak self] in self?.processing.retranscribeLast() },
            showCalls: { [weak self] in self?.showCalls() },
            showProjects: { [weak self] in self?.showProjects() },
            showSettings: { [weak self] in self?.showSettings() },
            togglePanel: { [weak self] in
                FloatingPanel.enabled.toggle()
                self?.stateChanged()
            },
            openUpdate: { [weak self] in if let u = self?.update { NSWorkspace.shared.open(u.url) } },
            quit: { NSApp.terminate(nil) }
        ), snapshot: { [unowned self] in self.menuSnapshot })

        recording.initialInfo = {
            CallInfo(profile: UserDefaults.standard.string(forKey: "lastProfile") ?? "", languages: Settings.shared.languages)
        }
        recording.onChange = { [weak self] in self?.stateChanged() }
        recording.onLevels = { [weak self] in self?.panel.fit() }
        recording.onSaved = { [weak self] session in self?.processing.recorded(session) }
        processing.onAnswered = { [weak self] dir in self?.recording.dismissSaved(dir) }
        processing.onChange = { [weak self] in self?.stateChanged() }
        processing.showSetup = { [weak self] step in self?.showSetup(step: step) }
        calls.onRetranscribe = { [weak self] call in
            guard let self, !self.calls.isRecording(call.url) else { NSSound.beep(); return }
            self.processing.retranscribe(call.url)
        }

        panel.model.onRecord = { [weak self] in self?.recording.start() }
        panel.model.onStop = { [weak self] in self?.recording.stop() }
        panel.model.onHide = { [weak self] in
            FloatingPanel.enabled = false
            self?.stateChanged()
        }
    }

    private var menuSnapshot: MenuSnapshot {
        let lastDir = processing.lastDir
        return MenuSnapshot(recording: recording.state, processing: processing.isProcessing,
                            engineUpdating: processing.isEngineUpdating, engine: engineState, update: update,
                            hasLastTranscript: processing.lastTranscript != nil,
                            canRedoLast: lastDir.map { !recording.state.isCapturing && !processing.contains($0) } ?? false,
                            panelEnabled: FloatingPanel.enabled)
    }

    /// Recording or transcription state changed: update the icon, panel and timer.
    func stateChanged() {
        let s = recording.state
        let p = panel.model
        // Folder of the recording in progress in "Calls": shown as recording, can't be deleted or transcribed.
        let recDir: URL? = s.isCapturing || s.isStarting ? s.dir : nil
        if calls.recordingDir != recDir { calls.recordingDir = recDir }
        if s.isCapturing {
            p.state = .recording
        } else if processing.isProcessing {
            p.state = .processing
        } else if case .saved = s {
            p.state = .saved
        } else {
            p.state = .idle
        }
        p.elapsed = s.session?.elapsed() ?? "0:00"
        // Without a ready engine, don't show the "Record" capsule: the recording couldn't be transcribed anyway.
        if engineState.isUsable || s.isCapturing || processing.isProcessing { panel.sync() } else { panel.hide() }
        menu?.stateChanged()
        if s.isRecording, tickTimer == nil {
            // In .common mode the timer keeps running while the menu is open.
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(t, forMode: .common)
            tickTimer = t
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

    func showSetup(step: SetupModel.Step = .welcome) {
        WindowsRegistry.shared.show(.hosting("setup", width: 560) {
            SetupView(m: SetupModel(step: step)) { [weak self] in
                WindowsRegistry.shared.close("setup")
                MCPServer.shared.start()
                self?.stateChanged()
            }
        })
    }

    /// Settings window in the style of Apple's apps: icon tabs in the toolbar.
    func showSettings(tab: Int? = nil) {
        let spec = WindowSpec(key: "settings", style: [.titled, .closable], contentSize: NSSize(width: 480, height: 300),
                              toolbarStyle: .preference) { [weak self] in
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = []  // no animation when switching tabs, like System Settings
            for t in SettingsView.Tab.allCases {
                let host = NSHostingController(rootView: SettingsView(tab: t, reinstall: {
                    WindowsRegistry.shared.close("settings")
                    self?.showSetup(step: .install)
                }, onPanelChange: {
                    self?.stateChanged()
                }))
                // We set the size ourselves: all tabs share one height, so the window doesn't jump or collapse.
                host.sizingOptions = []
                host.preferredContentSize = NSSize(width: 480, height: 300)
                host.title = t.title  // window title = tab name, like System Settings
                let item = NSTabViewItem(viewController: host)
                item.label = t.title
                item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
                tabs.addTabViewItem(item)
            }
            if let tab, tab < tabs.tabViewItems.count { tabs.selectedTabViewItemIndex = tab }
            return tabs
        }
        WindowsRegistry.shared.show(spec, onClose: { [weak self] in self?.stateChanged() })
    }

    func showProjects() {
        WindowsRegistry.shared.show(.hosting("projects", title: L("Проекты"), width: 460, transparentTitle: false) {
            ProjectsView()
        })
    }

    func showCalls() {
        let spec = WindowSpec(key: "calls", title: L("Звонки"),
                              style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              contentSize: NSSize(width: 960, height: 640), toolbarStyle: .unified,
                              autosaveName: "SozvonCalls") { [calls] in
            NSHostingController(rootView: CallsView(m: calls))
        }
        if WindowsRegistry.shared.window("calls") == nil { calls.startWatching() }
        WindowsRegistry.shared.show(spec, onClose: { [calls] in calls.stopWatching() })
    }

    func editInfo() {
        if CallInfoPrompt.isOpen { CallInfoPrompt.bringToFront(); return }
        guard let session = recording.state.session else { return }
        Task {
            if let i = await CallInfoPrompt.ask(session.info, title: L("Проект и собеседники"), okTitle: L("Сохранить")) {
                recording.updateInfo(i)
            }
        }
    }

    // MARK: Updates

    private func checkUpdates(force: Bool = false) {
        Task {
            let r = await Updates.check(force: force)
            update = r
            stateChanged()
            // Notify once per new version.
            if let r, UserDefaults.standard.string(forKey: Updates.notifiedKey) != r.version {
                UserDefaults.standard.set(r.version, forKey: Updates.notifiedKey)
                notify(L("Доступна версия %@", r.version), L("Новая версия Sozvon на GitHub"), url: r.url)
            }
        }
    }

    // MARK: Quit

    func applicationWillTerminate(_ n: Notification) { MCPServer.shared.stop() }

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
            processing.abortAll()
        }
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
