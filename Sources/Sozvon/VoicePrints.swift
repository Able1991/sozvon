// Voice prints in the app: the saved records (read from `<data>/voices`), one `bin/voice.py` run at a time,
// the own sample recorded in Settings, and enrolling a speaker after the user names them in a call.

import AppKit
import AVFoundation
import SozvonCore
import SwiftUI

@MainActor
final class VoiceStore: ObservableObject {
    static let shared = VoiceStore()

    @Published private(set) var records: [VoiceRecord] = []
    /// A voice.py run is going on or waiting.
    @Published private(set) var isBusy = false
    /// What the last "remember voice" did, shown for a few seconds in the Calls window. (ok, text)
    @Published private(set) var notice: (ok: Bool, text: String)?
    private var noticeID = 0

    private func show(ok: Bool, _ text: String) {
        noticeID += 1
        let id = noticeID
        notice = (ok, text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated { if self?.noticeID == id { self?.notice = nil } }
        }
    }

    /// Names with a saved voice for this project (or without a project), for the transcript's speaker labels.
    func voicedNames(profile: String) -> Set<String> {
        Set(records.filter { !$0.me && ($0.profile == profile || $0.profile.isEmpty) }.map(\.name))
    }

    private struct Job {
        let args: [String]
        let log: URL?
        let appendLog: Bool
        let done: CheckedContinuation<RunOutcome, Never>
    }
    private var jobs: [Job] = []
    private var running = false

    init() { refresh() }

    func refresh() {
        let fresh = Voices.all()
        if fresh != records { records = fresh }
    }

    /// The user's own sample (the newest, should an old one be left over).
    var me: VoiceRecord? { records.filter(\.me).max { $0.updatedAt < $1.updatedAt } }

    func voice(named name: String, profile: String) -> VoiceRecord? {
        Voices.voice(named: name, profile: profile, in: records)
    }

    /// Run `voice.py` after the runs before it. Success refreshes the records and syncs the own server.
    func run(_ args: [String], log: URL? = Paths.data.appendingPathComponent("voice.log"),
             appendLog: Bool = false) async -> RunOutcome {
        await withCheckedContinuation { cont in
            jobs.append(Job(args: args, log: log, appendLog: appendLog, done: cont))
            isBusy = true
            next()
        }
    }

    private func next() {
        guard !running else { return }
        guard !jobs.isEmpty else { isBusy = false; return }
        let job = jobs.removeFirst()
        running = true
        let tracker = OutputTracker()
        Engine.runScript(Voices.script, job.args, log: job.log, appendLog: job.appendLog,
                         onLine: { tracker.consume($0) }) { [weak self] code in
            let outcome = RunOutcome.parse(exitCode: code, result: tracker.result, lastLine: tracker.lastLine)
            job.done.resume(returning: outcome)
            guard let self else { return }
            self.running = false
            self.refresh()
            if outcome.isOK { ServerSync.shared.sync() }
            self.next()
        }
    }

    func delete(_ record: VoiceRecord) async -> RunOutcome { await run(Voices.delete(id: record.id)) }

    func deleteAll() async -> RunOutcome { await run(Voices.deleteAll()) }

    /// Own sample: enroll it. A new recording replaces the voice print (older own records are dropped);
    /// `add` merges one more sample into it (another call language).
    func enrollMe(_ file: URL, add: Bool = false) async -> RunOutcome {
        let name = Settings.shared.name.trimmingCharacters(in: .whitespaces)
        let before = Set(records.filter(\.me).map(\.id))
        let outcome = await run(Voices.enrollFile(name: name.isEmpty ? L("Я") : name, me: true, add: add, file: file))
        guard outcome.isOK, !add, let fresh = me else { return outcome }
        for id in before where id != fresh.id {
            if let old = records.first(where: { $0.id == id }) { _ = await delete(old) }
        }
        return outcome
    }

