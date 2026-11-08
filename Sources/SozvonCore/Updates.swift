// Updates: Sparkle in the app checks the appcast of the latest GitHub release once a day, downloads the new
// version in the background and installs it in a quiet moment. This file is the UI-free part: versions,
// links and the "quiet moment" rule.

import Foundation

public enum Updates {
    public static let repo = "Able1991/sozvon"
    /// The last version that ran on this Mac: tells "just updated" after a relaunch.
    public static let lastRunKey = "lastRunVersion"

    /// All releases with their notes (from CHANGELOG.md).
    public static let releasesURL = URL(string: "https://github.com/\(repo)/releases")!

    /// One version's release notes.
    public static func notesURL(_ version: String) -> URL {
        URL(string: "https://github.com/\(repo)/releases/tag/v\(version)")!
    }

    public static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Whether version a is newer than b: "0.10.1" > "0.9.3". Non-numeric suffixes (build hash) are ignored.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".")
                .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// At launch: the version Sozvon was just updated from, or nil (first run, same version, older build).
    /// Remembers `current` for the next launch.
    public static func updatedFrom(current: String = current, defaults: UserDefaults = .standard) -> String? {
        let last = defaults.string(forKey: lastRunKey)
        defaults.set(current, forKey: lastRunKey)
        guard let last, isNewer(current, than: last) else { return nil }
        return last
    }

    /// What Sozvon is doing right now, for the install rule.
    public struct Activity: Equatable, Sendable {
        public var recording, processing, inCall, windowOpen, settingUp: Bool
        public init(recording: Bool = false, processing: Bool = false, inCall: Bool = false,
                    windowOpen: Bool = false, settingUp: Bool = false) {
            self.recording = recording; self.processing = processing; self.inCall = inCall
            self.windowOpen = windowOpen; self.settingUp = settingUp
        }
    }

    /// A downloaded update restarts Sozvon for a couple of seconds: only when nothing is going on.
    /// No recording or transcription, no call holding the microphone (the user may press Record any moment),
    /// no open window (the user is reading or editing something), no setup assistant.
    public static func canInstallQuietly(_ a: Activity) -> Bool {
        !(a.recording || a.processing || a.inCall || a.windowOpen || a.settingUp)
    }

    /// "Check now" restarts Sozvon right away if the user installs: never during a recording or transcription.
    public static func canCheckNow(_ a: Activity) -> Bool {
        !(a.recording || a.processing)
    }
}
