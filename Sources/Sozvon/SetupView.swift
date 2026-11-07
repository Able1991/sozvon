// First-run setup: assistant, name and languages, model, engine install, permissions, projects.
// Laid out like Apple's own setup assistants: a symbol, a large title, a short body, system controls,
// and a bottom bar with Back on the left and the default action on the right. Building blocks live in
// DesignKit+Setup.swift.

import AppKit
import Combine
import SozvonCore
import SwiftUI

@MainActor
final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, assistant, account, model, install, permissions, projects }
    @Published var step: Step = .welcome {
        // Remembered until setup is finished: macOS's own "Quit & Reopen" (after granting screen recording)
        // relaunches Sozvon without telling us, and the assistant should come back on the same step.
        didSet { if !repair { UserDefaults.standard.set(step.rawValue, forKey: Self.stepKey) } }
    }
    static let stepKey = "setupStep"
    @Published var log: [String] = []
    @Published var phase = ""
    @Published var installing = false
    @Published var installed = SetupModel.engineReady
    @Published var failed = false
    @Published var cancelled = false
    let permissions = RecordingPermissions()
    let discovery = ProjectDiscovery.shared
    /// The pages redraw when the permissions or the project search change.
    private var children: [AnyCancellable] = []

    /// Opened from Settings ("Reinstall…", "Download Model…"): pick the model, reinstall, then back to Settings.
    let repair: Bool
    /// The model the engine had when setup opened (repair footer: "Current: …").
    let installedModel = Settings.shared.model

    init(step: Step = .welcome, repair: Bool = false) {
        self.step = step
        self.repair = repair
        if repair { installed = false }
        children = [permissions.objectWillChange.sink { [weak self] in self?.objectWillChange.send() },
                    discovery.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }]
        #if SOZVON_PREVIEW
        applyPreviewState()
        #endif
    }

    #if SOZVON_PREVIEW
    /// `--setup-state <name>` for snapshots of states that need a running installer or search.
    static var previewState: String?

    private func applyPreviewState() {
        // l10n-ignore-start
        let log = ["==> Ставлю uv 0.5.11", "uv 0.5.11 (aarch64-apple-darwin)", "==> Ставлю Python и зависимости",
                   "Resolved 112 packages in 1.2s", "Prepared 37 packages in 41.0s", "Installed 112 packages in 2.1s",
                   "==> Скачиваю модель Whisper Turbo", "model.safetensors  38%  612 MB / 1.6 GB  14.2 MB/s"]
        switch Self.previewState {
        case "installing":
            installed = false; installing = true; phase = "Скачиваю модель Whisper Turbo"; self.log = log
        case "failed":
            installed = false; failed = true; self.log = log + ["curl: (56) Recv failure: Connection reset by peer"]
        case "cancelled":
            installed = false; cancelled = true; self.log = log
        case "fresh":
            installed = false
        case "installed":
            installed = true
        case "discovering":
            discovery.preview(running: true, status: "Читаю сессии Claude Code", elapsed: 74)
        case "found":
            discovery.preview(running: false, result: "Найдено 3 проекта: Acme, Northwind, Sozvon")
        case "denied":
            SystemAudioPermission.previewStatus = .denied
            permissions.refresh()
        default: break
        }
        // l10n-ignore-end
    }
    #endif

    /// The permissions step's test recording: a few seconds into a temporary folder, deleted after.
    /// "Allowed" in the list is not proof: right after the permissions are granted the first start can
    /// fail, and it's better that it fails here than on a call.
    enum RecordCheck: Equatable { case idle, running, passed(systemHeard: Bool), failed(String) }
    var recordPassed: Bool { if case .passed = recordCheck { return true }; return false }
    @Published var recordCheck: RecordCheck = .idle
    @Published var checkMic: Float = 0
    @Published var checkSystem: Float = 0
    private let checkRecorder = Recorder()

    func checkRecording() async {
        guard recordCheck != .running else { return }
        recordCheck = .running
        for attempt in 0..<2 {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sozvon-check-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            do {
                let capture = try await checkRecorder.start(into: dir)
                var micHeard = false, systemHeard = false
                for tick in 0..<30 {
                    // The tap leaves Sozvon's own audio out: a chime from another process is what it can hear.
                    if capture == .tap && (tick == 5 || tick == 20) { Self.playProbe() }
                    try? await Task.sleep(for: .milliseconds(100))
                    let m = checkRecorder.meters
                    checkMic = m.mic.display
                    checkSystem = m.system.display
                    if m.mic.lastBufferAt != nil { micHeard = true }
                    if capture == .tap && m.system.heard { systemHeard = true }
                }
                _ = await checkRecorder.stop()
                checkMic = 0
                checkSystem = 0
                permissions.noteTestRecording(tapStarted: capture == .tap, heard: systemHeard)
                recordCheck = micHeard ? .passed(systemHeard: systemHeard)
                    : .failed(L("Запись запустилась, но микрофон не прислал звук. Проверь, какой микрофон выбран в Системных настройках → Звук."))
                return
            } catch {
                RecorderLog.write("setup check: \(error.localizedDescription)")
                // The first start right after the permissions are granted can fail; the second one works.
                if attempt == 0 && !Recorder.isTimeout(error) {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                recordCheck = .failed(error.localizedDescription)
                return
            }
        }
    }

    /// A short sound from another process (afplay): the process tap excludes Sozvon's own audio.
    private static func playProbe() {
        guard let url = Bundle.main.url(forResource: "record-start", withExtension: "wav") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = [url.path]
        try? p.run()
    }

    static var engineReady: Bool {
        EngineState.evaluate(data: Paths.data, model: Settings.shared.model, isDevEngine: Paths.isDevEngine).isUsable
    }

    /// Stop the install with all its child processes (uv, curl, python).
    func cancel() {
        cancelled = true
        EngineInstaller.shared.cancel(.setup)
    }

    /// Install through the shared owner: while a background update is running, don't start another.
    func install() {
        guard !EngineInstaller.shared.isRunning else { return }
        installing = true
        failed = false
        cancelled = false
        log = []
        Settings.shared.save()
        EngineInstaller.shared.run(.setup, onLine: { [weak self] line in
            guard let self else { return }
            if line.hasPrefix("==> ") { self.phase = String(line.dropFirst(4)) }
            self.log.append(line)
            if self.log.count > 400 { self.log.removeFirst(self.log.count - 400) }
        }) { [weak self] ok in
            guard let self else { return }
            self.installing = false
            self.installed = ok && SetupModel.engineReady
            self.failed = !self.installed && !self.cancelled
            if self.installed && !self.repair { self.step = .permissions }
        }
    }
}

