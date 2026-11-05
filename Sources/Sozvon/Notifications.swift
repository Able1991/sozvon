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

    /// Notification button ("open" is covered by clicking the notification itself).
    var buttonTitle: String? {
        switch self {
        case .open: return nil
        case .openLog: return L("Открыть журнал")
        case .permissions: return L("Проверить разрешения")
        case .reinstallEngine: return L("Переустановить движок")
        case .downloadModel: return L("Скачать модель")
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
            let actions = a.buttonTitle.map { [UNNotificationAction(identifier: a.rawValue, title: $0, options: [.foreground])] } ?? []
            return UNNotificationCategory(identifier: a.category, actions: actions, intentIdentifiers: [])
        }))
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ title: String, _ body: String, action: NotifyAction = .open, url: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = action.category
        var info: [String: String] = ["action": action.rawValue]
        if let url { info["url"] = url.absoluteString }
        content.userInfo = info
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Show the banner even if the app is active.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = (info["action"] as? String).flatMap(NotifyAction.init(rawValue:)) ?? .open
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        await MainActor.run { self.onAction(action, url) }
    }
}

@MainActor
func notify(_ title: String, _ text: String, action: NotifyAction = .open, url: URL? = nil) {
    Notifier.shared.post(title, text, action: action, url: url)
}

/// Short system sounds for recording. Sozvon itself isn't captured (excludesCurrentProcessAudio).
enum Sounds {
    enum Kind { case start, stop, done }
    static let key = "sounds"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func play(_ k: Kind) {
        guard enabled else { return }
        let name: String
        switch k {
        case .start: name = "Tink"
        case .stop: name = "Pop"
        case .done: name = "Glass"
        }
        system("/System/Library/Sounds/\(name).aiff")
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
