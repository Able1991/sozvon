// "Keep audio" (Settings → General): finished calls older than N days lose their tracks, the transcript,
// summary and notes stay. Runs at launch, every 6 hours and when the setting changes (after a confirmation).

import AppKit
import SozvonCore

@MainActor
enum AudioCleanup {
    static var days: Int {
        get { UserDefaults.standard.integer(forKey: AudioRetention.defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: AudioRetention.defaultsKey) }
    }

    /// Busy calls (recording, queued or transcribing) are never touched.
    static var isBusy: (URL) -> Bool = { _ in false }
    /// Something was removed: the Calls window reloads.
    static var onChange: () -> Void = {}

    static func expired(days: Int) -> [URL] {
        AudioRetention.expired(in: Paths.calls, days: days).filter { !isBusy($0) }
    }

    /// Remove the expired audio. Returns the bytes freed.
    @discardableResult
    static func run() -> Int64 {
        let dirs = expired(days: days)
        guard !dirs.isEmpty else { return 0 }
        let freed = dirs.reduce(Int64(0)) { $0 + AudioRetention.removeAudio($1) }
        NSLog("Sozvon: removed audio of \(dirs.count) calls older than \(days) days, \(freed / 1_000_000) MB")
        onChange()
        return freed
    }

    /// The setting changed to `newDays`: if that removes audio right now, ask first. Returns whether to keep it.
    static func confirm(_ newDays: Int) -> Bool {
        let dirs = expired(days: newDays)
        guard !dirs.isEmpty else { return true }
        let size = dirs.reduce(Int64(0)) { total, d in
            total + AudioRetention.tracks.reduce(Int64(0)) { t, name in
                t + ((try? FileManager.default.attributesOfItem(atPath: d.appendingPathComponent(name).path)[.size]
                      as? NSNumber)?.int64Value ?? 0)
            }
        }
        let alert = NSAlert()
        alert.messageText = L("Удалить аудио %@ звонков?", dirs.count)
        alert.informativeText = L("У звонков старше %@ дн. удалится звук (%@). Расшифровки, итоги и заметки останутся, но плеер и «Расшифровать заново» для них пропадут. Вернуть звук будет нельзя.",
                                  newDays, ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        alert.addButton(withTitle: L("Удалить аудио"))
        alert.addButton(withTitle: L("Отмена"))
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