struct SetupView: View {
    @StateObject var m: SetupModel
    @ObservedObject private var installer = EngineInstaller.shared
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var voices = VoiceStore.shared
    @State private var voiceSheet = false
    /// Height of the transparent title bar the page extends under: the hosting window adds it on top of
    /// the view's height.
    private static let titlebar = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height
    let finish: () -> Void
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        stepContent
            .id(m.step)
            .transition(.opacity)
            .setupBottomBar { bottomBar }
            .animation(.easeOut(duration: 0.2), value: m.step)
            // The page starts at the window's top edge, under the transparent title bar; the window
            // (title bar included) is 680 high.
            .ignoresSafeArea(edges: .top)
            .frame(height: 680 - Self.titlebar)
            .onReceive(timer) { _ in
                guard m.step == .permissions else { return }
                m.permissions.refresh()
                // A required permission went away: the passed test no longer says anything.
                if !m.permissions.requiredGranted, m.recordCheck != .running { m.recordCheck = .idle }
            }
            // Background update finished: the engine may now be ready.
            .onChange(of: installer.owner) { _, owner in
                if owner == nil && !m.installing && !m.repair { m.installed = SetupModel.engineReady }
            }
    }

    @ViewBuilder private var stepContent: some View {
        switch m.step {
        case .welcome: welcome
        case .assistant: assistant
        case .account: account
        case .model: model
        case .install: install
        case .permissions: permissions
        case .projects: projects
        }
    }

    // MARK: Bottom bar

    /// Back on the left; Cancel (repair) and the default action on the right.
    private var bottomBar: some View {
        SetupBottomBar {
            backButton
        } trailing: {
            cancelButton
            primaryButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(m.repair ? L("Переустановка движка") : L("Шаг %@ из %@", m.step.rawValue + 1, SetupModel.Step.allCases.count))
    }

    @ViewBuilder private var backButton: some View {
        if m.repair {
            if m.step == .install && !m.installing && !m.installed {
                Button(L("Назад")) { m.step = .model }
            }
        } else if m.step != .welcome && m.step != .permissions && !(m.step == .install && (m.installing || m.installed)) {
            Button(L("Назад")) { m.step = SetupModel.Step(rawValue: m.step.rawValue - 1)! }
        }
    }

    @ViewBuilder private var cancelButton: some View {
        if m.repair && (m.step == .model || (m.step == .install && !m.installing && !m.installed)) {
            Button(L("Отмена")) { finish() }.keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch m.step {
        case .install:
            if m.installed {
                if m.repair {
                    defaultButton(L("Готово")) { finish() }
                } else {
                    defaultButton(L("Продолжить")) { m.step = .permissions }
                }
            } else if m.installing {
                Button(L("Остановить")) { m.cancel() }.keyboardShortcut(.cancelAction)
            } else {
                defaultButton(m.failed || m.cancelled ? L("Продолжить установку") : L("Установить")) { m.install() }
                    .disabled(installer.isRunning)
            }
        case .model where m.repair:
            defaultButton(L("Переустановить")) {
                s.save()
                m.step = .install
                m.install()
            }
            .disabled(installer.isRunning)
        case .model:
            // The model step starts the download right away; the install step shows its progress.
            // The engine may be ready for one model and not for another: decide by the selected one.
            let ready = SetupModel.engineReady
            defaultButton(ready ? L("Продолжить") : L("Скачать и продолжить")) {
                s.save()
                m.installed = SetupModel.engineReady
                m.step = .install
                if !m.installed && !installer.isRunning { m.install() }
            }
        case .projects:
            defaultButton(L("Готово")) { finish() }
        case .permissions:
            defaultButton(m.permissions.requiredGranted && m.recordPassed ? L("Продолжить") : L("Пропустить")) {
                m.step = .projects
            }
            .disabled(m.recordCheck == .running)
        default:
            defaultButton(L("Продолжить")) {
                if m.step == .account { s.save() }
                m.step = SetupModel.Step(rawValue: m.step.rawValue + 1)!
            }
        }
    }

    /// The prominent default action of a step (Return), at least as wide as Apple's Continue buttons.
    private func defaultButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(minWidth: 84) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
    }

    // MARK: Welcome

    private var welcome: some View {
        SetupPage(icon: .app, title: L("Добро пожаловать в Sozvon"),
                  subtitle: L("Нажал в строке меню, созвонился, остановил. Дальше расшифровка и саммари на этом Mac.")) {
            VStack(alignment: .leading, spacing: 20) {
                SetupFeature(symbol: "record.circle", title: L("Одна кнопка"),
                             text: L("Запись из строки меню или плавающей капсулы. Sozvon сам предложит записать, когда начнётся звонок."))
                SetupFeature(symbol: "lock.shield", title: L("Локально"),
                             text: L("Расшифровка идёт на Mac. Ничего не покидает его, пока ты не включишь саммари через ассистента."))
                SetupFeature(symbol: "person.2", title: L("Кто что сказал"),
                             text: L("Реплики разбиваются по голосам. Запомни голоса один раз, и имена подставятся сами."))
                SetupFeature(symbol: "sparkles", title: L("Саммари"),
                             text: L("Коротко, решения и задачи через Claude Code или Codex. Потом можно спросить ассистента о любом звонке."))
            }
            .frame(maxWidth: 440)
            .padding(.top, 4)
        }
    }

    // MARK: Assistant

    private var assistant: some View {
        SetupPage(icon: .symbol("sparkles"), title: L("Помощник для саммари"),
                  subtitle: L("Кто будет писать «Коротко», «Решения» и «Задачи». Текст звонка уходит в сервис помощника, аудио остаётся на Mac.")) {
            SetupRadioGroup(selection: $s.assistant, items: Assistant.allCases, isEnabled: \.isAvailable,
                            accessibilityLabel: L("Помощник для саммари")) { a in
                SetupChoiceLabel(title: Self.title(a),
                                 note: a == .none ? nil : (a.isAvailable ? L("установлен") : L("не найден")),
                                 text: Self.subtitle(a))
            }
        }
    }

    private static func symbol(_ a: Assistant) -> String {
        switch a {
        case .claude: "chevron.left.chevron.right"
        case .codex: "apple.terminal"
        case .none: "shield"
        }
    }

    private static func title(_ a: Assistant) -> String { a == .none ? L("Без саммари") : a.title }

    private static func subtitle(_ a: Assistant) -> String {
        switch a {
        case .claude: L("Текст уходит в Anthropic. Потом можно спрашивать о звонках прямо в терминале.")
        case .codex: L("Текст уходит в OpenAI. Потом можно спрашивать о звонках в Codex.")
        case .none: L("Только расшифровка. Ничего не покидает Mac. Можно включить позже в Настройках.")
        }
    }

    // MARK: Details

    private var account: some View {
        SetupPage(icon: .symbol("person.crop.circle"), title: L("Пара деталей"),
                  subtitle: L("Имя пишется в расшифровке рядом с твоими репликами. Языки помогают модели не путать слова.")) {
            SetupGroup {
                SetupRow(title: L("Как тебя подписывать")) {
                    TextField(L("Как тебя подписывать"), text: $s.name, prompt: Text(L("Аня")))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 220)
                        .accessibilityLabel(L("Как тебя подписывать"))
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Языки звонков"))
                    SetupLanguages(selection: $s.languages)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("Языки звонков"))
            }
            if Engine.gentle {
                Text(L("Расшифровка уступает твоим программам: при звонке она не мешает Zoom и браузеру."))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, -8)
            }
            // The voice print is made by the engine: before it is installed, the sample is recorded later in Settings.
            if SetupModel.engineReady {
                SetupGroup(title: L("Голос")) {
                    SetupRow(title: L("Твой голос"), detail: L("По образцу Sozvon узнаёт тебя в звонках. Можно записать позже в Настройках.")) {
                        Text(voices.me.map { L("Записан, %@ с", Int($0.seconds.rounded())) } ?? L("Не записан"))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Button(voices.me == nil ? L("Записать образец…") : L("Записать заново…")) { voiceSheet = true }
                            .disabled(voices.isBusy)
                    }
                }
            }
        }
        .sheet(isPresented: $voiceSheet) { VoiceSampleSheet() }
        .onAppear { voices.refresh() }
    }

    // MARK: Model

    private var model: some View {
        SetupPage(icon: .symbol("waveform.badge.magnifyingglass"), title: L("Модель распознавания"),
                  subtitle: m.repair
                      ? L("Движок переустановится с выбранной моделью, недостающее докачается. Расшифровки и саммари не пострадают.")
                      : L("Модель скачается один раз и будет работать на этом Mac. Точнее обычно значит медленнее.")) {
            SetupRadioGroup(selection: $s.model, items: WhisperModel.allCases,
                            accessibilityLabel: L("Модель распознавания")) { md in
                SetupChoiceLabel(title: md.title, note: Self.badge(md), text: md.subtitle)
            }
            if m.repair {
                Text(L("Текущая: %@", "\(m.installedModel.title) · \(m.installedModel.size)"))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Size, "recommended" for Turbo, "downloaded" when the model is already on this Mac.
    private static func badge(_ md: WhisperModel) -> String {
        var parts = [md.size]
        if md == .turbo { parts.insert(L("рекомендуем"), at: 0) }
        if md.isDownloaded { parts.append(L("скачана")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Install

    private var install: some View {
        Group {
            if m.installed {
                SetupPage(icon: .status("checkmark.circle.fill", tint: .green), title: L("Движок установлен"),
                          subtitle: L("Python, модель и разбивка по голосам на месте. Первая расшифровка займёт чуть дольше: модель прогревается.")) {
                    SetupGroup {
                        SetupRow(symbol: "chevron.left.forwardslash.chevron.right", title: "Python",
                                 detail: L("Своя копия внутри Sozvon, системный Python не трогается")) { done }
                        SetupRow(symbol: "waveform", title: s.model.title, detail: L("%@, скачана и проверена", s.model.size)) { done }
                        SetupRow(symbol: "person.2.wave.2", title: L("Разбивка по голосам"),
                                 detail: L("pyannote, работает на GPU этого Mac")) { done }
                    }
                    // Repair: what was fixed stays readable on the done page.
                    if m.repair && !m.log.isEmpty { SetupLogView(lines: m.log) }
                }
            } else {
                SetupPage(icon: m.failed ? .status("exclamationmark.triangle.fill", tint: .yellow) : .symbol("arrow.down.circle"),
                          title: m.repair ? L("Переустановка движка") : L("Установка движка"),
                          subtitle: m.repair
                              ? L("Проверяю Python и модели, докачиваю и чиню то, что повреждено или не хватает. Записи и расшифровки не трогаются.")
                              : L("Python, модель Whisper и разбивка по голосам скачаются один раз, 2-4 ГБ. Обычно 5-10 минут.")) {
                    installStatus
                }
            }
        }
    }

    @ViewBuilder private var installStatus: some View {
        if m.installing {
            SetupProgress(text: m.phase.isEmpty ? L("Начинаю установку…") : m.phase)
        } else if installer.owner == .background {
            SetupProgress(text: L("Движок обновляется в фоне. Установка станет доступна, когда обновление закончится."))
        }
        if m.failed {
            Label {
                Text(L("Что-то пошло не так. Лог лежит в setup.log в папке данных."))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if m.cancelled && !m.installing {
            Text(L("Установка остановлена. Скачанное сохранится, продолжить можно в любой момент."))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        // A failed install opens its log right away.
        if !m.log.isEmpty { SetupLogView(lines: m.log, expanded: m.failed) }
    }

    private var done: some View { SetupCheck(text: L("Готово"), iconOnly: true) }

    // MARK: Permissions

    private var permissions: some View {
        let p = m.permissions
        return SetupPage(icon: .symbol("hand.raised"), title: L("Разрешения"),
                         subtitle: L("Без них звонок не записать. macOS спросит про каждое один раз.")) {
            SetupGroup {
                SetupRow(symbol: "mic", title: L("Микрофон"), detail: L("Твой голос")) {
                    permissionStatus(p.mic) { Task { await p.requestMic() } }
                }
                SetupRow(symbol: "rectangle.inset.filled.and.person.filled", title: L("Запись экрана"),
                         detail: p.screen ? L("Через неё Sozvon слышит микрофон. Картинка не записывается")
                             : L("Включи Sozvon в списке, потом перезапусти"),
                         detailSymbol: p.screen ? nil : "exclamationmark.triangle.fill") {
                    permissionStatus(p.screen) { p.requestScreen() }
                }
                SetupRow(symbol: "speaker.wave.2", title: L("Запись системного аудио"),
                         detail: SystemAudioCopy.detail(p),
                         detailSymbol: p.systemAudio == .denied ? "exclamationmark.triangle.fill" : nil) {
                    if p.systemAudio == .granted {
                        SetupCheck(text: L("Разрешено"))
                    } else if p.checkingSystemAudio || m.recordCheck == .running {
                        ProgressView().controlSize(.small)
                    } else if p.systemAudio == .unknown && !p.systemAudioAsked && p.requiredGranted {
                        // The first process tap is what makes macOS ask: the test recording starts it and
                        // hears whether it was allowed.
                        Button(L("Разрешить")) { Task { await m.checkRecording() } }
                    } else {
                        Button(SystemAudioCopy.button(p)) { Task { await p.requestSystemAudio() } }
                    }
                }
            }
            if p.requiredGranted {
                SetupGroup {
                    SetupRow(symbol: "waveform", title: L("Пробная запись"), detail: recordCheckDetail,
                             detailSymbol: { if case .failed = m.recordCheck { return "exclamationmark.triangle.fill" }; return nil }()) {
                        switch m.recordCheck {
                        case .running:
                            HStack(spacing: 6) {
                                CheckMeter(level: m.checkMic, symbol: "mic")
                                CheckMeter(level: m.checkSystem, symbol: "speaker.wave.2")
                                ProgressView().controlSize(.small)
                            }
                        case .passed:
                            SetupCheck(text: L("Получилось"))
                        case .idle:
                            Button(L("Проверить")) { Task { await m.checkRecording() } }
                        case .failed:
                            Button(L("Ещё раз")) { Task { await m.checkRecording() } }
                        }
                    }
                }
                .task {
                    // Back from the relaunch after granting screen recording: check right away, unless the
                    // first process tap (macOS's system audio prompt) is still to come: then "Allow" starts it.
                    if m.recordCheck == .idle && (p.systemAudio != .unknown || p.systemAudioAsked) {
                        await m.checkRecording()
                    }
                }
            }
            if !p.screen {
                Button(L("Я включил, перезапустить Sozvon")) {
                    UserDefaults.standard.set(SetupModel.Step.permissions.rawValue, forKey: "setupResumeStep")
                    Permissions.relaunch()
                }
                .buttonStyle(.link)
            }
            Text(L("Согласие собеседников на запись на тебе."))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .onAppear { p.refresh() }
    }

    private var recordCheckDetail: String {
        switch m.recordCheck {
        case .idle: return L("Три секунды во временную папку, с коротким звуком. Потом она удаляется")
        case .running: return L("Пишу три секунды…")
        case .passed(let systemHeard):
            return systemHeard ? L("Микрофон и звук компьютера записываются")
                : L("Микрофон записывается. Собеседников слышно через запись экрана, FaceTime так не слышно")
        case .failed(let message): return message
        }
    }

    @ViewBuilder private func permissionStatus(_ ok: Bool, title: String = L("Разрешить"),
                                               request: @escaping () -> Void) -> some View {
        if ok {
            SetupCheck(text: L("Разрешено"))
        } else {
            Button(title, action: request)
        }
    }

    // MARK: Projects

    private var projects: some View {
        SetupPage(icon: .symbol("folder.badge.person.crop"), title: L("Проекты"),
                  subtitle: L("Проект это команда и её слова: имена, продукты, термины. С ними расшифровка точнее, а саммари знает, о ком речь.")) {
            if s.assistant != .none {
                VStack(spacing: 10) {
                    Button { m.discovery.start() } label: {
                        Label(L("Найти проекты через %@", s.assistant.title), systemImage: Self.symbol(s.assistant))
                    }
                    .controlSize(.large)
                    .disabled(m.discovery.isRunning)
                    Text(s.assistant == .claude
                         ? L("Claude посмотрит твои сессии Claude Code и спросит открытые, о чём там работа.")
                         : L("Codex посмотрит прошлые сессии и соберёт проекты, людей и термины."))
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if m.discovery.isRunning {
                    GroupBox { ProjectDiscoveryProgress(discovery: m.discovery).padding(6) }
                } else if !m.discovery.result.isEmpty {
                    SetupDiscoverResult(text: m.discovery.result, outcome: m.discovery.outcome)
                }
            }
            Text(L("Проекты можно завести позже: Проекты… в меню строки меню."))
                .font(.callout).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }
}

/// A small level bar with its source's symbol, for the test recording.
private struct CheckMeter: View {
    let level: Float
    let symbol: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.green).frame(width: 36 * CGFloat(min(max(level, 0.04), 1)))
            }
            .frame(width: 36, height: 5)
            .animation(.linear(duration: 0.1), value: level)
        }
        .accessibilityHidden(true)
    }
}