    /// The user named a speaker precisely: learn their voice from this call (best effort, silent).
    /// Skips calls without audio and generic labels; the caller checks the edit lock.
    func enroll(_ names: [String], from call: Call) {
        guard call.hasAudio else { return }
        let log = call.url.appendingPathComponent("process.log")
        for name in Voices.namesToEnroll(names, me: Settings.shared.name) {
            let args = Voices.enrollCall(name: name, profile: call.info.profile, dir: call.url, speaker: name)
            Task {
                let outcome = await run(args, log: log, appendLog: true)
                if outcome.isOK {
                    show(ok: true, L("Голос «%@» сохранён", name))
                } else {
                    NSLog("Sozvon: voice print for %@ not saved: %@", name, outcome.message)
                    show(ok: false, L("Голос «%@» не сохранён: %@", name,
                                      outcome.message.isEmpty ? L("подробности в process.log") : outcome.message))
                }
            }
        }
    }
}

// MARK: - Own sample

/// Records the default microphone to a 16 kHz mono wav, with a level meter and a timer.
@MainActor
final class SampleRecorder: ObservableObject {
    static let maxSeconds: TimeInterval = 25
    static let minSeconds: TimeInterval = 10

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// 0...1 from the meter's average power.
    @Published private(set) var level: Double = 0

    private var recorder: AVAudioRecorder?
    private var ticker: Task<Void, Never>?
    private(set) var file: URL?

    /// Start recording. Throws when the file can't be opened or the microphone doesn't start.
    func start() throws {
        discard()
        let dir = Paths.data.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("voice-sample-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        guard r.record() else {
            try? FileManager.default.removeItem(at: url)
            throw CocoaError(.fileWriteUnknown)
        }
        recorder = r
        file = url
        elapsed = 0
        isRecording = true
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let r = self.recorder, self.isRecording else { return }
                r.updateMeters()
                let db = Double(r.averagePower(forChannel: 0))
                self.level = max(0, min(1, (db + 50) / 50))
                self.elapsed = r.currentTime
                if self.elapsed >= Self.maxSeconds { self.stop() }
            }
        }
    }

    /// Stop; the file stays for enrolling.
    func stop() {
        guard isRecording else { return }
        elapsed = recorder?.currentTime ?? elapsed
        recorder?.stop()
        recorder = nil
        ticker?.cancel()
        ticker = nil
        isRecording = false
        level = 0
    }

    /// Stop and delete the recording.
    func discard() {
        stop()
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        elapsed = 0
    }
}

/// Texts to read aloud for a voice sample, in the call's language (not the interface's: the voice print should
/// hear the language you speak on calls). Simple words on purpose. Other languages get a hint to speak freely.
@MainActor
enum SampleText {
    static func text(_ lang: SpeechLanguage) -> String? {
        switch lang {
        case .ru:
            return "Привет. Я работаю каждый день. Утром я пью кофе и читаю почту. Потом у меня созвоны с командой. Мы говорим о работе, сроках и деньгах. Днём я много пишу и читаю. Вечером я иду домой. Я люблю гулять, читать книги и смотреть фильмы. В выходные я встречаюсь с друзьями. Я люблю лето и море."  // l10n-ignore
        case .en:
            return "Hello. I work every day. In the morning I drink coffee and read my email. Then I have calls with my team. We talk about work, time and money. In the afternoon I write and read a lot. In the evening I go home. I like to walk, read books and watch films. On the weekend I meet my friends. I like summer and the sea."
        default:
            return nil
        }
    }

    /// The call languages from Settings; none picked ("Detect automatically") means Russian and English.
    static var languages: [SpeechLanguage] {
        let set = Settings.shared.languages.filter { $0 != .auto }
        return set.isEmpty ? [.ru, .en] : set
    }
}

/// "Record My Voice": read a short text aloud, then the engine makes the own voice print.
struct VoiceSampleSheet: View {
    /// One more sample merged into the voice print instead of replacing it.
    var add = false
    @Environment(\.dismiss) private var dismiss
    @State private var lang: SpeechLanguage = SampleText.languages.first ?? .ru
    @StateObject private var rec = SampleRecorder()
    @ObservedObject private var store = VoiceStore.shared
    @State private var enrolling = false
    @State private var problem: String?
    @State private var micDenied = false
    /// Recent meter levels for the wave, newest on the right.
    @State private var levels = Array(repeating: CGFloat(0), count: VoiceSampleSheet.bars)
    private static let bars = 32
    /// The pace the text is written for: about twenty seconds of reading.
    private static let readSeconds: Double = 20

