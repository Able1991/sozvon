// "System Audio Recording": the permission behind the Core Audio process tap that records the other side of a
// call (Recorder's SystemTap). macOS asks for it the first time a tap starts. There is no public API to read
// its state, so the status comes from TCC's preflight call when the system has it, and is `.unknown` otherwise.

import Darwin
import Foundation
import SozvonCore

@MainActor
enum SystemAudioPermission {
    enum Status: Equatable {
        case granted
        case denied
        /// Never asked, or the state can't be read on this macOS.
        case unknown
    }

    /// `TCCAccessPreflight(service, options)`: 0 granted, 1 denied, anything else not decided yet.
    /// Read-only, never shows a prompt.
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32

    private static let preflight: Preflight? = {
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Preflight.self)
    }()

    static var status: Status {
        #if SOZVON_PREVIEW
        if let s = previewStatus { return s }
        #endif
        guard let preflight else { return .unknown }
        return status(preflight: preflight("kTCCServiceAudioCapture" as CFString, nil))
    }

    static func status(preflight code: Int32) -> Status {
        switch code {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Start a process tap for half a second and throw the audio away: the first time, this is what makes
    /// macOS show its prompt. Already decided: nothing visible happens. Returns the status afterwards.
    static func request() async -> Status {
        let sink = AudioSink.discarding()
        if let tap = try? SystemTap(sink: sink) {
            try? await Task.sleep(for: .milliseconds(500))
            tap.stop()
        }
        _ = sink.finish()
        return status
    }

    #if SOZVON_PREVIEW
    /// Screenshot states (`--setup-state denied`).
    static var previewStatus: Status?
    #endif
}

/// The three permissions a recording needs, for the setup assistant and Settings: the microphone (your voice),
/// screen recording (ScreenCaptureKit, which captures the microphone) and system audio recording (the process
/// tap, the other side of the call). Refreshed by the screens while they are visible.
@MainActor
final class RecordingPermissions: ObservableObject {
    @Published private(set) var mic = Permissions.mic
    @Published private(set) var screen = Permissions.screen
    @Published private(set) var systemAudio = RecordingPermissions.effectiveStatus
    /// The system audio check is running (its prompt may be on screen).
    @Published private(set) var checkingSystemAudio = false
    /// The check ran in this window, yet the state still reads as unknown (this macOS doesn't tell):
    /// System Settings is the only place to look.
    @Published private(set) var systemAudioAsked = false

    /// What a recording can't start without. System audio is optional (FaceTime only).
    var requiredGranted: Bool { mic && screen }

    /// The test recording heard the other side through a process tap: proof this macOS doesn't give otherwise.
    static let heardKey = "systemAudioHeard"
    private static var effectiveStatus: SystemAudioPermission.Status {
        let s = SystemAudioPermission.status
        return s == .unknown && UserDefaults.standard.bool(forKey: heardKey) ? .granted : s
    }

    /// The test recording ran: with a tap it asked macOS (its prompt, the first time), and a signal through it
    /// proves the permission. No signal proves nothing (the prompt may still have been up, the Mac muted).
    func noteTestRecording(tapStarted: Bool, heard: Bool) {
        if tapStarted { systemAudioAsked = true }
        if heard { UserDefaults.standard.set(true, forKey: Self.heardKey) }
        refresh()
    }

    func refresh() {
        #if SOZVON_PREVIEW
        if SystemAudioPermission.previewStatus == .denied {
            mic = false; screen = false; systemAudio = .denied
            return
        }
        #endif
        if mic != Permissions.mic { mic = Permissions.mic }
        if screen != Permissions.screen { screen = Permissions.screen }
        // While the prompt is up, the state is still undecided: keep it.
        if !checkingSystemAudio, systemAudio != Self.effectiveStatus { systemAudio = Self.effectiveStatus }
    }

    func requestMic() async {
        await Permissions.requestMic()
        refresh()
    }

    func requestScreen() {
        Permissions.requestScreen()
        refresh()
    }

    /// Never asked: a short tap brings up the prompt. Denied, or asked and still unknown: the switch is in
    /// System Settings, under "System Audio Recording Only".
    func requestSystemAudio() async {
        guard systemAudio == .unknown, !systemAudioAsked else {
            Permissions.openPane("Privacy_ScreenCapture")
            return
        }
        checkingSystemAudio = true
        systemAudio = await SystemAudioPermission.request()
        checkingSystemAudio = false
        systemAudioAsked = true
    }
}

/// What the setup assistant and Settings say about system audio recording.
@MainActor
enum SystemAudioCopy {
    static func detail(_ p: RecordingPermissions) -> String {
        switch p.systemAudio {
        case .denied:
            return L("Включи Sozvon в разделе «Только запись системного аудио»")
        case .unknown where p.systemAudioAsked:
            return L("Проверь в Системных настройках, раздел «Только запись системного аудио»")
        default:
            return L("Звук собеседников из любого приложения, FaceTime тоже")
        }
    }

    /// The button next to a status that isn't "Allowed".
    static func button(_ p: RecordingPermissions) -> String {
        p.systemAudio == .denied || p.systemAudioAsked ? L("Открыть настройки") : L("Разрешить")
    }
}
