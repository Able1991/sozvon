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
    @Published var selection: Call.ID?
    @Published var search = "" { didSet { if search != oldValue { scheduleTextSearch() } } }
    /// Calls whose summary or transcript contains `textQuery` (searched in the background with a 250 ms debounce).
    @Published private(set) var textMatches: Set<Call.ID> = []
    private var textQuery = ""
    private var searchTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?
    /// Folders currently being transcribed.
    @Published var processing: Set<String> = []
    /// Folder of the recording in progress: can't be deleted or transcribed until capture is finalized.
    @Published var recordingDir: URL?
    var onRetranscribe: (Call) -> Void = { _ in }
    private var watcher: DirectoryWatcher?

    func isProcessing(_ url: URL) -> Bool { processing.contains(url.standardizedFileURL.path) }
    func isRecording(_ url: URL) -> Bool { recordingDir?.standardizedFileURL.path == url.standardizedFileURL.path }
    /// Being transcribed or recorded: can't be deleted or transcribed.
    func isBusy(_ url: URL) -> Bool { isProcessing(url) || isRecording(url) }

    /// The list reloads immediately (call.json only); folder sizes and full-text search run in the background.
    func reload() {
        let sel = selection
        let projects = Project.titles(Project.all())
        let sizes = Dictionary(calls.map { ($0.id, $0.bytes) }, uniquingKeysWith: { a, _ in a })
        calls = Call.all(projects: projects, defaults: CallInfo(languages: Settings.shared.languages)).map {
            var c = $0
            c.bytes = sizes[c.id] ?? 0  // keep the old size while the new one is computed, so the row doesn't flicker
            return c
        }
        if let sel, !calls.contains(where: { $0.id == sel }) { selection = calls.first?.id }
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

    var filtered: [Call] {
        let q = Self.normalize(search)
        guard !q.isEmpty else { return calls }
        let df = DateFormatter()
        df.dateStyle = .long
        let text = textQuery == q ? textMatches : []
        return calls.filter { c in
            if text.contains(c.id) { return true }
            // Metadata: topic, project, people, keywords, languages, date, folder name.
            var meta = [c.title, c.project, c.people, c.info.terms, c.url.lastPathComponent,
                        c.languages.map(\.title).joined(separator: " ")]
            if let d = c.date { meta.append(df.string(from: d)) }
            return meta.contains(where: { $0.lowercased().contains(q) })
        }
    }

    /// Groups by day: "Today", "Yesterday", date.
    var groups: [(String, [Call])] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        var out: [(String, [Call])] = []
        for c in filtered {
            let key: String
            if let d = c.date {
                key = cal.isDateInToday(d) ? L("Сегодня") : cal.isDateInYesterday(d) ? L("Вчера") : f.string(from: d)
            } else {
                key = L("Без даты")
            }
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1.append(c) } else { out.append((key, [c])) }
        }
        return out
    }

    var selected: Call? { calls.first { $0.id == selection } }

    /// Like Finder: no confirmation, with the trash sound; ⌘Z puts the call back.
    func trash(_ c: Call, undo: UndoManager? = nil) {
        guard !isBusy(c.url) else { NSSound.beep(); return }  // don't delete what is being recorded or transcribed
        // Select the neighboring call next, like Mail.
        let list = filtered
        if let i = list.firstIndex(where: { $0.id == c.id }) {
            selection = (i + 1 < list.count ? list[i + 1] : (i > 0 ? list[i - 1] : nil))?.id
        }
        Task { @MainActor in
            if let moved = try? await NSWorkspace.shared.recycle([c.url]) {
                Sounds.trash()
                if let trashed = moved[c.url] {
                    undo?.registerUndo(withTarget: self) { m in
                        MainActor.assumeIsolated { m.restore(trashed, to: c.url, undo: undo) }
                    }
                    undo?.setActionName(L("Удаление звонка"))
                }
            }
            reload()
        }
    }

    func restore(_ trashed: URL, to original: URL, undo: UndoManager?) {
        guard (try? FileManager.default.moveItem(at: trashed, to: original)) != nil else { return }
        reload()
        selection = original.path
        if let c = calls.first(where: { $0.url == original }) {
            undo?.registerUndo(withTarget: self) { m in MainActor.assumeIsolated { m.trash(c, undo: undo) } }
        }
    }
}

/// Project color derived from its name: a muted system palette, used only for the dot.
func projectColor(_ name: String) -> Color {
    let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]
    let h = name.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
    return palette[abs(h) % palette.count].opacity(0.85)
}

struct CallRow: View {
    let call: Call
    let processing: Bool
    var recording = false