    private var sample: String? { SampleText.text(lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sample == nil ? L("Расскажи что-нибудь вслух") : L("Прочитай вслух текст ниже"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if SampleText.languages.count > 1 {
                Picker(L("Язык"), selection: $lang) {
                    ForEach(SampleText.languages) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240, alignment: .leading)
                .disabled(rec.isRecording || enrolling)
                .accessibilityLabel(L("Язык"))
            }
            sampleBox
            meter
            if enrolling {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Сохраняю голос…")).foregroundStyle(.secondary)
                }
            } else if micDenied {
                HStack(spacing: 8) {
                    SettingsWarning(L("Нет доступа к микрофону")).fixedSize()
                    Button(L("Открыть настройки")) { Permissions.openPane("Privacy_Microphone") }
                        .controlSize(.small)
                }
            } else if let problem {
                SettingsWarning(problem)
            }
            HStack(spacing: 8) {
                Label(L("Образец остаётся на Mac"), systemImage: "lock")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // Not while enrolling: the engine is still reading the recording.
                Button(L("Отмена")) { rec.discard(); dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(enrolling)
                Button {
                    if rec.isRecording { rec.stop() } else { Task { await start() } }
                } label: {
                    Label(rec.isRecording ? L("Остановить") : (problem == nil ? L("Записать") : L("Записать заново")),
                          systemImage: rec.isRecording ? "stop.fill" : "record.circle")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(enrolling || (rec.isRecording && rec.elapsed < SampleRecorder.minSeconds))
            }
        }
        .padding(20)
        .frame(width: 480, alignment: .leading)
        .onChange(of: rec.level) { _, v in
            levels.removeFirst()
            levels.append(CGFloat(v))
        }
        .onChange(of: rec.isRecording) { _, now in
            guard !now else { return }
            levels = Array(repeating: 0, count: Self.bars)
            // Stop and the auto-stop at the limit both land here; a discarded recording has no file.
            finished()
        }
        .onDisappear { rec.discard() }
    }

    private var subtitle: String {
        var t = sample == nil
            ? L("Секунд двадцать на этом языке обычным голосом, как на звонке: о себе, о работе, о чём угодно.")
            : L("Секунд двадцать обычным голосом, как на звонке. Текст на языке звонков из настроек.")
        if add { t += " " + L("Образец добавится к записанному голосу, а не заменит его.") }
        return t
    }

    /// The text to read, in the call language. While recording, the part already due is in the primary color
    /// and the rest is dimmer, at an easy reading pace.
    private var sampleBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            // With several call languages the segmented picker above already names it.
            if SampleText.languages.count == 1 {
                Text(lang.title.uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let sample {
                progress(sample)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(L("Для этого языка нет текста: говори свободно."))
                    .font(.title3).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func progress(_ text: String) -> Text {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        let done = rec.isRecording ? Int(Double(words.count) * min(1, rec.elapsed / Self.readSeconds)) : words.count
        let read = Text(verbatim: words.prefix(done).joined(separator: " ")).foregroundStyle(.primary)
        let rest = Text(verbatim: (done > 0 && done < words.count ? " " : "") + words.dropFirst(done).joined(separator: " "))
            .foregroundStyle(.secondary)
        return Text("\(read)\(rest)")
    }

    /// Dot, timer, live level wave and the limit.
    private var meter: some View {
        HStack(spacing: 12) {
            if rec.isRecording {
                SZWRecordDot()
            } else {
                Circle().fill(.tertiary).frame(width: 8, height: 8).accessibilityHidden(true)
            }
            Text(verbatim: clock(rec.elapsed))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(rec.isRecording ? .primary : .secondary)
                .accessibilityLabel(L("Записано %@ из %@", clock(rec.elapsed), clock(SampleRecorder.maxSeconds)))
            SZWWave(bars: levels.map { SZWWave.Bar(value: pow($0, 1.4), them: false) })
                .animation(.easeOut(duration: 0.08), value: levels)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            Text(verbatim: "/ " + clock(SampleRecorder.maxSeconds))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func start() async {
        problem = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { micDenied = true; return }
        default:
            micDenied = true
            return
        }
        micDenied = false
        do {
            try rec.start()
        } catch {
            problem = L("Не получилось начать запись: %@", error.localizedDescription)
        }
    }

    /// A stopped recording: a long enough sample is saved right away, a short one is dropped.
    private func finished() {
        guard rec.file != nil, !enrolling else { return }
        if rec.elapsed < SampleRecorder.minSeconds {
            rec.discard()
            problem = L("Слишком коротко: нужно хотя бы %@ секунд", Int(SampleRecorder.minSeconds))
        } else {
            save()
        }
    }

    /// The engine makes (or extends) the own voice print from the sample.
    private func save() {
        guard let file = rec.file else { return }
        problem = nil
        enrolling = true
        Task {
            let outcome = await store.enrollMe(file, add: add)
            rec.discard()
            enrolling = false
            if outcome.isOK {
                dismiss()
            } else {
                problem = outcome.message.isEmpty ? L("Не получилось сохранить голос. Подробности в voice.log") : outcome.message
            }
        }
    }
}

// MARK: - Settings rows

/// "Your voice" row of the Voices section: status and Record, or Re-record / Add a sample.
struct MyVoiceRow: View {
    @ObservedObject private var store = VoiceStore.shared
    /// nil: no sheet; false: record or re-record (replaces); true: add one more sample.
    @State private var sheet: Bool?

    private var subtitle: String {
        guard let me = store.me else { return L("Не записан") }
        let seconds = L("%@ с речи", Int(me.seconds.rounded()))
        guard let d = ISO8601DateFormatter().date(from: me.updatedAt) else { return seconds }
        return L("Записан %@, %@", d.formatted(.dateTime.day().month(.wide)), seconds)
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                if store.me == nil {
                    Button(L("Записать…")) { sheet = false }
                        .disabled(store.isBusy)
                } else {
                    // Two plain buttons, each with its own name for VoiceOver: add a sample in another call
                    // language, or record again (replaces).
                    Button(L("Добавить язык…")) { sheet = true }
                        .disabled(store.isBusy)
                        .help(L("Добавить образец на другом языке звонков"))
                    Button(L("Записать заново…")) { sheet = false }
                        .disabled(store.isBusy)
                }
            }
        } label: {
            Text(L("Твой голос"))
            Text(subtitle)
        }
        .sheet(isPresented: Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } })) {
            VoiceSampleSheet(add: sheet ?? false)
        }
        .onAppear { store.refresh() }
    }
}

/// "Voices" section of General: your voice, the other voices saved (Manage opens the list), what voice prints are.
struct VoicesSection: View {
    @ObservedObject private var store = VoiceStore.shared
    @State private var showing = false

