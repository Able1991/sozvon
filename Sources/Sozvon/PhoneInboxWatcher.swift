// Recordings from the phone: every half a minute, one new audio file of the chosen folder becomes a call and goes
// to transcription with no questions; the file moves to a subfolder. Rules in SozvonCore (PhoneInbox).

import AppKit
import SozvonCore

@MainActor
final class PhoneInboxWatcher {
    var calls: CallsModel?
    /// Recording, or no engine, or setup not finished: wait.
    var isBusy: () -> Bool = { true }
    var onImported: (URL, CallInfo) -> Void = { _, _ in }
    private var timer: Timer?
    private var working = false
    /// Files that could not leave the folder (it is read-only): reported once, not tried again until the next launch.
    private var stuck: Set<String> = []

    func start() {
        guard timer == nil else { return }
        timer = Timer.repeatingOnMain(every: 30) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard !working, !isBusy(), let dir = PhoneInbox.folder, let calls, calls.importing == nil else { return }
        let scan = PhoneInbox.scan(dir)
        for p in scan.notDownloaded {
            if let real = PhoneInbox.realFile(ofPlaceholder: p) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: real)
            }
        }
        guard let file = scan.ready.first(where: { !stuck.contains($0.path) }) else { return }
        // Moved before the import: a file that cannot leave the folder would be imported again on every tick.
        let claimed: URL
        do {
            claimed = try PhoneInbox.moveAside(file, to: PhoneInbox.doneFolder)
        } catch {
            stuck.insert(file.path)
            notify(L("Не получилось перенести «%@» в папку Imported", file.lastPathComponent),
                   L("Запись не импортирована: разреши запись в эту папку."))
            return
        }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                let call = try await calls.importRecording(claimed)
                let s = Settings.shared
                var info = CallInfo(topic: PhoneInbox.topic(of: file), summary: s.assistant != .none, languages: s.languages)
                info.reflection = true  // a voice memo: one person thinking out loud
                onImported(call, info)
            } catch {
                _ = try? PhoneInbox.moveAside(claimed, to: PhoneInbox.failedFolder, in: dir)
                notify(L("Не получилось импортировать «%@»", file.lastPathComponent), error.localizedDescription)
            }
        }
    }
}
