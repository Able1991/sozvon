// Around a call: "A call is on in Zoom. Record?" (or, if chosen in Settings, the same capsule counting down to an
// automatic start), and the optional automatic stop once the call is over. On the floating panel, or as a
// notification when the panel is off. Rules live in SozvonCore (CallWatcher, CallDetector, CallEndDetector).
// An automatic start or stop always shows a countdown with a way to cancel it.

import AppKit
import SozvonCore

@MainActor
final class CallPromptController {
    private static let notificationID = "sozvon.callPrompt"
    private static let endNotificationID = "sozvon.callEnded"

    static var mode: CallStartMode {
        get { CallAutomation.mode() }
        set { CallAutomation.setMode(newValue) }
    }
    static var autoStop: Bool {
        get { CallAutomation.autoStop() }
        set { CallAutomation.setAutoStop(newValue) }
    }

    private let watcher = CallWatcher(source: CoreAudioMicSource())
    private var notified: CallApp?
    private var end = CallEndDetector()
    private var endNotified = false
    private var startDeadline: Date?
    private var ticker: Timer?

    /// Recording, starting, stopping, the call prompt open, or no engine to transcribe with: no prompt.
    var isBusy: () -> Bool = { false }
    /// A recording is running (the automatic stop watches only then).
    var isRecording: () -> Bool = { false }
    /// The other side's track has sound right now: the call is not over, whatever the microphone says.
    var otherSideAudible: () -> Bool = { false }
    /// The prompt or a countdown changed (redraw the panel).
    var onChange: () -> Void = {}
    /// "Record" pressed, or the start countdown ran out.
    var onRecord: () -> Void = {}
    /// The stop countdown ran out.
    var onStop: () -> Void = {}

    /// Seconds left before the automatic start, while counting down.
    private(set) var startIn: Int?
    /// Seconds left before the automatic stop, while counting down.
    private(set) var stopIn: Int?

    init() {
        watcher.onPrompt = { [weak self] app in self?.promptChanged(app) }
        watcher.onRefresh = { [weak self] in self?.checkEnd() }
        watcher.isBusy = { [weak self] in
            guard let self else { return true }
            return Self.mode == .off || self.isBusy()
        }
        watcher.isSafariRunning = {
            !NSRunningApplication.runningApplications(withBundleIdentifier: CallApps.safariBundleID).isEmpty
        }
    }

    var prompt: CallApp? { watcher.prompt }

    /// The capsule's text: a question, or the countdown to the automatic start.
    func text(_ app: CallApp) -> String {
        if let n = startIn { return L("Звонок в %@ · запись через %@ с", app.name, n) }
        return L("Идёт звонок в %@. Записать?", app.name)
    }

    /// Settings or Sozvon's state changed: start or stop listening, re-check busy.
    func sync() {
        if Self.mode != .off || Self.autoStop { watcher.start() } else { watcher.stop() }
        watcher.refresh()
        checkEnd()
    }

    /// "Record" (now, without waiting for the countdown).
    func record() {
        cancelStart()
        watcher.dismiss()
        onRecord()
    }

    /// "Not now" / "Don't record": nothing for this call until its app lets go of the microphone.
    func notNow() {
        cancelStart()
        watcher.dismiss()
    }

    /// "Keep recording": the call looked over, but the recording goes on.
    func keepRecording() {
        end.keepRecording()
        setStopIn(nil)
    }

    // MARK: Start

    private func promptChanged(_ app: CallApp?) {
        if app != nil, Self.mode == .record {
            if startDeadline == nil { startDeadline = Date().addingTimeInterval(TimeInterval(CallAutomation.startCountdown)) }
        } else {
            cancelStart()
        }
        updateStart()
        if let app, !FloatingPanel.enabled {
            // The panel is off: a notification with the same choices, posted once per prompt.
            if notified != app {
                notified = app
                Notifier.shared.post(text(app), "", action: .callPrompt, id: Self.notificationID, sound: false)
            }
        } else if notified != nil {
            notified = nil
            Notifier.shared.remove(id: Self.notificationID)
        }
        onChange()
    }

    private func cancelStart() {
        startDeadline = nil
        startIn = nil
        updateTicker()
    }

    private func updateStart() {
        guard let d = startDeadline else { return }
        if Self.mode != .record {  // changed in Settings during the countdown
            cancelStart()
            onChange()
            return
        }
        let left = Int(d.timeIntervalSinceNow.rounded(.up))
        if left <= 0, prompt != nil {
            record()
            return
        }
        if startIn != max(left, 0) {
            startIn = max(left, 0)
            onChange()
        }
        updateTicker()
    }

    // MARK: End

    private func checkEnd() {
        guard Self.autoStop, isRecording() else {
            if end != CallEndDetector() || stopIn != nil { end = CallEndDetector(); setStopIn(nil) }
            updateTicker()
            return
        }
        defer { updateTicker() }
        guard let left = end.update(inCall: watcher.inCall, otherSideAudible: otherSideAudible(), now: Date()) else {
            setStopIn(nil)
            return
        }
        if left <= 0 {
            end = CallEndDetector()
            setStopIn(nil)
            onStop()
            return
        }
        setStopIn(Int(left.rounded(.up)))
    }

    private func setStopIn(_ n: Int?) {
        let wasCounting = stopIn != nil
        guard stopIn != n else { return }
        stopIn = n
        if n != nil, !wasCounting, !FloatingPanel.enabled {
            endNotified = true
            Notifier.shared.post(L("Звонок закончился"), L("Запись остановится через %@ секунд", CallAutomation.stopGrace),
                                 action: .callEnded, id: Self.endNotificationID, sound: false)
        } else if n == nil, endNotified {
            endNotified = false
            Notifier.shared.remove(id: Self.endNotificationID)
        }
        updateTicker()
        onChange()
    }

    // MARK: Countdown clock

    /// Once a second while a countdown runs: the capsule shows the seconds, and the deadline is checked.
    private func updateTicker() {
        // After the call app let go, also while the other side is still heard: the countdown starts when it goes quiet.
        let waitingForEnd = Self.autoStop && end.armed && !end.kept && !watcher.inCall && isRecording()
        let needed = startDeadline != nil || stopIn != nil || waitingForEnd
        if needed, ticker == nil {
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateStart()
                    self.checkEnd()
                }
            }
            RunLoop.main.add(t, forMode: .common)  // also while the menu or an alert is open
            ticker = t
        } else if !needed {
            ticker?.invalidate()
            ticker = nil
        }
    }
}

extension CallApps {
    /// A known call app is using the microphone right now (Zoom, Meet in a browser, Telegram, ...).
    @MainActor
    static func inCall() -> Bool {
        let safari = !NSRunningApplication.runningApplications(withBundleIdentifier: safariBundleID).isEmpty
        let own = ProcessInfo.processInfo.processIdentifier
        return CoreAudioMicSource().activeClients().contains { c in
            c.pid != own && CallApps.app(for: c, safariRunning: safari) != nil
        }
    }
}
