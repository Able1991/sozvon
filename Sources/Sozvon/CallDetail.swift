// The call card: summary, transcript, notes and actions for one call.

import AppKit
import SozvonCore
import SwiftUI

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
    @State private var findOpen = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    @State private var findFocus = 0
    /// Scrolls the transcript text: it is one text view in the card's scroll view, not rows to scroll to.
    @State private var scroller = TranscriptScroller()
    /// What the open find bar matches in this transcript.
    private func found(in doc: TranscriptDoc) -> [TranscriptFind.Match] {
        findOpen ? TranscriptFind.matches(findQuery, in: doc.lines.map(\.text)) : []
    }

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
        let matches = found(in: doc)
        let currentMatch = matches.indices.contains(findIndex) ? matches[findIndex] : nil
        Group {
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
                    content(doc, found: matches, current: currentMatch)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toolbar { toolbar }
            .safeAreaInset(edge: .top, spacing: 0) {
                if findOpen && showsTranscript {
                    TranscriptFindBar(query: $findQuery, index: findIndex, count: matches.count, focusRequest: findFocus,
                                      onStep: { d in
                                          findIndex = TranscriptFind.step(from: findIndex, by: d, count: matches.count)
                                          let i = findIndex
                                          if matches.indices.contains(i) { scroller.reveal(matches[i]) }
                                      },
                                      onClose: { findOpen = false; findQuery = "" })
                }
            }
            .onChange(of: findQuery) { _, _ in
                findIndex = 0
                if let first = found(in: doc).first {
                    // After the text view has the new highlights.
                    DispatchQueue.main.async { scroller.reveal(first) }
                }
            }
            .onChange(of: m.transcriptFindRequest) { _, _ in
                guard showsTranscript else { return }
                findOpen = true
                findFocus += 1
            }
            .onChange(of: showsTranscript) { _, on in if !on { findOpen = false; findQuery = "" } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if playable { PlayerBar(player: player, hasTranscript: call.hasTranscript) }
            }
            .onReceive(player.line.$time) { _ in
                // Keep the line being played in view, scrolling only when it changes.
                guard let i = player.line.index(in: doc.starts), i != followed, player.isPlaying else { return }
                followed = i
                scroller.reveal(line: i)
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
            // Screenshot check of the playing paragraph's highlight and scrolling to it, without sound.
            if let at = CommandLine.arguments.firstIndex(of: "--playing-at").flatMap({ i in
                i + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[i + 1]) : nil }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    player.line.time = at
                    if let i = player.line.index(in: texts.doc.starts) { scroller.reveal(line: i) }
                }
            }
            // Screenshot check of find in the transcript: --find <words>.
            if let q = CommandLine.arguments.firstIndex(of: "--find").flatMap({ i in
                i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    findOpen = true
                    findQuery = q
                }
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
        } else if m.isQueued(call.url) && call.hasTranscript {
            SZBanner(L("В очереди."), L("Начнётся, когда освободится движок и закончится звонок.")) {
                Button(L("Убрать из очереди")) { m.onRemoveFromQueue(call) }
                    .controlSize(.small)
            }
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

    @ViewBuilder private func content(_ doc: TranscriptDoc, found: [TranscriptFind.Match] = [], current: TranscriptFind.Match? = nil) -> some View {
        if showsTranscript {
            TranscriptView(doc: doc, playing: player.line, canPlay: playable, canEdit: !m.isEditLocked(call.url),
                           me: me,
                           onPlay: { player.play(from: $0.start) },
                           onRename: { renaming = $0 },
                           onRememberVoice: call.hasAudio ? { voices.enroll([$0], from: call) } : nil,
                           voiced: voiced,
                           onFix: { fixing = $0 },
                           found: found, currentFound: current, scroller: scroller)
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
            : m.isQueued(call.url) ? ("clock", L("В очереди"))
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
            if m.isQueued(call.url) { Button(L("Убрать из очереди")) { m.onRemoveFromQueue(call) } }
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
                if m.isQueued(call.url) { Button(L("Убрать из очереди")) { m.onRemoveFromQueue(call) } }
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
