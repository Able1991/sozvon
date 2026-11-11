// The Calls window model: the call list, selection, undo, plus its transcript edits and import extensions.

import AppKit
import AVFoundation
import SozvonCore
import SwiftUI
import UniformTypeIdentifiers

/// Call list for the window. Reloaded on calls folder events (DirectoryWatcher)
/// and when a transcription starts or finishes.
@MainActor
final class CallsModel: ObservableObject {
    @Published var calls: [Call] = []
    /// Grows on every ⌘F on the Transcript tab: the card opens its find bar.
    @Published var transcriptFindRequest = 0
    /// Set from outside too (Show in Calls, undo, import): a call hidden by the project filter brings back all projects.
    @Published var selection: Call.ID? { didSet { if selection != oldValue { revealSelection() } } }
    @Published var search = "" { didSet { if search != oldValue { scheduleTextSearch() } } }
    /// The filter's choice for reflections instead of a project: a tag no project slug can have.
    static let reflectionsFilter = CallFilter.reflections
    /// The sidebar's project filter: a project slug, or empty for all projects. Kept across launches.
    @Published var projectFilter = UserDefaults.standard.string(forKey: DefaultsKey.callsProject) ?? "" {
        didSet {
            guard projectFilter != oldValue else { return }
            UserDefaults.standard.set(projectFilter, forKey: DefaultsKey.callsProject)
            // The selected call is filtered out: select the first one the list shows.
            if let c = selected, !isShown(c) { selection = firstListed?.id }
        }
    }
    /// Projects for the filter, as of the last reload.
    @Published private(set) var projects: [Project] = []
    /// The project filter's choices: this Mac's projects, then projects of calls from another Mac (projects
    /// are per Mac; such a call keeps the title the server sent).
    @Published private(set) var filterProjects: [Project] = []
    /// Calls whose summary or transcript contains `textQuery` (searched in the background with a 250 ms debounce).
    @Published private(set) var textMatches: Set<Call.ID> = []
    private var textQuery = ""
    private var searchTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?
    /// Folders currently being transcribed.
    @Published var processing: Set<String> = []
    /// Folders waiting for their turn in the transcription queue.
    @Published var queued: Set<String> = []
    /// Folder of the recording in progress: can't be deleted or transcribed until capture is finalized.
    @Published var recordingDir: URL?
    /// A recording being imported (its folder exists, its system.m4a doesn't yet).
    @Published var importing: ImportProgress?
    var onRetranscribe: (Call) -> Void = { _ in }
    /// "Remove from Queue": a waiting call goes back to how it was.
    var onRemoveFromQueue: (Call) -> Void = { _ in }
    /// "Update Summary": a new summary from the edited transcript.
    var onResummarize: (Call) -> Void = { _ in }
    /// Folders whose summary is being made again.
    @Published var summarizing: Set<String> = []
    func isSummarizing(_ url: URL) -> Bool { summarizing.contains(url.standardizedFileURL.path) }
    /// An imported recording is ready: ask what the call was about, then transcribe.
    var onImported: (URL) -> Void = { _ in }
    private var watcher: DirectoryWatcher?

    func isProcessing(_ url: URL) -> Bool { processing.contains(url.standardizedFileURL.path) }
    func isQueued(_ url: URL) -> Bool { queued.contains(url.standardizedFileURL.path) }
    func isRecording(_ url: URL) -> Bool { recordingDir?.standardizedFileURL.path == url.standardizedFileURL.path }
    func isImporting(_ url: URL) -> Bool { importing?.dir.standardizedFileURL.path == url.standardizedFileURL.path }
    /// Being transcribed, waiting for it, recorded or imported: can't be deleted, transcribed or edited.
    func isBusy(_ url: URL) -> Bool { isProcessing(url) || isQueued(url) || isRecording(url) || isImporting(url) }
    /// The transcript can't be edited: busy here, or call.json says `processing` (an engine run Sozvon didn't
    /// start, `process_call.py` by hand, or one left over from a crash): the engine would overwrite the edit.
    func isEditLocked(_ url: URL) -> Bool {
        if isBusy(url) { return true }
        let path = url.standardizedFileURL.path
        return calls.first { $0.url.standardizedFileURL.path == path }?.status == .processing
    }

