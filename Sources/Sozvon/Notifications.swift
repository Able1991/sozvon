// System notifications from Sozvon (with its own icon) with a click action, plus recording sounds.

import AppKit
import AudioToolbox
import SozvonCore
import UserNotifications

/// What to do when the notification is clicked.
enum NotifyAction: String, CaseIterable {
    /// Open a file (transcript, release page).
    case open
    case openLog
    case permissions
    case reinstallEngine
    case downloadModel
    /// "A call is on. Record?" (the panel is hidden). Clicking the notification itself does nothing:
    /// only the "Record" button starts a recording.
    case callPrompt
    case record
    case notNow
    /// The automatic stop is counting down (the panel is hidden): one button to keep recording.
    case callEnded
    case keepRecording
    /// A call waits for its description: open "What was the call about?" (`url` is the call folder).
    case describeCall
    /// A source went silent mid-recording: System Settings → Sound.
    case openSoundSettings
    /// Show the call (`url` is its folder) in the Calls window.
    case openCall
    /// System audio goes through ScreenCaptureKit (the tap is off): Privacy → Screen & System Audio Recording.
    case systemAudioPermission

    /// Notification button ("open" is covered by clicking the notification itself).
    var buttonTitle: String? {
        switch self {
        case .open, .callPrompt, .openCall, .callEnded: return nil
        case .openLog: return L("Открыть журнал")
        case .permissions: return L("Проверить разрешения")
        case .reinstallEngine: return L("Переустановить движок")
        case .downloadModel: return L("Скачать модель")
        case .record: return L("Записать")
        case .notNow: return L("Не сейчас")
        case .keepRecording: return L("Продолжить запись")
        case .describeCall: return L("Описать")
        case .openSoundSettings: return L("Настройки звука")
        case .systemAudioPermission: return L("Открыть настройки")
        }
    }

    /// Buttons of this notification kind.
    var buttons: [NotifyAction] {
        switch self {
        case .callPrompt: return [.record, .notNow]
        case .callEnded: return [.keepRecording]
        default: return buttonTitle == nil ? [] : [self]
        }
    }

    var category: String { "sozvon.\(rawValue)" }
}

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Action handler; by default just opens the file.
    var onAction: (NotifyAction, URL?) -> Void = { _, url in
        if let url { NSWorkspace.shared.open(url) }
    }

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.setNotificationCategories(Set(NotifyAction.allCases.map { a in
            let actions = a.buttons.compactMap { b in
                b.buttonTitle.map { UNNotificationAction(identifier: b.rawValue, title: $0, options: b == .notNow || b == .keepRecording ? [] : [.foreground]) }
            }
            return UNNotificationCategory(identifier: a.category, actions: actions, intentIdentifiers: [])
        }))
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ title: String, _ body: String, action: NotifyAction = .open, url: URL? = nil,
              id: String = UUID().uuidString, sound: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        content.categoryIdentifier = action.category
        var info: [String: String] = ["action": action.rawValue]
        if let url { info["url"] = url.absoluteString }
        content.userInfo = info
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Take back a notification that is no longer true (the call ended, the call was described).
    func remove(id: String) {
        let c = UNUserNotificationCenter.current()
        c.removeDeliveredNotifications(withIdentifiers: [id])
        c.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // Show the banner even if the app is active.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        // A button press names its own action; a click on the notification uses the one it was posted with.
        let action = NotifyAction(rawValue: response.actionIdentifier)
            ?? (info["action"] as? String).flatMap(NotifyAction.init(rawValue:)) ?? .open
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        await MainActor.run { self.onAction(action, url) }
    }
}

@MainActor
func notify(_ title: String, _ text: String, action: NotifyAction = .open, url: URL? = nil) {
    Notifier.shared.post(title, text, action: action, url: url)
}

/// Short system sounds for recording. Sozvon itself isn't recorded (the tap and ScreenCaptureKit leave it out).
enum Sounds {
    enum Kind { case start, stop, done, mark }
    static let key = "sounds"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    @MainActor static func play(_ k: Kind) {
        guard enabled else { return }
        // Without headphones the call's microphone would hear the chime and the other side would too
        // (a stop before hanging up included).
        if k != .done, CallApps.inCall() { return }
        switch k {
        // Our own pair: two soft tones up to start, the same tones down to stop.
        case .start: bundled("record-start")
        case .stop: bundled("record-stop")
        case .done: system("/System/Library/Sounds/Glass.aiff")
        case .mark: system("/System/Library/Sounds/Morse.aiff")
        }
    }

    private static func bundled(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return }
        system(url.path)
    }

    /// Like a system UI sound (Finder): plays at the quiet "UI sounds" volume
    /// and is muted along with them in System Settings → Sound.
    static func system(_ path: String) {
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &id) == noErr else { return }
        let sound = id
        AudioServicesPlaySystemSoundWithCompletion(sound) { AudioServicesDisposeSystemSoundID(sound) }
    }

    static func trash() {
        system("/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif")
    }
}
