// "A call is on in Zoom. Record?": on the floating panel, or as a notification when the panel is off.
// Detection rules live in SozvonCore (CallWatcher, CallDetector). Sozvon never starts recording here:
// only the user's "Record" press does, exactly like the Record button.

import AppKit
import SozvonCore

@MainActor
final class CallPromptController {
    static let key = "callPrompt"
    /// Settings → Panel: "Offer to record when a call starts" (on by default).
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    private static let notificationID = "sozvon.callPrompt"

    private let watcher = CallWatcher(source: CoreAudioMicSource())
    private var notified: CallApp?

    /// Recording, starting, stopping, the call prompt open, or no engine to transcribe with: no prompt.
    var isBusy: () -> Bool = { false } { didSet { watcher.isBusy = isBusy } }
    /// The prompt changed (redraw the panel).
    var onChange: () -> Void = {}
    /// "Record" pressed.
    var onRecord: () -> Void = {}

    init() {
        watcher.onPrompt = { [weak self] app in self?.promptChanged(app) }
        watcher.isSafariRunning = {
            !NSRunningApplication.runningApplications(withBundleIdentifier: CallApps.safariBundleID).isEmpty
        }
    }

    var prompt: CallApp? { watcher.prompt }

    static func text(_ app: CallApp) -> String { L("Идёт звонок в %@. Записать?", app.name) }

    /// Settings or Sozvon's state changed: start or stop listening, re-check busy.
    func sync() {
        if Self.enabled { watcher.start() } else { watcher.stop() }
        watcher.refresh()
    }

    func record() {
        watcher.dismiss()
        onRecord()
    }

    func notNow() { watcher.dismiss() }

    private func promptChanged(_ app: CallApp?) {
        if let app, !FloatingPanel.enabled {
            // The panel is off: a notification with the same two choices, posted once per prompt.
            if notified != app {
                notified = app
                Notifier.shared.post(Self.text(app), "", action: .callPrompt, id: Self.notificationID, sound: false)
            }
        } else if notified != nil {
            notified = nil
            Notifier.shared.remove(id: Self.notificationID)
        }
        onChange()
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