    /// The list reloads immediately (call.json only); folder sizes and full-text search run in the background.
    func reload() {
        let sel = selection
        let selectedID = selected?.callID
        let all = Project.all()
        if all.map(\.slug) != projects.map(\.slug) || all.map(\.title) != projects.map(\.title) { projects = all }
        let projects = Project.titles(all)
        let sizes = Dictionary(calls.map { ($0.id, $0.bytes) }, uniquingKeysWith: { a, _ in a })
        calls = Call.all(projects: projects, defaults: CallInfo(languages: Settings.shared.languages)).map {
            var c = $0
            c.bytes = sizes[c.id] ?? 0  // keep the old size while the new one is computed, so the row doesn't flicker
            return c
        }
        let local = Set(all.map(\.slug))
        var remote: [String: String] = [:]
        for c in calls where !c.info.profile.isEmpty && !local.contains(c.info.profile) { remote[c.info.profile] = c.project }
        let choices = all + remote.map { Project(slug: $0.key, title: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if choices.map(\.slug) != filterProjects.map(\.slug) || choices.map(\.title) != filterProjects.map(\.title) {
            filterProjects = choices
        }
        // The filtered project is gone: show every call rather than an empty list.
        if !projectFilter.isEmpty, projectFilter != Self.reflectionsFilter, !choices.contains(where: { $0.slug == projectFilter }) {
            projectFilter = ""
        }
        if let sel, !calls.contains(where: { $0.id == sel }) {
            // The folder was renamed (after transcription, or in Finder): keep the same call by its permanent id.
            selection = (calls.first { $0.callID == selectedID } ?? firstListed ?? calls.first)?.id
        }
        revealSelection()
        updateSizes()
        CallTextCache.shared.retain(Set(calls.flatMap { [$0.summaryURL.path, $0.transcriptURL.path] }))
        if !textQuery.isEmpty { scheduleTextSearch(delay: false) }
    }

    private func updateSizes() {
        sizeTask?.cancel()
        let dirs = calls.map(\.url)
        sizeTask = Task { [weak self] in
            let sizes = await Task.detached(priority: .utility) {
                Dictionary(dirs.map { ($0.path, FolderSizeCache.shared.size($0)) }, uniquingKeysWith: { a, _ in a })
            }.value
            guard let self, !Task.isCancelled else { return }
            for i in self.calls.indices {
                if let b = sizes[self.calls[i].id], self.calls[i].bytes != b { self.calls[i].bytes = b }
            }
        }
    }

    private static func normalize(_ q: String) -> String { q.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Search across summaries and transcripts: after a typing pause, in the background, texts cached by (path, mtime).
    private func scheduleTextSearch(delay: Bool = true) {
        searchTask?.cancel()
        let q = Self.normalize(search)
        guard !q.isEmpty else {
            textQuery = ""
            textMatches = []
            return
        }
        let files = calls.map { (id: $0.id, urls: [$0.summaryURL, $0.transcriptURL]) }
        searchTask = Task { [weak self] in
            if delay { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                CallTextCache.shared.matching(q, in: files)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.textQuery = q
            self.textMatches = found
        }
    }

    /// Watch the calls folder while the window is open.
    func startWatching() {
        reload()
        if watcher == nil { watcher = DirectoryWatcher(Paths.calls) { [weak self] in self?.reload() } }
        watcher?.start()
    }

    func stopWatching() { watcher?.stop() }

    /// The calls folder changed (Settings): watch the new one, if the window watches at all, and list its calls.
    func followCallsFolder() {
        let wasWatching = watcher != nil
        watcher?.stop()
        watcher = nil
        if wasWatching { startWatching() } else { reload() }
    }

    /// In the filtered project, or the live call (shown under "Now" whatever the filter).
    private func isShown(_ c: Call) -> Bool {
        CallFilter.isShown(c, filter: projectFilter, isLive: isRecording(c.url))
    }

    /// The selected call is outside the project filter: show all projects so it is visible.
    private func revealSelection() {
        if let c = selected, !isShown(c) { projectFilter = "" }
    }

    /// The calls of the filtered project (all calls without a filter).
    var inProject: [Call] {
        CallFilter.apply(calls, filter: projectFilter)
    }

    /// "November 5, 2026": day groups and search by date.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    var filtered: [Call] {
        let q = Self.normalize(search)
        let calls = inProject
        guard !q.isEmpty else { return calls }
        let text = textQuery == q ? textMatches : []
        return calls.filter { c in
            if text.contains(c.id) { return true }
            // Metadata: topic, project, people, keywords, languages, date, folder name.
            var meta = [c.title, c.project, c.people, c.info.terms, c.url.lastPathComponent,
                        c.languages.map(\.title).joined(separator: " ")]
            if let d = c.date { meta.append(Self.dayFormatter.string(from: d)) }
            return meta.contains(where: { $0.lowercased().contains(q) })
        }
    }

    /// The call being recorded: the sidebar keeps it on top under "Now", whatever the filter or search.
    var live: Call? {
        guard recordingDir != nil else { return nil }
        return calls.first { isRecording($0.url) }
    }

    /// The first call the list shows that has something to open (the live call has nothing yet).
    var firstListed: Call? { groups.first?.1.first }

    /// Groups by day: "Today", "Yesterday", date. Without the call being recorded (it is under "Now").
    var groups: [(String, [Call])] {
        let labels = CallDays.Labels(today: L("Сегодня"), yesterday: L("Вчера"), undated: L("Без даты")) {
            Self.dayFormatter.string(from: $0)
        }
        return CallDays.group(filtered.filter { !isRecording($0.url) }, now: Date(), calendar: .current, labels: labels)
    }

    var selected: Call? { calls.first { $0.id == selection } }

    /// A note typed in the Calls window. -> an error to show, nil when added.
    func addNote(_ text: String, to c: Call) -> String? {
        do {
            try CallNotes.add(text, to: c.url)
        } catch CallNotes.Failure.empty {
            return nil
        } catch CallNotes.Failure.tooLong {
            return L("Заметка длиннее %@ символов", CallNotes.maxText)
        } catch CallNotes.Failure.tooMany {
            return L("У звонка уже %@ заметок, больше нельзя", CallNotes.maxNotes)
        } catch {
            return L("Не получилось сохранить заметку: call.json повреждён")
        }
        reload()
        ServerSync.shared.sync()
        return nil
    }

    /// Delete a note; ⌘Z puts it back (as a new note with the same text, time and source: the deleted id stays a
    /// tombstone for the own server).
    func deleteNote(_ n: CallNote, of c: Call, undo: UndoManager? = nil) {
        guard (try? CallNotes.delete(n.id, in: c.url)) == true else { NSSound.beep(); return }
        reload()
        ServerSync.shared.sync()
        undo?.registerUndo(withTarget: self) { m in
            MainActor.assumeIsolated {
                guard let back = try? CallNotes.add(n.text, to: c.url, source: n.source.isEmpty ? "app" : n.source,
                                                    now: n.date ?? Date()) else { NSSound.beep(); return }
                m.reload()
                ServerSync.shared.sync()
                undo?.registerUndo(withTarget: m) { m in MainActor.assumeIsolated { m.deleteNote(back, of: c, undo: undo) } }
                undo?.setActionName(L("Удаление заметки"))
            }
        }
        undo?.setActionName(L("Удаление заметки"))
    }

    /// Like Finder: no confirmation, with the trash sound; ⌘Z puts the call back.
    func trash(_ c: Call, undo: UndoManager? = nil) {
        guard !isBusy(c.url) else { NSSound.beep(); return }  // don't delete what is being recorded or transcribed
        // Select the neighboring call in the list next, like Mail (not the live call: nothing to show yet).
        let list = groups.flatMap(\.1)
        if let i = list.firstIndex(where: { $0.id == c.id }) {
            selection = (i + 1 < list.count ? list[i + 1] : (i > 0 ? list[i - 1] : nil))?.id
        }
        let before = selection
        Task { @MainActor in
            let moved: [URL: URL]
            do { moved = try await NSWorkspace.shared.recycle([c.url]) } catch {
                if selection == before || selection == nil { selection = c.id }  // still there: back to it
                Self.alert(L("Не получилось удалить звонок"), error.localizedDescription)
                return
            }
            Sounds.trash()
            // Own server: delete it there on the next sync. Only calls deleted here are ever deleted there.
            if Settings.shared.hasServer && !c.isDemo {  // a demo call was never on the server
                do { try ServerTombstones.add(c.callID) } catch {
                    Self.alert(L("Звонок в Корзине, но на сервере он останется"), error.localizedDescription)
                }
            }
            if let trashed = moved[c.url] {
                undo?.registerUndo(withTarget: self) { m in
                    MainActor.assumeIsolated { m.restore(trashed, to: c.url, undo: undo) }
                }
                undo?.setActionName(L("Удаление звонка"))
            }
            ServerSync.shared.sync()  // own server, if set up: the call disappears there too
            reload()
        }
    }

    static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    func restore(_ trashed: URL, to original: URL, undo: UndoManager?) {
        guard (try? FileManager.default.moveItem(at: trashed, to: original)) != nil else { NSSound.beep(); return }
        // Back from the Trash: keep it on the server, or bring it back there if sync already deleted it.
        let id = CallFile.callID(original)
        do {
            if DemoCalls.isDemo(CallFile.read(original)) {
                // never on the server
            } else if Settings.shared.hasServer { try ServerTombstones.restored(id) } else { try ServerTombstones.remove(id) }
        } catch {
            Self.alert(L("Звонок вернулся, но сервер может удалить его копию"), error.localizedDescription)
        }
        ServerSync.shared.sync()
        reload()
        selection = original.path
        if let c = calls.first(where: { $0.url == original }) {
            undo?.registerUndo(withTarget: self) { m in MainActor.assumeIsolated { m.trash(c, undo: undo) } }
        }
    }
}

// MARK: - Transcript edits

extension CallsModel {
    private static let lockedMessage = L("Звонок сейчас записывается или расшифровывается")

    /// Rename a speaker in this call's transcript.md/.txt (and a typed name in call.json names). -> an error to show,
    /// nil when done.
    func renameSpeaker(_ c: Call, from old: String, to new: String) -> String? {
        guard !isEditLocked(c.url) else { return Self.lockedMessage }
        do {
            try TranscriptEdit.renameSpeaker(in: c.url, from: old, to: new)
        } catch TranscriptEditError.badName {
            return L("Имя не может быть пустым или содержать «:», «*», «[» и «]»")
        } catch TranscriptEditError.notFound {
            return L("Говорящий «%@» не найден в расшифровке", old)
        } catch {
            return L("Не получилось сохранить расшифровку: %@", error.localizedDescription)
        }
        edited(c)
        return nil
    }

    /// Swap two speakers (both mixed up). -> an error to show, nil when done.
    func swapSpeakers(_ c: Call, _ a: String, _ b: String) -> String? {
        guard !isEditLocked(c.url) else { return Self.lockedMessage }
        do {
            try TranscriptEdit.swapSpeakers(in: c.url, a, b)
        } catch {
            return L("Не получилось поменять местами: %@", error.localizedDescription)
        }
        edited(c)
        return nil
    }

    /// Give one line to another speaker. -> an error to show, nil when done.
    func reassignLine(_ c: Call, target: FixTarget, to name: String) -> String? {
        guard !isEditLocked(c.url) else { return Self.lockedMessage }
        do {
            try TranscriptEdit.reassignLine(in: c.url, line: target.line, occurrence: target.occurrence, to: name)
        } catch {
            return L("Не получилось изменить реплику: %@", error.localizedDescription)
        }
        edited(c)
        return nil
    }

    /// Fix a word in one line. -> an error to show, nil when done.
    func fixWord(_ c: Call, target: FixTarget, wrong: String, right: String) -> String? {
        guard !isEditLocked(c.url) else { return Self.lockedMessage }
        do {
            try TranscriptEdit.fixWord(in: c.url, line: target.line, occurrence: target.occurrence, wrong: wrong, right: right)
        } catch TranscriptEditError.notFound {
            return L("Расшифровка изменилась, открой звонок заново")
        } catch {
            return L("Не получилось сохранить расшифровку: %@", error.localizedDescription)
        }
        edited(c)
        return nil
    }

    /// The project the call belongs to, if its file exists (otherwise the shared vocabulary learns the fix).
    func project(of c: Call) -> Project? {
        let slug = c.info.profile
        guard !slug.isEmpty else { return nil }
        return projects.first { $0.slug == slug }
    }

    /// Remember the fix as an auto-replacement for the call's project (or the shared vocabulary).
    func remember(wrong: String, right: String, project: Project?) -> String? {
        do {
            try ReplacementStore.add(wrong: wrong, right: right, project: project?.slug ?? "")
        } catch {
            return L("Не получилось запомнить замену: %@", error.localizedDescription)
        }
        return nil
    }

    /// The speaker was named precisely: learn the voice from this call (a single line is not enough to go on).
    /// Not while the engine may rewrite the transcript; generic labels and the user are skipped by the store.
    func enrollVoices(after action: RenameAction, speaker old: String, in c: Call) {
        guard !isEditLocked(c.url) else { return }
        switch action {
        case .rename(let n), .merge(let n): VoiceStore.shared.enroll([n], from: c)
        case .swap(let n): VoiceStore.shared.enroll([n, old], from: c)
        case .line: break
        }
    }

    /// call.json `participants` recomputed from the edited transcript (CallParticipants.update); `names` stays as typed.
    /// Only after a user edit, never on simply opening a call. Best effort and silent: a corrupt call.json stays as
    /// it is. -> whether call.json changed.
    @discardableResult
    private func saveParticipants(_ c: Call) -> Bool {
        guard !c.isLegacy, c.hasTranscript, !isEditLocked(c.url) else { return false }
        do {
            return try CallParticipants.update(in: c.url, me: Settings.shared.name)
        } catch {
            NSLog("Sozvon: participants of %@ not saved: %@", c.url.lastPathComponent, error.localizedDescription)
            return false
        }
    }

    /// The edited files have a new mtime: the list, search cache and MCP index see them; the participants follow the
    /// transcript (a new name joins, a person left without lines goes); the server gets the call again.
    private func edited(_ c: Call) {
        saveParticipants(c)
        reload()
        ServerSync.shared.sync()
    }
}

// MARK: - Import

extension CallsModel {
    /// "Import Recording…": the open panel.
    func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = L("Импортировать запись")
        panel.prompt = L("Импортировать")
        panel.allowedContentTypes = AudioImport.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// Files dropped on the list. -> whether the drop is taken (a format macOS can't read gets an explanation).
    func dropFiles(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        let unreadable = files.filter(CallImport.isUnreadable)
        guard files.contains(where: CallImport.isSupported) || !unreadable.isEmpty, importing == nil else { return false }
        importFiles(files)
        return true
    }

    /// Dropped or chosen files, one after another. Only the last imported call gets the "What was the call about?"
    /// prompt (one prompt at a time); the others wait in the list with "Transcribe…".
    func importFiles(_ urls: [URL]) {
        let files = urls.filter(CallImport.isSupported)
        let unreadable = urls.filter(CallImport.isUnreadable)
        if !unreadable.isEmpty {
            let a = NSAlert()
            a.messageText = L("Этот формат не поддерживается: сконвертируй в m4a, mp3 или wav")
            a.informativeText = unreadable.map(\.lastPathComponent).joined(separator: "\n")
            a.runModal()
        }
        guard !files.isEmpty else { if unreadable.isEmpty { NSSound.beep() }; return }
        guard importing == nil else { NSSound.beep(); return }
        Task { @MainActor in
            var last: URL?
            for f in files {
                do {
                    let dir = try await importRecording(f)
                    selection = dir.path
                    last = dir
                } catch {
                    importFailed(f, error)
                }
            }
            if let last { onImported(last) }
        }
    }

    /// A recording becomes a call. -> its folder; a failure leaves nothing behind.
    func importRecording(_ src: URL) async throws -> URL {
        let recorded = await AudioImport.recordedDate(src)
        let date = CallImport.date(of: src, recorded: recorded)
        let dir = try CallImport.createFolder(for: src, recorded: recorded)
        importing = ImportProgress(name: src.lastPathComponent, fraction: 0, dir: dir)
        defer { importing = nil }
        reload()
        do {
            let seconds = try await AudioImport.convert(src, to: dir.appendingPathComponent("system.m4a")) { [weak self] p in
                self?.importing?.fraction = p
            }
            guard CallImport.finish(dir, recordedAt: date, seconds: seconds) else { throw AudioImport.Failure.failed("call.json") }
        } catch {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("system.m4a"))
            CallFolder.discardIfUnused(dir)
            reload()
            throw error
        }
        reload()
        return dir
    }

    private func importFailed(_ src: URL, _ error: Error) {
        let a = NSAlert()
        a.messageText = L("Не получилось импортировать «%@»", src.lastPathComponent)
        a.informativeText = error.localizedDescription
        a.runModal()
    }
}