    private var others: [VoiceRecord] { store.records.filter { !$0.me } }

    private var names: String {
        var seen = Set<String>()
        let list = others.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .filter { seen.insert($0).inserted }
        return list.isEmpty ? L("Пока нет: имена подставятся, когда ты подпишешь спикеров") : list.joined(separator: ", ")
    }

    var body: some View {
        Section {
            MyVoiceRow()
            LabeledContent {
                HStack(spacing: 10) {
                    if store.isBusy { ProgressView().controlSize(.small) }
                    Text(verbatim: String(others.count)).foregroundStyle(.secondary).monospacedDigit()
                    Button(L("Управлять…")) { showing = true }
                        .disabled(store.records.isEmpty)
                }
            } label: {
                Text(L("Голоса собеседников"))
                Text(names)
            }
            .sheet(isPresented: $showing) { SavedVoicesSheet() }
        } header: {
            Text(L("Голоса"))
        } footer: {
            SettingsFooter(L("Отпечатки голосов относятся к биометрическим данным: они хранятся на этом Mac и, если ты настроил свой сервер с отправкой голосов, в твоём аккаунте Cloudflare. Sozvon использует их только для того, чтобы называть собеседников в твоих звонках."))
        }
    }
}

/// Every saved voice print: whose, in which project, how much speech, when; delete one or all.
struct SavedVoicesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = VoiceStore.shared
    @State private var confirmingAll = false
    @State private var deleting: VoiceRecord?
    @State private var problem: String?
    @State private var selection: VoiceRecord.ID?
    private let titles = Project.titles(Project.all())

