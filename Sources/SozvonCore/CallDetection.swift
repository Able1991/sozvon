// "A call is on. Record?": notice that a call app started using the microphone while Sozvon is idle.
// Sozvon never records by itself: this only offers the Record button, the user presses it (consent).
//
//   MicActivitySource  which processes capture audio input right now (Core Audio, or a fake in tests)
//   CallDetector       pure rules: known call apps only, never Sozvon itself, a 5 second debounce,
//                      "Not now" and a finished recording suppress the app until it releases the mic
//   CallWatcher        glue: asks the source on every change, re-checks when the debounce runs out

import Foundation

/// A process that is capturing audio input.
public struct MicClient: Equatable, Hashable, Sendable {
    public let pid: Int32
    /// Bundle id; empty for daemons without a bundle.
    public let bundleID: String
    /// Executable name (fallback for processes without a bundle id).
    public let processName: String

    public init(pid: Int32, bundleID: String, processName: String = "") {
        self.pid = pid
        self.bundleID = bundleID
        self.processName = processName
    }
}

/// A call app as the user knows it. Helper processes (Chrome Helper, WebKit GPU) map to their app.
public struct CallApp: Equatable, Hashable, Sendable {
    /// Display name, also the identity: Chrome and its helpers are one app.
    public let name: String
    public init(name: String) { self.name = name }
}