    /// "Project · people · duration" as one quiet line.
    private var subtitle: String {
        [call.project == call.title ? "" : call.project, shortPeople(splitList(call.people)), call.durationText]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(call.title).font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if recording {
                    Image(systemName: "record.circle").font(.caption).foregroundStyle(.red)
                        .help(L("идёт запись"))
                } else if processing {
                    ProgressView().controlSize(.mini)
                } else if !call.hasTranscript {
                    Image(systemName: "waveform.slash").font(.caption).foregroundStyle(.tertiary)
                        .help(L("без расшифровки"))
                }
                if let d = call.date {
                    Text(d, style: .time).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack(spacing: 5) {
                if !call.project.isEmpty {
                    Circle().fill(projectColor(call.project)).frame(width: 6, height: 6)
                }
                Text(subtitle.isEmpty ? " " : subtitle).lineLimit(1)
            }
            .help(call.people)
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct CallDetail: View {
    let call: Call
    @ObservedObject var m: CallsModel
    @Binding var tab: Int
    @Environment(\.undoManager) private var undo

    private func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }

    /// Summary and transcript without the title and header already shown in the card.
    private var summaryText: String { read(call.summaryURL) }
    private var transcriptBody: String {
        let t = read(call.transcriptURL)
        if let r = t.range(of: "\n---\n") { return String(t[r.upperBound...]) }
        return t.components(separatedBy: "\n").drop { !$0.hasPrefix("**[") }.joined(separator: "\n")
    }

    /// "November 4, 21:50 · 1:38:00 · 117.6 MB · Yuri"
    private var meta: String {
        var parts: [String] = []
        if let d = call.date { parts.append(d.formatted(.dateTime.day().month(.wide).hour().minute())) }
        parts += [call.durationText, call.sizeText].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(call.title).font(.title2.weight(.bold)).textSelection(.enabled)
                    HStack(spacing: 5) {
                        if !call.project.isEmpty {
                            Circle().fill(projectColor(call.project)).frame(width: 7, height: 7)
                            Text(call.project)
                            Text("·")
                        }
                        Text(meta)
                    }
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    // Participants on their own wrapping line, so all 5-6 people are visible.
                    if !call.people.isEmpty {
                        Label(call.people, systemImage: "person.2")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                if call.hasTranscript || call.hasSummary {
                    MarkdownText(text: tab == 0 && call.hasSummary ? summaryText : transcriptBody)
                } else {
                    VStack(spacing: 8) {
                        let recording = m.isRecording(call.url)
                        Image(systemName: recording ? "record.circle" : m.isProcessing(call.url) ? "hourglass" : "waveform.slash")
                            .font(.system(size: 28)).foregroundStyle(recording ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                        Text(recording ? L("Идёт запись") : m.isProcessing(call.url) ? L("Расшифровывается…") : L("Нет расшифровки"))
                            .font(.headline).foregroundStyle(.secondary)
                        if call.hasAudio && !m.isBusy(call.url) {
                            Button(L("Расшифровать…")) { m.onRetranscribe(call) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if call.hasSummary && call.hasTranscript {
                    Picker("", selection: $tab) {
                        Text(L("Саммари")).tag(0)
                        Text(L("Расшифровка")).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if call.hasTranscript {
                    Button { NSWorkspace.shared.open(call.transcriptURL) } label: { Label(L("Открыть"), systemImage: "doc.text") }
                        .help(L("Открыть расшифровку"))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(read(tab == 0 && call.hasSummary ? call.summaryURL : call.transcriptURL), forType: .string)
                    } label: { Label(L("Копировать"), systemImage: "doc.on.doc") }
                        .help(L("Копировать"))
                }
                Menu {
                    if call.hasAudio && !m.isBusy(call.url) {
                        Button(call.hasTranscript ? L("Расшифровать заново…") : L("Расшифровать…")) { m.onRetranscribe(call) }
                    }
                    Button(L("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([call.url]) }
                    if FileManager.default.fileExists(atPath: call.logURL.path) {
                        Button(L("Журнал обработки")) { NSWorkspace.shared.open(call.logURL) }
                    }
                    Divider()
                    Button(L("Удалить в корзину")) { m.trash(call, undo: undo) }
                        .keyboardShortcut(.delete, modifiers: .command)
                        .disabled(m.isBusy(call.url))
                } label: { Label(L("Ещё"), systemImage: "ellipsis.circle") }
            }
        }
    }
}

/// Line-by-line Markdown: headings, lists, checklists, bold text.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    EmptyView()
                } else if line.hasPrefix("## ") || line.hasPrefix("# ") {
                    Text(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                        .font(.headline).padding(.top, 6)
                } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
                    Label { inline(String(line.dropFirst(6))) } icon: {
                        Image(systemName: line.hasPrefix("- [x]") ? "checkmark.square" : "square").foregroundStyle(.secondary)
                    }
                } else if line.hasPrefix("- ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(String(line.dropFirst(2)))
                    }
                } else if line == "---" {
                    Divider()
                } else {
                    inline(line)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s) { return Text(a) }
        return Text(s)
    }
}

struct CallsView: View {
    @ObservedObject var m: CallsModel
    @State private var tab = 0
    @Environment(\.undoManager) private var undo

    var body: some View {
        NavigationSplitView {
            List(selection: $m.selection) {
                ForEach(m.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { c in
                            CallRow(call: c, processing: m.isProcessing(c.url), recording: m.isRecording(c.url)).tag(c.id)
                                .contextMenu {
                                    if c.hasTranscript { Button(L("Открыть расшифровку")) { NSWorkspace.shared.open(c.transcriptURL) } }
                                    Button(L("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([c.url]) }
                                    if c.hasAudio && !m.isBusy(c.url) { Button(L("Расшифровать заново…")) { m.onRetranscribe(c) } }
                                    Divider()
                                    Button(L("Удалить в корзину")) { m.trash(c, undo: undo) }
                                        .disabled(m.isBusy(c.url))
                                }
                        }
                    }
                }
            }
            .onDeleteCommand { if let c = m.selected { m.trash(c, undo: undo) } }
            .searchable(text: $m.search, placement: .sidebar, prompt: Text(L("Поиск по звонкам")))
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            .overlay {
                if m.calls.isEmpty {
                    ContentUnavailableView(L("Звонков пока нет"), systemImage: "waveform",
                                           description: Text(L("Нажми «Записать» на панели или в меню Sozvon.")))
                }
            }
        } detail: {
            if let c = m.selected {
                CallDetail(call: c, m: m, tab: $tab).id(c.id)
                    .onAppear { tab = c.hasSummary ? 0 : 1 }
            } else {
                ContentUnavailableView(L("Выбери звонок"), systemImage: "list.bullet.rectangle")
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { if m.selection == nil { m.selection = m.calls.first?.id } }
    }
}