    private var sorted: [VoiceRecord] {
        store.records.sorted { a, b in
            if a.me != b.me { return a.me }
            if a.profile != b.profile { return project(a) < project(b) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func project(_ r: VoiceRecord) -> String {
        r.profile.isEmpty ? L("Без проекта") : (titles[r.profile] ?? r.profile)
    }

    private func date(_ r: VoiceRecord) -> String {
        guard let d = ISO8601DateFormatter().date(from: r.updatedAt) else { return "" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Сохранённые голоса")).font(.headline).accessibilityAddTraits(.isHeader)
            List(selection: $selection) {
                ForEach(sorted) { r in
                    row(r).tag(r.id)
                        .contextMenu {
                            Button(L("Удалить…"), role: .destructive) { deleting = r }.disabled(store.isBusy)
                        }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .onDeleteCommand {
                if let id = selection, let r = store.records.first(where: { $0.id == id }) { deleting = r }
            }
            .frame(maxHeight: .infinity)
            if let problem {
                SettingsWarning(problem)
            }
            HStack(spacing: 8) {
                Button(L("Удалить все…")) { confirmingAll = true }
                    .disabled(store.records.isEmpty || store.isBusy)
                Spacer()
                if store.isBusy { ProgressView().controlSize(.small) }
                Button(L("Готово")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 440)
        .onChange(of: store.records.isEmpty) { _, empty in if empty { dismiss() } }
        .alert(L("Удалить все сохранённые голоса?"), isPresented: $confirmingAll) {
            Button(L("Удалить"), role: .destructive) {
                Task {
                    let outcome = await store.deleteAll()
                    problem = outcome.isOK ? nil : (outcome.message.isEmpty ? L("Не получилось удалить голоса") : outcome.message)
                }
            }
            Button(L("Отмена"), role: .cancel) {}
        } message: {
            Text(L("Sozvon перестанет узнавать собеседников и тебя по голосу. Голоса удалятся и с твоего сервера. Свой голос можно будет записать заново."))
        }
        .alert(L("Удалить голос «%@»?", deleting?.name ?? ""), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { r in
            Button(L("Удалить"), role: .destructive) { delete(r) }
            Button(L("Отмена"), role: .cancel) {}
        } message: { r in
            Text(r.me ? L("Sozvon перестанет узнавать тебя по голосу. Свой голос можно записать заново.")
                 : L("Sozvon перестанет узнавать этого человека по голосу. Голос снова сохранится, когда ты подпишешь его в расшифровке."))
        }
    }

    /// Whose voice, then project, seconds of speech and date in secondary text; a trash button at the end.
    private func row(_ r: VoiceRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: r.me ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.title2).foregroundStyle(r.me ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.me ? L("%@ (мой голос)", r.name) : r.name)
                Text([r.me ? "" : project(r), L("%@ с речи", Int(r.seconds.rounded())), date(r)]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SZSmallIconButton("trash", label: L("Удалить голос «%@»", r.name)) { deleting = r }
                .disabled(store.isBusy)
        }
        .padding(.vertical, 3)
    }

    private func delete(_ r: VoiceRecord) {
        Task {
            let outcome = await store.delete(r)
            problem = outcome.isOK ? nil : (outcome.message.isEmpty ? L("Не получилось удалить голос") : outcome.message)
        }
    }
}