public enum CallApps {
    /// Bundle id (or bundle id prefix followed by ".") to app name. Only these apps trigger the prompt:
    /// dictation, Siri, voice memos and anything unknown never do. Browsers are here for Meet and other web calls.
    static let byBundle: [(String, String)] = [
        ("us.zoom", "Zoom"),
        ("ru.keepcoder.Telegram", "Telegram"),
        ("com.tdesktop.Telegram", "Telegram"),
        ("org.telegram.desktop", "Telegram"),
        ("com.apple.Safari", "Safari"),
        ("com.google.Chrome", "Chrome"),
        ("com.microsoft.edgemac", "Edge"),
        ("org.mozilla.firefox", "Firefox"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.brave.Browser", "Brave"),
        ("ru.yandex.desktop.yandex-browser", "Yandex Browser"),
        ("ru.trueconf", "TrueConf"),
        ("com.trueconf", "TrueConf"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.microsoft.teams", "Teams"),
        ("com.microsoft.teams2", "Teams"),
        ("com.hnc.Discord", "Discord"),
        ("com.skype.skype", "Skype"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.webex.meetingmanager", "Webex"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("desktop.WhatsApp", "WhatsApp"),
    ]

    /// Daemons without a bundle id, by executable name. FaceTime audio runs in avconferenced.
    static let byProcess: [String: String] = ["avconferenced": "FaceTime"]

    /// Safari captures the microphone in the WebKit GPU process, which every WebKit app shares (Mail, a Help
    /// viewer, any app with a web view): it counts as Safari only while Safari is running, otherwise it is ignored.
    static let webKitGPU = "com.apple.WebKit.GPU"
    public static let safariBundleID = "com.apple.Safari"

    public static func app(for c: MicClient, safariRunning: Bool = false) -> CallApp? {
        let b = c.bundleID
        if b == webKitGPU || b.hasPrefix(webKitGPU + ".") { return safariRunning ? CallApp(name: "Safari") : nil }
        if !b.isEmpty, let hit = byBundle.first(where: { b == $0.0 || b.hasPrefix($0.0 + ".") }) {
            return CallApp(name: hit.1)
        }
        return byProcess[c.processName].map(CallApp.init(name:))
    }
}

/// Who captures audio input. The real one reads Core Audio state (`CoreAudioMicSource`); tests use a fake.
@MainActor
public protocol MicActivitySource: AnyObject {
    /// Processes capturing audio input right now.
    func activeClients() -> [MicClient]
    /// Start observing; `onChange` runs on the main thread whenever the answer may have changed.
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// The prompt rules, without clocks or Core Audio: the caller passes the time and the clients.
public struct CallDetector: Sendable {
    /// A call app must hold the microphone this long (a quick mic test or a voice message is not a call).
    public static let debounce: TimeInterval = 5

    public let ownPID: Int32
    public let ownBundleID: String
    /// When each call app started holding the mic (continuously).
    private var since: [CallApp: Date] = [:]
    /// Apps that get no prompt until they release the mic ("Not now", or the call was recorded).
    private(set) var suppressed: Set<CallApp> = []
    /// The app to offer recording for, or nil.
    public private(set) var prompt: CallApp?

    public init(ownPID: Int32, ownBundleID: String) {
        self.ownPID = ownPID
        self.ownBundleID = ownBundleID
    }

    /// New state of the world. `busy`: Sozvon is recording (or not ready to): no prompt, and the apps
    /// on the mic right now stay quiet until they release it, so stopping a recording mid-call doesn't nag.
    /// `safariRunning`: whether the shared WebKit GPU process may stand for Safari (CallApps.app).
    @discardableResult
    public mutating func update(_ clients: [MicClient], now: Date, busy: Bool, safariRunning: Bool = false) -> CallApp? {
        let apps = Set(clients.filter { $0.pid != ownPID && ($0.bundleID.isEmpty || $0.bundleID != ownBundleID) }
            .compactMap { CallApps.app(for: $0, safariRunning: safariRunning) })
        // Released the mic: forget it, including "Not now".
        for a in Array(since.keys) where !apps.contains(a) { since[a] = nil }
        suppressed.formIntersection(apps)
        for a in apps where since[a] == nil { since[a] = now }
        if busy {
            suppressed.formUnion(apps)
            prompt = nil
            return nil
        }
        // Keep the current prompt while it is valid; otherwise the app that has held the mic longest.
        if let p = prompt, apps.contains(p), !suppressed.contains(p) { return p }
        prompt = since.filter { !suppressed.contains($0.key) && now.timeIntervalSince($0.value) >= Self.debounce }
            .min { $0.value != $1.value ? $0.value < $1.value : $0.key.name < $1.key.name }?.key
        return prompt
    }

    /// "Not now": no prompt for this app until it releases the mic.
    public mutating func dismiss() {
        if let p = prompt { suppressed.insert(p) }
        prompt = nil
    }

    /// When the next app passes the debounce (to check again then), or nil.
    public func nextCheck() -> Date? {
        guard prompt == nil else { return nil }
        return since.filter { !suppressed.contains($0.key) }.values.min()?.addingTimeInterval(Self.debounce)
    }
}

/// Runs the detector against a source: on every source change and when the debounce runs out.
@MainActor
public final class CallWatcher {
    private let source: MicActivitySource
    private var detector: CallDetector
    private let now: () -> Date
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var generation = 0
    public private(set) var isRunning = false

    /// Sozvon is recording or can't record: no prompt.
    public var isBusy: () -> Bool = { false }
    /// Safari is running (NSWorkspace in the app): only then does the shared WebKit GPU process count as Safari.
    public var isSafariRunning: () -> Bool = { false }
    /// The prompt changed (nil: hide it).
    public var onPrompt: (CallApp?) -> Void = { _ in }
    public var prompt: CallApp? { detector.prompt }

    public init(source: MicActivitySource,
                ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                ownBundleID: String = Bundle.main.bundleIdentifier ?? "",
                now: @escaping () -> Date = Date.init,
                schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = CallWatcher.mainQueue) {
        self.source = source
        self.detector = CallDetector(ownPID: ownPID, ownBundleID: ownBundleID)
        self.now = now
        self.schedule = schedule
    }

    public static func mainQueue(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            work()
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        source.start { [weak self] in self?.refresh() }
        refresh()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        source.stop()
        detector = CallDetector(ownPID: detector.ownPID, ownBundleID: detector.ownBundleID)
        onPrompt(nil)
    }

    /// Ask the source again (also after Sozvon's own state changed: recording started or stopped).
    public func refresh() {
        guard isRunning else { return }
        let before = detector.prompt
        let t = now()
        let clients = source.activeClients()
        let safari = clients.contains { $0.bundleID.hasPrefix(CallApps.webKitGPU) } && isSafariRunning()
        detector.update(clients, now: t, busy: isBusy(), safariRunning: safari)
        if detector.prompt != before { onPrompt(detector.prompt) }
        generation += 1
        if let next = detector.nextCheck() {
            let g = generation
            schedule(max(0.1, next.timeIntervalSince(t))) { [weak self] in
                guard let self, self.generation == g else { return }
                self.refresh()
            }
        }
    }

    /// "Not now".
    public func dismiss() {
        guard detector.prompt != nil else { return }
        detector.dismiss()
        onPrompt(nil)
    }
}
