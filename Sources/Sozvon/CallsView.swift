// "Calls" window: recordings grouped by day (like Voice Memos) and a call card
// with the summary, transcript and actions.

import AppKit
import SozvonCore
import SwiftUI

/// Call list for the window. Reloaded on calls folder events (DirectoryWatcher)
/// and when a transcription starts or finishes.
@MainActor
final class CallsModel: ObservableObject {
    @Published var calls: [Call] = []
    /// Set from outside too (Show in Calls, undo, import): a call hidden by the project filter brings back all projects.
    @Published var selection: Call.ID? { didSet { if selection != oldValue { revealSelection() } } }
    @Published var search = "" { didSet { if search != oldValue { scheduleTextSearch() } } }
    /// The sidebar's project filter: a project slug, or empty for all projects. Kept across launches.
    @Published var projectFilter = UserDefaults.standard.string(forKey: "callsProject") ?? "" {
        didSet {
            guard projectFilter != oldValue else { return }
            UserDefaults.standard.set(projectFilter, forKey: "callsProject")
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
    /// Folder of the recording in progress: can't be deleted or transcribed until capture is finalized.
    @Published var recordingDir: URL?
    /// A recording being imported (its folder exists, its system.m4a doesn't yet).
    @Published var importing: ImportProgress?
    var onRetranscribe: (Call) -> Void = { _ in }
    /// "Update Summary": a new summary from the edited transcript.
    var onResummarize: (Call) -> Void = { _ in }
    /// Folders whose summary is being made again.
    @Published var summarizing: Set<String> = []
    func isSummarizing(_ url: URL) -> Bool { summarizing.contains(url.standardizedFileURL.path) }
    /// An imported recording is ready: ask what the call was about, then transcribe.
    var onImported: (URL) -> Void = { _ in }
    private var watcher: DirectoryWatcher?

    func isProcessing(_ url: URL) -> Bool { processing.contains(url.standardizedFileURL.path) }
    func isRecording(_ url: URL) -> Bool { recordingDir?.standardizedFileURL.path == url.standardizedFileURL.path }
    func isImporting(_ url: URL) -> Bool { importing?.dir.standardizedFileURL.path == url.standardizedFileURL.path }
    /// Being transcribed, recorded or imported: can't be deleted, transcribed or edited.
    func isBusy(_ url: URL) -> Bool { isProcessing(url) || isRecording(url) || isImporting(url) }
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
        if !projectFilter.isEmpty, !choices.contains(where: { $0.slug == projectFilter }) { projectFilter = "" }
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

    /// In the filtered project, or the live call (shown under "Now" whatever the filter).
    private func isShown(_ c: Call) -> Bool {
        projectFilter.isEmpty || c.info.profile == projectFilter || isRecording(c.url)
    }

    /// The selected call is outside the project filter: show all projects so it is visible.
    private func revealSelection() {
        if let c = selected, !isShown(c) { projectFilter = "" }
    }

    /// The calls of the filtered project (all calls without a filter).
    var inProject: [Call] {
        projectFilter.isEmpty ? calls : calls.filter { $0.info.profile == projectFilter }
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
        let cal = Calendar.current
        var out: [(String, [Call])] = []
        for c in filtered where !isRecording(c.url) {
            let key: String
            if let d = c.date {
                key = cal.isDateInToday(d) ? L("Сегодня") : cal.isDateInYesterday(d) ? L("Вчера") : Self.dayFormatter.string(from: d)
            } else {
                key = L("Без даты")
            }
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1.append(c) } else { out.append((key, [c])) }
        }
        return out
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
            if Settings.shared.hasServer {
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
            if Settings.shared.hasServer { try ServerTombstones.restored(id) } else { try ServerTombstones.remove(id) }
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

/// A sidebar row: bold title and start time, then a quiet line: the project and duration, or the
/// call's state (recording, transcribing, waiting for a description, not transcribed).
struct CallRow: View {
    let call: Call
    var processing = false
    var recording = false
    var importing = false
    /// The List draws the selected row on an accent background: state colors turn white on it.
    @Environment(\.backgroundProminence) private var prominence
    private var selected: Bool { prominence == .increased }

    /// Duration for the row: "<1 min", "14 min", "1 h 05 min"; empty for zero.
    static func minutes(_ seconds: TimeInterval) -> String {
        let t = Int(seconds.rounded())
        guard t > 0 else { return "" }
        if t < 60 { return L("<1 мин") }
        let m = t / 60
        if m < 60 { return L("%@ мин", m) }
        return L("%@ ч %@ мин", m / 60, String(format: "%02d", m % 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(call.title).szFont(.bodySemibold).lineLimit(1)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let d = call.date {
                    Text(d, format: .dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            subtitle
                .szFont(.small).lineLimit(1)
                .foregroundStyle(.secondary)
                .help(call.people)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var duration: String { Self.minutes(call.duration) }

    /// "Project · 22 min" with its dot, or the call's state first.
    @ViewBuilder private var subtitle: some View {
        HStack(spacing: 5) {
            if recording {
                Circle().fill(SZ.red).frame(width: 7, height: 7)
                    .shadow(color: SZ.red, radius: 3)
                    .padding(.trailing, 3)
                Text(L("Идёт запись")).fontWeight(.medium).foregroundStyle(selected ? Color.white : SZ.red)
            } else if importing {
                Text(L("Импортируется…"))
            } else if processing {
                ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 12, height: 12)
                Text(L("Расшифровывается…"))
                dotted(duration)
            } else if call.infoPending {
                SZBadge(L("Ждёт описания"))
                    .help(L("Нажми «Расшифровать…», чтобы описать звонок"))
                dotted(duration)
            } else if call.status == .failed && !call.hasTranscript {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                    .foregroundStyle(selected ? Color.white : SZ.orange)
                Text(L("Не получилось расшифровать"))
                dotted(duration)
            } else if !call.hasTranscript && !call.hasSummary {
                Image(systemName: "waveform.slash").font(.system(size: 9))
                    .foregroundStyle(selected ? Color.white : SZ.label3)
                Text(L("Без расшифровки"))
                dotted(duration)
            } else {
                let lead = call.project.isEmpty || call.project == call.title
                    ? shortPeople(splitList(call.people)) : call.project
                if !call.project.isEmpty {
                    SZWDot.view(selected ? .white : SZW.projectColor(call.project), size: 6)
                }
                if !lead.isEmpty { Text(lead) }
                if lead.isEmpty { Text(duration.isEmpty ? " " : duration) } else { dotted(duration) }
            }
        }
    }

    @ViewBuilder private func dotted(_ s: String) -> some View {
        if !s.isEmpty {
            Text(verbatim: "·")
            Text(s)
        }
    }
}

/// What the call card shows from its files, read once per file version (CallDetail caches it).
struct CardTexts: Sendable {
    /// Which file versions these are: the folder and the mtimes of summary.md and transcript.md.
    struct Key: Hashable, Sendable {
        let dir: String
        let summary: Date?
        let transcript: Date?
    }

    var summary = ""
    /// The transcript without the title and header the card already shows.
    var doc = TranscriptDoc.empty
    var actionItems: [ActionItem] = []

    static func mtime(_ u: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
    }

    /// A text file's contents, or "" when it is missing or unreadable.
    static func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }

    static func key(_ c: Call) -> Key {
        Key(dir: c.url.path, summary: mtime(c.summaryURL), transcript: mtime(c.transcriptURL))
    }

    /// Reads and parses the files: off the main thread (a long call's transcript is megabytes).
    static func load(summary: URL, transcript: URL) -> CardTexts {
        var t = CardTexts()
        t.summary = read(summary)
        let raw = read(transcript)
        let body = raw.range(of: "\n---\n").map { String(raw[$0.upperBound...]) }
            ?? raw.components(separatedBy: "\n").drop { !$0.hasPrefix("**[") }.joined(separator: "\n")
        t.doc = TranscriptDoc(body)
        t.actionItems = ActionItems.parse(t.summary)
        return t
    }
}

struct CallDetail: View {
    let call: Call
    @ObservedObject var m: CallsModel
    @Binding var tab: Int
    @Environment(\.undoManager) private var undo
    /// Not observed here (it ticks four times a second): only the player bar and the transcript rows watch it.
    @State private var player: CallPlayer
    @State private var renaming: FixTarget?
    /// The paragraph the transcript last scrolled to while playing.
    @State private var followed: Int?
    @ObservedObject private var voices = VoiceStore.shared
    /// "Not now" on the Remember voices bar, for this call while the window is open.
    @State private var voicesDismissed = false
    @State private var fixing: FixTarget?
    @State private var learn: (wrong: String, right: String, project: Project?)?
    /// Offered once the fix sheet is gone: an alert can't open while a sheet is closing.
    @State private var pendingLearn: (wrong: String, right: String, project: Project?)?
    @State private var problem: String?
    @State private var reminders = false
    /// The files as last read: body evaluations (a keystroke in search, a reload) don't read or parse them again.
    @State private var texts = CardTexts()

    init(call: Call, m: CallsModel, tab: Binding<Int>) {
        self.call = call
        self.m = m
        _tab = tab
        _player = State(initialValue: CallPlayer(dir: call.url))
    }

    private var showsTranscript: Bool { call.hasTranscript && !(tab == 0 && call.hasSummary) }

    /// The user's name as the transcript writes it (Settings), trimmed.
    private var me: String { Settings.shared.name.trimmingCharacters(in: .whitespaces) }

    /// Everyone on the call: the user first when they speak (or when there is no transcript yet), then call.json
    /// `participants`. A call made before that field existed gets them derived in memory from the transcript shown
    /// (never written on open).
    private var participantNames: [String] {
        let others = call.participants
            ?? CallParticipants.derived(splitList(call.info.names), speakers: texts.doc.lines.map(\.speaker), me: me)
        let speaks = !call.hasTranscript || texts.doc.lines.contains { $0.speaker.caseInsensitiveCompare(me) == .orderedSame }
        let withMe = !me.isEmpty && speaks && !others.contains { $0.caseInsensitiveCompare(me) == .orderedSame }
        return (withMe ? [me] : []) + others
    }

    /// Names with a saved voice in this call's project, lowercased: labels and voice records may differ in case.
    private var voiced: Set<String> { Set(voices.voicedNames(profile: call.info.profile).map { $0.lowercased() }) }

    /// The participants line; a green check marks those whose voice is saved (Sozvon recognizes them). Others can
    /// be remembered from their context menu once they speak in the transcript.
    private func participants(_ names: [String]) -> some View {
        let speaking = Set(texts.doc.lines.map(\.speaker))
        let voiced = self.voiced
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "person.2").font(.system(size: 11)).foregroundStyle(SZ.label2)
                .accessibilityLabel(L("Участники"))
            FlowLayout(spacing: 10) {
                ForEach(names, id: \.self) { n in
                    let isMe = !me.isEmpty && n.caseInsensitiveCompare(me) == .orderedSame
                    let saved = isMe ? voices.me != nil : voiced.contains(n.lowercased())
                    HStack(spacing: 4) {
                        Text(n)
                        if saved { SZWCheckDot(size: 11).accessibilityLabel(L("Голос сохранён")) }
                    }
                    .help(isMe ? (saved ? L("Твой голос сохранён") : L("Твой голос не записан: запиши его в Настройках"))
                          : saved ? L("Голос сохранён: Sozvon узнаёт этого человека в следующих звонках")
                          : L("Голос не сохранён"))
                    .contextMenu {
                        if !isMe, !saved, call.hasAudio, speaking.contains(n), !m.isEditLocked(call.url) {
                            Button(L("Запомнить голос «%@»", n)) { voices.enroll([n], from: call) }
                        }
                    }
                }
            }
        }
        .szFont(.caption).foregroundStyle(SZ.label2)
    }

    /// Names to offer when renaming a speaker: the other people speaking in this transcript, the user, the call's
    /// participants, then the people of its project; each once (ignoring case), without generic labels and
    /// without `speaker` itself.
    private func speakerSuggestions(except speaker: String) -> [String] {
        var seen: Set<String> = [speaker.lowercased()]
        let named = texts.doc.lines.map(\.speaker).filter { !Voices.isGenericLabel($0, me: me) }
        let people = splitList(call.people) + (m.project(of: call)?.people ?? [])
        return (named + [me] + people)
            .compactMap(Transcript.cleanSpeaker)
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(16).map { $0 }
    }

    /// transcript.txt is newer than summary.md: the transcript was edited after the summary.
    static func summaryStale(_ call: Call) -> Bool {
        guard let t = CardTexts.mtime(call.url.appendingPathComponent("transcript.txt")),
              let s = CardTexts.mtime(call.summaryURL) else { return false }
        return t.timeIntervalSince(s) > 2
    }

    /// The player: on both tabs, for calls whose audio tracks are present (a call restored from the server
    /// may come with them too), not while recording or importing. Line highlighting only shows on the transcript tab.
    private var playable: Bool { call.hasAudio && !m.isRecording(call.url) && !m.isImporting(call.url) }
    private var canShare: Bool { call.hasTranscript || canRemind }
    private var canRemind: Bool { !actionItems.isEmpty || !call.notes.isEmpty }
    private var actionItems: [ActionItem] { call.hasSummary ? texts.actionItems : [] }

    private func load() async {
        let s = call.summaryURL, t = call.transcriptURL
        let loaded = await Task.detached(priority: .userInitiated) { CardTexts.load(summary: s, transcript: t) }.value
        guard !Task.isCancelled else { return }
        texts = loaded
    }

    /// The meta line: project dot and name · "November 5 at 15:30" · "22 min". The folder size lives in the More menu.
    private var meta: some View {
        var parts: [String] = []
        if !call.project.isEmpty { parts.append(call.project) }
        if let d = call.date { parts.append(d.formatted(.dateTime.day().month(.wide).hour().minute())) }
        let duration = CallRow.minutes(call.duration)
        if !duration.isEmpty { parts.append(duration) }
        return HStack(spacing: 5) {
            if !call.project.isEmpty { SZWDot.view(SZW.projectColor(call.project), size: 7) }
            ForEach(parts.indices, id: \.self) { i in
                if i > 0 { Text(verbatim: "·") }
                Text(parts[i])
            }
        }
        .szFont(SZTextStyle(size: 12, lineHeight: 16, tabular: true)).foregroundStyle(SZ.label2).lineLimit(1)
        .help(call.durationText)
    }

    var body: some View {
        let doc = showsTranscript ? texts.doc : TranscriptDoc.empty
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(call.title).szFont(.h1Bold).foregroundStyle(SZ.label).textSelection(.enabled)
                            .accessibilityAddTraits(.isHeader)
                        meta
                        // Participants on their own wrapping line, so all 5-6 people are visible.
                        let names = participantNames
                        if !names.isEmpty { participants(names) }
                    }
                    voiceBanners
                    // Notes come first: what the user wrote down matters more than what the model made of the call.
                    if !call.isLegacy { NotesSection(call: call, m: m) }
                    statusBanner
                    content(doc)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if playable { PlayerBar(player: player, hasTranscript: call.hasTranscript) }
            }
            .onReceive(player.line.$time) { _ in
                // Keep the line being played in view, scrolling only when it changes.
                guard let i = player.line.index(in: doc.starts), i != followed, player.isPlaying, i < doc.rowIDs.count else { return }
                followed = i
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(doc.rowIDs[i]) }
            }
        }
        .task(id: CardTexts.key(call)) { await load() }
        // The player bar is on both tabs; the transcript works out its playing line from the time.
        .onAppear {
            if playable { player.prepare() }
            #if SOZVON_PREVIEW
            // Screenshot check that the highlight follows playback: play from the start right away.
            if CommandLine.arguments.contains("--autoplay") {
                let from = CommandLine.arguments.firstIndex(of: "--from").flatMap { i in
                    i + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[i + 1]) : nil } ?? 0
                player.play(from: from)
            }
            if CommandLine.arguments.contains("--rename") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if let l = texts.doc.lines.last { renaming = FixTarget(line: l) }
                }
            }
            #endif
        }
        .onChange(of: playable) { _, on in if on { player.prepare() } else { player.pause() } }
        .onDisappear { player.stop() }
        .sheet(item: $renaming) { t in
            RenameSpeakerSheet(target: t, lines: texts.doc.lines, suggestions: speakerSuggestions(except: t.line.speaker)) { action in
                switch action {
                case .rename(let n), .merge(let n): problem = m.renameSpeaker(call, from: t.line.speaker, to: n)
                case .swap(let n): problem = m.swapSpeakers(call, t.line.speaker, n)
                case .line(let n): problem = m.reassignLine(call, target: t, to: n)
                }
                if problem == nil { m.enrollVoices(after: action, speaker: t.line.speaker, in: call) }
            }
        }
        .sheet(item: $fixing, onDismiss: { learn = pendingLearn; pendingLearn = nil }) { t in
            FixWordSheet(line: t.line) { wrong, right in
                if let e = m.fixWord(call, target: t, wrong: wrong, right: right) {
                    problem = e
                } else {
                    pendingLearn = (wrong, right, m.project(of: call))
                }
            }
        }
        .alert(learn?.project.map { L("Запоминать для проекта «%@»?", $0.shortTitle) } ?? L("Запоминать для всех звонков?"),
               isPresented: Binding(get: { learn != nil }, set: { if !$0 { learn = nil } })) {
            Button(L("Запоминать")) {
                if let l = learn { problem = m.remember(wrong: l.wrong, right: l.right, project: l.project) }
            }
            Button(L("Не надо"), role: .cancel) {}
        } message: {
            if let l = learn { Text(L("В новых расшифровках «%@» будет сразу заменяться на «%@».", l.wrong, l.right)) }
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        }
        .sheet(isPresented: $reminders) {
            RemindersSheet(call: call, items: actionItems, me: me)
        }
    }

    /// "Remember voices", the voice saved notice and its progress.
    @ViewBuilder private var voiceBanners: some View {
        if let n = voices.notice {
            Label(n.text, systemImage: n.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .szFont(.caption)
                .foregroundStyle(n.ok ? SZ.green : SZ.orange)
                .transition(.opacity)
        } else if voices.isBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Запоминаю голос…")).foregroundStyle(SZ.label2)
            }
            .szFont(.caption)
        }
        if call.hasAudio && call.hasTranscript && !m.isEditLocked(call.url) && !voicesDismissed {
            let unsaved = Voices.unsaved(speakers: texts.doc.lines.map(\.speaker), profile: call.info.profile,
                                         records: voices.records, me: me)
            if !unsaved.isEmpty {
                // The transcript named people right: one click teaches Sozvon their voices for next calls.
                SZBanner(L("Подписи верные?"),
                         L("Запомни голоса (%@), и в следующих звонках имена подставятся сами.",
                           unsaved.joined(separator: ", "))) {
                    Button(L("Не сейчас")) { voicesDismissed = true }
                        .buttonStyle(.borderless).controlSize(.small)
                    Button(L("Запомнить голоса")) { voices.enroll(unsaved, from: call) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(voices.isBusy)
                }
            }
        }
    }

    /// A progress line under the header: the call transcribed again, its summary made again.
    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(SZ.label2)
            Spacer(minLength: 0)
        }
        .szFont(.caption)
        .padding(.vertical, 10).padding(.horizontal, 14)
        .szSurface(SZ.fillb, radius: SZ.radiusBanner, shadow: .banner)
    }

    /// Transcribing again, the summary being made again, the last run failed, or the transcript edited after
    /// the summary.
    @ViewBuilder private var statusBanner: some View {
        if m.isProcessing(call.url) && call.hasTranscript {
            progress(L("Расшифровываю заново…"))
        } else if m.isSummarizing(call.url) {
            progress(L("Обновляю саммари…"))
        } else if call.status == .failed && call.hasTranscript && !m.isBusy(call.url) {
            // The last run failed; what is shown is from the run before it.
            SZBanner(L("Не получилось расшифровать."), L("Здесь расшифровка с прошлого раза.")) {
                logButton
                Button(L("Расшифровать заново…")) { m.onRetranscribe(call) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        } else if call.hasSummary && Self.summaryStale(call) && !m.isEditLocked(call.url) {
            // The transcript was edited after the summary was written (names fixed, lines moved).
            SZBanner(L("Саммари устарело."), L("Расшифровку изменили после того, как оно было написано.")) {
                Button(L("Обновить саммари")) { m.onResummarize(call) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }

    private var hasLog: Bool { FileManager.default.fileExists(atPath: call.logURL.path) }

    @ViewBuilder private var logButton: some View {
        if hasLog {
            Button(L("Журнал обработки")) { NSWorkspace.shared.open(call.logURL) }
                .buttonStyle(.borderless).controlSize(.small)
        }
    }

    @ViewBuilder private func content(_ doc: TranscriptDoc) -> some View {
        if showsTranscript {
            TranscriptView(doc: doc, playing: player.line, canPlay: playable, canEdit: !m.isEditLocked(call.url),
                           me: me,
                           onPlay: { player.play(from: $0.start) },
                           onRename: { renaming = $0 },
                           onRememberVoice: call.hasAudio ? { voices.enroll([$0], from: call) } : nil,
                           voiced: voiced,
                           onFix: { fixing = $0 })
        } else if call.hasSummary {
            SummaryCards(text: texts.summary)
        } else {
            emptyContent
        }
    }

    /// No transcript yet: being recorded, imported, transcribed, waiting for a description, failed, or never run.
    private var emptyContent: some View {
        let failed = call.status == .failed && !m.isBusy(call.url)
        let (symbol, title): (String, String) =
            m.isRecording(call.url) ? ("record.circle", L("Идёт запись"))
            : m.isImporting(call.url) ? ("square.and.arrow.down", L("Импортируется…"))
            : m.isProcessing(call.url) ? ("hourglass", L("Расшифровывается…"))
            : call.infoPending ? ("text.badge.plus", L("Ждёт описания"))
            : failed ? ("exclamationmark.triangle", L("Не получилось расшифровать"))
            : ("waveform.slash", L("Нет расшифровки"))
        return VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28)).foregroundStyle(m.isRecording(call.url) ? SZ.red : SZ.label3)
            Text(title).szFont(.h2).foregroundStyle(SZ.label2)
            if call.hasAudio && !m.isBusy(call.url) {
                HStack(spacing: 8) {
                    if failed { logButton }
                    Button(call.infoPending ? L("Описать…") : L("Расшифровать…")) { m.onRetranscribe(call) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    /// System toolbar items (Liquid Glass on macOS 26): the view switch in the middle, Share and More on the right.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if call.hasSummary && call.hasTranscript {
                Picker(L("Вид"), selection: $tab) {
                    Text(L("Саммари")).tag(0)
                    Text(L("Расшифровка")).tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(L("Саммари или расшифровка"))
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if canShare {
                Menu {
                    if call.hasTranscript {
                        let summary = tab == 0 && call.hasSummary
                        Button(summary ? L("Копировать саммари") : L("Копировать расшифровку")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(CardTexts.read(summary ? call.summaryURL : call.transcriptURL),
                                                           forType: .string)
                        }
                        Button(L("Открыть расшифровку")) { NSWorkspace.shared.open(call.transcriptURL) }
                    }
                    if canRemind {
                        Button(L("В Напоминания…")) { reminders = true }
                    }
                } label: {
                    Label(L("Поделиться"), systemImage: "square.and.arrow.up")
                }
                .help(L("Поделиться"))
            }
            Menu {
                if call.hasAudio && !m.isBusy(call.url) {
                    Button(call.infoPending ? L("Описать…")
                           : call.hasTranscript ? L("Расшифровать заново…") : L("Расшифровать…")) { m.onRetranscribe(call) }
                }
                if call.hasTranscript {
                    Button(L("Обновить саммари")) { m.onResummarize(call) }
                        .disabled(m.isEditLocked(call.url) || m.isSummarizing(call.url))
                }
                Button(L("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([call.url]) }
                if hasLog {
                    Button(L("Журнал обработки")) { NSWorkspace.shared.open(call.logURL) }
                }
                Divider()
                Button(L("Удалить в корзину")) { m.trash(call, undo: undo) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(m.isBusy(call.url))
                if !call.sizeText.isEmpty {
                    Divider()
                    Button(L("На диске: %@", call.sizeText)) {}.disabled(true)
                }
            } label: {
                Label(L("Ещё"), systemImage: "ellipsis.circle")
            }
            .help(L("Ещё"))
        }
    }
}

/// "Notes": notes from assistants (MCP) and from here, oldest first, each with a yellow dot.
/// A note can be deleted (the ⋯ menu next to it, or the context menu), not edited; the deletion reaches the own
/// server on the next sync.
/// The input appears only after "Add": Return adds, Escape cancels.
struct NotesSection: View {
    let call: Call
    @ObservedObject var m: CallsModel
    @State private var draft = ""
    @State private var error: String?
    @State private var adding = false
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.undoManager) private var undo

    var body: some View {
        SZBlock(L("Заметки"), spacing: 12) {
            if !adding {
                Button { adding = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text(L("Добавить"))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SZ.accent)
                    .padding(.horizontal, 4)
                    .frame(height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Добавить заметку"))
                .accessibilityLabel(L("Добавить заметку"))
            }
        } content: {
            ForEach(call.notes) { n in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(n.text).szFont(.bodyRelaxed).foregroundStyle(SZ.label)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text(stamp(n)).szFont(SZTextStyle(size: 11, lineHeight: 19, tabular: true)).foregroundStyle(SZ.label3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        actions(n)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SZ.label2)
                            .frame(width: 22, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L("Действия с заметкой"))
                    .accessibilityLabel(L("Действия с заметкой"))
                }
                .padding(.leading, 12)
                .overlay(alignment: .topLeading) { Circle().fill(SZ.yellow).frame(width: 5, height: 5).padding(.top, 7) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu { actions(n) }
            }
            if call.notes.isEmpty && !adding {
                Text(L("Заметок пока нет: решения, договорённости, что проверить потом."))
                    .foregroundStyle(.secondary)
            }
            if adding { field }
            if let error { Text(error).szFont(.caption).foregroundStyle(SZ.orange) }
        }
    }

    @ViewBuilder private func actions(_ n: CallNote) -> some View {
        Button(L("Копировать")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(n.text, forType: .string)
        }
        Button(L("Удалить заметку"), role: .destructive) { m.deleteNote(n, of: call, undo: undo) }
    }

    /// "November 5 at 16:02", and where the note came from when not typed here ("claude-code").
    private func stamp(_ n: CallNote) -> String {
        let when = n.date.map { $0.formatted(.dateTime.day().month(.wide).hour().minute()) } ?? n.at
        return n.source.isEmpty || n.source == "app" ? when : "\(when) · \(n.source)"
    }

    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: SZ.radiusControl)
        return TextField(L("Заметка"), text: $draft, prompt: Text(L("Заметка")).foregroundStyle(SZ.label3), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineLimit(1...6)
            .focused($focused)
            .onSubmit(add)
            .onExitCommand(perform: cancel)
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background {
                shape.fill(SZ.textBg.shadow(.inner(color: SZ.hex(scheme == .dark ? 0x00000059 : 0x0000001a), radius: 1, x: 0, y: 1)))
            }
            .overlay {
                shape.inset(by: -0.5).strokeBorder(SZ.hex(scheme == .dark ? 0xffffff1f : 0x00000026), lineWidth: 0.5)
            }
            // The field is not in the responder chain yet on its first appearance: focus on the next turn.
            .onAppear { Task { @MainActor in focused = true } }
    }

    private func add() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { cancel(); return }
        error = m.addNote(draft, to: call)
        if error == nil { draft = ""; adding = false }
    }

    private func cancel() {
        draft = ""
        error = nil
        adding = false
    }
}

/// The summary as cards, one per "## " section: paragraphs, bullet lists, action items.
struct SummaryCards: View {
    let text: String

    var body: some View {
        let blocks = SummaryBlocks.split(text)
        VStack(alignment: .leading, spacing: 24) {
            ForEach(blocks.indices, id: \.self) { i in
                SZBlock(blocks[i].title) {
                    SummaryBlockBody(lines: blocks[i].lines)
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// The lines of one summary card: consecutive bullets make one list (4 apart), other lines 10 apart.
struct SummaryBlockBody: View {
    let lines: [String]

    private enum Piece {
        case paragraph(String)
        case heading(String)
        case bullets([String])
        case task(ActionItem)
    }

    private var pieces: [Piece] {
        var out: [Piece] = []
        for line in lines {
            if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                // ActionItems reads the owner ("Sarah: send the keys") the same way Reminders does.
                if let item = ActionItems.parse("## Tasks\n" + line).first { out.append(.task(item)) }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let item = String(line.dropFirst(2))
                if case .bullets(let list)? = out.last {
                    out[out.count - 1] = .bullets(list + [item])
                } else {
                    out.append(.bullets([item]))
                }
            } else if line.hasPrefix("#") {
                out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else {
                out.append(.paragraph(line))
            }
        }
        return out
    }

    var body: some View {
        let pieces = self.pieces
        ForEach(pieces.indices, id: \.self) { i in
            switch pieces[i] {
            case .paragraph(let s):
                inline(s).szFont(.bodyRelaxed).foregroundStyle(SZ.label).fixedSize(horizontal: false, vertical: true)
            case .heading(let s):
                inline(s).szFont(.bodyRelaxed).fontWeight(.semibold).foregroundStyle(SZ.label)
            case .bullets(let items):
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items.indices, id: \.self) { j in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(verbatim: "•").foregroundStyle(SZ.label3).frame(width: 18, alignment: .center)
                            inline(items[j]).foregroundStyle(SZ.label).fixedSize(horizontal: false, vertical: true)
                        }
                        .szFont(.bodyRelaxed)
                    }
                }
            case .task(let item):
                HStack(alignment: .top, spacing: 10) {
                    SZTaskRing(done: item.done).padding(.top, 2.5)
                    inline(item.task).szFont(.bodyRelaxed)
                        .foregroundStyle(item.done ? SZ.label2 : SZ.label)
                        .strikethrough(item.done)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if !item.owner.isEmpty {
                        Text(item.owner).szFont(.bodyRelaxed).font(.system(size: 12)).foregroundStyle(SZ.label2)
                            .lineLimit(1).fixedSize()
                    }
                }
            }
        }
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s) { return Text(a) }
        return Text(s)
    }
}

struct CallsView: View {
    @ObservedObject var m: CallsModel
    /// Summary (0) or transcript (1): the user's choice, kept across selections and launches.
    @AppStorage("callsTab") private var tab = 0
    @Environment(\.undoManager) private var undo

    init(m: CallsModel) {
        _m = ObservedObject(wrappedValue: m)
        #if SOZVON_PREVIEW
        // Screenshots pick the tab explicitly, whatever was chosen last time.
        UserDefaults.standard.set(CommandLine.arguments.contains("--transcript") ? 1 : 0, forKey: "callsTab")
        #endif
    }

    /// The chosen tab, or the other one when this call doesn't have it.
    private func shownTab(for c: Call) -> Binding<Int> {
        Binding(get: {
            if tab == 0 && !c.hasSummary { return 1 }
            if tab == 1 && !c.hasTranscript { return 0 }
            return tab
        }, set: { tab = $0 })
    }

    var body: some View {
        NavigationSplitView {
            CallsSidebar(m: m)
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SZ.windowBg)
        }
        .navigationTitle(L("Звонки"))
        .frame(minWidth: 820, minHeight: 520)
        // Drop an audio or video file anywhere in the window: it becomes a new call.
        .dropDestination(for: URL.self) { urls, _ in m.dropFiles(urls) }
        .onAppear {
            // The first call that is not being recorded (it has nothing to show yet).
            if m.selection == nil { m.selection = (m.firstListed ?? m.calls.first)?.id }
        }
    }

    @ViewBuilder private var detail: some View {
        if let c = m.selected {
            CallDetail(call: c, m: m, tab: shownTab(for: c)).id(c.id)
        } else if m.calls.isEmpty {
            ContentUnavailableView {
                Label(L("Звонков пока нет"), systemImage: "waveform")
            } description: {
                Text(L("Нажми «Записать» на панели или в меню Sozvon. Готовую запись можно перетащить сюда."))
            } actions: {
                Button(L("Импортировать запись…")) { m.chooseImport() }
            }
        } else {
            ContentUnavailableView {
                Label(L("Выбери звонок"), systemImage: "list.bullet.rectangle")
            } description: {
                Text(L("Итоги, расшифровка и запись звонка откроются здесь."))
            }
        }
    }
}

/// The sidebar: search, project filter, the call being recorded under "Now", then calls by day.
struct CallsSidebar: View {
    @ObservedObject var m: CallsModel
    @Environment(\.undoManager) private var undo
    @FocusState private var searching: Bool

    var body: some View {
        list
        .searchable(text: $m.search, placement: .sidebar, prompt: L("Поиск по звонкам"))
        .searchFocused($searching)
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker(L("Проект"), selection: $m.projectFilter) {
                        Text(L("Все проекты")).tag("")
                        if !m.filterProjects.isEmpty { Divider() }
                        ForEach(m.filterProjects) { p in Text(p.shortTitle).tag(p.slug) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(L("Проект"), systemImage: m.projectFilter.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                              : "line.3.horizontal.decrease.circle.fill")
                }
                .help(L("Показать звонки одного проекта"))
            }
            ToolbarItem {
                Button { m.chooseImport() } label: {
                    Label(L("Импортировать запись…"), systemImage: "square.and.arrow.down")
                }
                .help(L("Импортировать запись…"))
                .disabled(m.importing != nil)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let p = m.importing {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Импорт «%@»", p.name)).szFont(.small).foregroundStyle(SZ.label2).lineLimit(1)
                    ProgressView(value: p.fraction).controlSize(.small).tint(SZ.accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(SZ.bar)
                .overlay(alignment: .top) { Rectangle().fill(SZ.sep).frame(height: 1) }
            }
        }
        .background {
            // ⌘F: to the search field.
            Button(L("Поиск по звонкам")) { searching = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// The system sidebar list: native selection, keyboard navigation and type-select.
    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $m.selection) {
                if let live = m.live {
                    Section(L("Сейчас")) { row(live) }
                }
                ForEach(m.groups, id: \.0) { group in
                    Section(group.0) { ForEach(group.1) { c in row(c) } }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand { if let c = m.selected { m.trash(c, undo: undo) } }
            .onChange(of: m.selection) { _, id in if let id { proxy.scrollTo(id) } }
            .overlay { empty }
            .safeAreaInset(edge: .bottom, spacing: 0) { filterBar }
        }
    }

    /// Under the list while a project filter is on (as Mail's "Filtered by"): which one, and Clear.
    @ViewBuilder private var filterBar: some View {
        if let p = m.filterProjects.first(where: { $0.slug == m.projectFilter }) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(.tint)
                Text(L("Только «%@»", p.shortTitle)).lineLimit(1)
                Spacer(minLength: 0)
                Button(L("Сбросить")) { m.projectFilter = "" }.buttonStyle(.link)
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
        }
    }

    @ViewBuilder private var empty: some View {
        if m.calls.isEmpty {
            // The detail explains how to get the first call; the sidebar only says there are none.
            Text(L("Нет звонков")).font(.title3).foregroundStyle(.tertiary)
        } else if m.filtered.isEmpty && m.live == nil {
            if m.search.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView(L("В этом проекте звонков нет"), systemImage: "tray")
            } else {
                ContentUnavailableView.search(text: m.search)
            }
        }
    }

    private func row(_ c: Call) -> some View {
        CallRow(call: c, processing: m.isProcessing(c.url), recording: m.isRecording(c.url), importing: m.isImporting(c.url))
            .tag(c.id)
            .id(c.id)
        .contextMenu {
            if c.infoPending && c.hasAudio && !m.isBusy(c.url) {
                Button(L("Описать…")) { m.onRetranscribe(c) }
            }
            if c.hasTranscript { Button(L("Открыть расшифровку")) { NSWorkspace.shared.open(c.transcriptURL) } }
            Button(L("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([c.url]) }
            if c.hasAudio && !m.isBusy(c.url) && !c.infoPending {
                Button(c.hasTranscript ? L("Расшифровать заново…") : L("Расшифровать…")) { m.onRetranscribe(c) }
            }
            Divider()
            Button(L("Удалить в корзину")) { m.trash(c, undo: undo) }
                .disabled(m.isBusy(c.url))
        }
    }

}
