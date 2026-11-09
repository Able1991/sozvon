// Updates through Sparkle. Feed: appcast.xml of the latest GitHub release (SUFeedURL in Info.plist),
// every update is checked against the EdDSA key (SUPublicEDKey) and the Developer ID signature.
// Automatic mode (default): Sparkle checks once a day, downloads in the background and hands us "install now";
// we call it in a quiet moment (Updates.canInstallQuietly), Sozvon restarts in a couple of seconds.
// Manual mode: Sparkle only finds the update, the menu shows "Version X is available", the user installs.

import AppKit
import Sparkle
import SozvonCore

@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    /// What Sozvon is doing now (from AppDelegate).
    var activity: () -> Updates.Activity = { .init() }
    /// The menu and Settings follow `available`.
    var onChange: () -> Void = {}

    /// A version found but not installed yet (manual mode, or automatic mode waiting for a quiet moment).
    private(set) var available: String?
    private var controller: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?
    private var timer: Timer?

    /// Not in a preview build (screenshots and UI tests) and not without a feed in Info.plist.
    static var isSupported: Bool {
        #if SOZVON_PREVIEW
        return false
        #else
        return Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        #endif
    }

    func start() {
        guard Self.isSupported, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        // A downloaded update waits for a quiet moment: look once a minute.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { AppUpdater.shared.installIfQuiet() }
        }
    }

    var updater: SPUUpdater? { controller?.updater }

    /// "Install automatically" in Settings: download and install by itself, or only tell.
    var automatic: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? true }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    var canCheck: Bool { updater?.canCheckForUpdates ?? false }

    /// "Check now" in Settings and the menu item: Sparkle's own window (found, release notes, Install).
    func checkNow() {
        guard Updates.canCheckNow(activity()) else { NSSound.beep(); return }
        if let installNow { self.installNow = nil; installNow(); return }
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    /// A downloaded update waits for a quiet moment: the quit that installs it must not meet a new transcription.
    var updateReady: Bool { installNow != nil }

    /// Called on every state change and once a minute.
    func installIfQuiet() {
        guard let installNow, Updates.canInstallQuietly(activity()) else { return }
        self.installNow = nil
        installNow()
    }

    /// After a relaunch into a newer version: one notification with a link to what's new.
    static func announceIfUpdated() {
        guard Updates.updatedFrom() != nil else { return }
        notify(L("Sozvon обновлён до %@", Updates.current), L("Что нового"), url: Updates.notesURL(Updates.current))
    }

    private func setAvailable(_ v: String?) {
        guard available != v else { return }
        available = v
        onChange()
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    /// Automatic mode: the update is downloaded and ready. We keep "install now" and use it in a quiet moment;
    /// if Sozvon quits first, Sparkle installs it on quit by itself.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        nonisolated(unsafe) let block = immediateInstallationBlock
        MainActor.assumeIsolated {
            installNow = block
            setAvailable(version)
            installIfQuiet()
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        MainActor.assumeIsolated { if installNow == nil { setAvailable(nil) } }
    }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
    /// Sozvon lives in the menu bar: Sparkle must not pop a window over a call. We show a menu item instead.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            if !userInitiated && !handleShowingUpdate { setAvailable(version) }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { if installNow == nil { setAvailable(nil) } }
    }
}
