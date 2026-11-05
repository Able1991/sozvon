// First-run setup: assistant, name and languages, model, engine install, permissions, projects.

import AppKit
import SozvonCore
import SwiftUI

@MainActor
final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, assistant, account, model, install, permissions, projects }
    @Published var step: Step = .welcome
    @Published var log: [String] = []
    @Published var phase = ""
    @Published var installing = false
    @Published var installed = SetupModel.engineReady
    @Published var failed = false
    @Published var cancelled = false
    @Published var mic = Permissions.mic
    @Published var screen = Permissions.screen
    @Published var discovering = false
    @Published var discoverResult = ""
    @Published var discoverStatus = ""
    @Published var discoverStarted = Date()

    private var discoverProcess: RunningProcess?

    init(step: Step = .welcome) { self.step = step }

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
            if self.installed { self.step = .permissions }
        }
    }

    func refreshPermissions() {
        mic = Permissions.mic
        screen = Permissions.screen
    }

    /// Project discovery by the assistant: `bin/discover_projects.py`, with intermediate `STATUS: …` lines.
    func discover() {
        discovering = true
        discoverResult = ""
        discoverStatus = ""
        discoverStarted = Date()
        discoverProcess = ProcessRunner.run(Paths.python, [Paths.engineScript("discover_projects.py").path],
                                            environment: Engine.environment(), currentDirectory: Paths.data,
                                            onLine: { [weak self] l in
            guard let self else { return }
            if l.hasPrefix("STATUS: ") {
                withAnimation(.easeOut(duration: 0.2)) { self.discoverStatus = String(l.dropFirst(8)) }
            } else {
                self.discoverResult += (self.discoverResult.isEmpty ? "" : "\n") + l
            }
        }) { [weak self] _ in
            self?.discovering = false
            self?.discoverProcess = nil
        }
    }

    func stopDiscover() {
        discoverProcess?.terminate()
        discoverResult = L("Поиск остановлен")
    }
}

struct SetupView: View {
    @StateObject var m: SetupModel
    @ObservedObject private var installer = EngineInstaller.shared
    @ObservedObject private var s = Settings.shared
    let finish: () -> Void
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Group {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 36)
            .padding(.horizontal, 32)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(SetupModel.Step.allCases, id: \.self) { st in
                        Circle().fill(st == m.step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()
                if m.step != .welcome && m.step != .permissions && !(m.step == .install && (m.installing || m.installed)) {
                    Button(L("Назад")) { m.step = SetupModel.Step(rawValue: m.step.rawValue - 1)! }
                }
                primaryButton
            }
            .padding(16)
        }
        .frame(height: 650)
        .onReceive(timer) { _ in if m.step == .permissions { m.refreshPermissions() } }
        // Background update finished: the engine may now be ready.
        .onChange(of: installer.owner) { _, owner in if owner == nil && !m.installing { m.installed = SetupModel.engineReady } }
    }

    @ViewBuilder private var primaryButton: some View {
        switch m.step {
        case .install:
            if m.installed {
                Button(L("Далее")) { m.step = .permissions }.keyboardShortcut(.defaultAction)
            } else if m.installing {
                Button(L("Остановить")) { m.cancel() }.keyboardShortcut(.cancelAction)
            } else {
                Button(m.failed || m.cancelled ? L("Продолжить установку") : L("Установить")) { m.install() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(installer.isRunning)
            }
        case .projects:
            Button(L("Готово")) { finish() }.keyboardShortcut(.defaultAction)
        case .permissions:
            Button(m.mic && m.screen ? L("Далее") : L("Пропустить")) { m.step = .projects }.keyboardShortcut(.defaultAction)
        default:
            Button(L("Продолжить")) {
                if m.step == .account || m.step == .model { s.save() }
                m.step = SetupModel.Step(rawValue: m.step.rawValue + 1)!
            }.keyboardShortcut(.defaultAction)
        }
    }

    private var welcome: some View {
        VStack(spacing: 28) {
            Header(symbol: "app", title: L("Добро пожаловать в Sozvon"),
                   subtitle: L("Записывает созвоны в Zoom, Meet, Telegram и где угодно, а потом расшифровывает их прямо на этом Mac."))
            VStack(alignment: .leading, spacing: 14) {
                feature("record.circle.fill", L("Одна кнопка"), L("Нажал в строке меню, созвонился, остановил."))
                feature("lock.shield.fill", L("Локально"), L("Whisper и разбивка по голосам работают на Apple Silicon без интернета."))
                feature("person.2.fill", L("Кто что сказал"), L("Ты и собеседники по отдельности, с таймкодами."))
                feature("text.badge.checkmark", L("Саммари"), L("Решения, задачи и открытые вопросы. По желанию."))
            }
            .frame(maxWidth: 400)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var assistant: some View {
        VStack(spacing: 22) {
            Header(symbol: "sparkles", title: L("Помощник для саммари"),
                   subtitle: L("Расшифровка всегда локальная. Саммари и поиск проектов делает CLI, который у тебя уже есть, по твоей подписке."))
            VStack(spacing: 10) {
                ForEach(Assistant.allCases) { a in
                    ChoiceCard(symbol: a.symbol, title: a.title, subtitle: a.subtitle, selected: s.assistant == a,
                               badge: a == .none ? nil : (a.isAvailable ? L("установлен") : L("не найден")),
                               disabled: !a.isAvailable) { s.assistant = a }
                }
            }
        }
    }

    private var account: some View {
        VStack(spacing: 22) {
            Header(symbol: "person.crop.circle.fill", title: L("Пара деталей"),
                   subtitle: L("Имя пишется в расшифровке рядом с твоими репликами. Язык можно поменять для любого звонка."))
            Form {
                TextField(L("Как тебя подписывать"), text: $s.name, prompt: Text(L("Аня")))
                LanguagesPicker(title: L("Языки звонков"), selection: $s.languages)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 130)
        }
    }

    private var model: some View {
        VStack(spacing: 22) {
            Header(symbol: "cpu", title: L("Модель распознавания"),
                   subtitle: L("Работает на этом Mac. Модель скачается один раз, потом её можно сменить в настройках."))
            VStack(spacing: 10) {
                ForEach(WhisperModel.allCases) { md in
                    ChoiceCard(symbol: md.symbol, title: md.title, subtitle: md.subtitle, selected: s.model == md,
                               badge: md == .turbo ? L("рекомендуем") + " · " + md.size : md.size) { s.model = md }
                }
            }
        }
    }

    private var install: some View {
        VStack(spacing: 22) {
            Header(symbol: m.installed ? "checkmark.seal.fill" : "arrow.down.circle.dotted",
                   title: m.installed ? L("Движок установлен") : L("Установка движка"),
                   subtitle: L("Python, модель Whisper и разбивка по голосам скачаются один раз, 2-4 ГБ. Обычно 5-10 минут."),
                   tint: m.failed ? .orange : (m.installed ? .green : .accentColor))
            if m.installing {
                ProgressView().controlSize(.small)
                Text(m.phase).font(.callout).foregroundStyle(.secondary)
            } else if installer.owner == .background {
                ProgressView().controlSize(.small)
                Text(L("Движок обновляется в фоне. Установка станет доступна, когда обновление закончится."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if !m.log.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(m.log.enumerated()), id: \.offset) { i, l in
                                Text(l).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
                    .frame(height: 200)
                    .onChange(of: m.log.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            if m.cancelled && !m.installing {
                Text(L("Установка остановлена. Скачанное сохранится, продолжить можно в любой момент.")).font(.callout).foregroundStyle(.secondary)
            }
            if m.failed {
                Text(L("Что-то пошло не так. Лог лежит в setup.log в папке данных.")).font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private var permissions: some View {
        VStack(spacing: 22) {
            Header(symbol: "hand.raised.fill", title: L("Разрешения"),
                   subtitle: L("Микрофон нужен для твоего голоса, запись экрана и системного аудио для голосов собеседников. Видео не пишется."))
            VStack(spacing: 10) {
                StatusRow(ok: m.mic, title: L("Микрофон"), detail: m.mic ? L("Разрешено") : L("Нужен доступ"),
                          buttonTitle: L("Разрешить")) {
                    Task {
                        await Permissions.requestMic()
                        m.refreshPermissions()
                    }
                }
                StatusRow(ok: m.screen, title: L("Запись экрана и системного аудио"),
                          detail: m.screen ? L("Разрешено") : L("Включи Sozvon в списке, потом перезапусти"),
                          buttonTitle: L("Разрешить")) { Permissions.requestScreen() }
            }
            if !m.screen {
                Button(L("Я включил, перезапустить Sozvon")) {
                    UserDefaults.standard.set(SetupModel.Step.permissions.rawValue, forKey: "setupResumeStep")
                    Permissions.relaunch()
                }
                .buttonStyle(.link)
            }
        }
        .onAppear { m.refreshPermissions() }
    }

    private var projects: some View {
        VStack(spacing: 22) {
            Header(symbol: "person.2.crop.square.stack.fill", title: L("Проекты"),
                   subtitle: L("Для каждого проекта можно задать людей и термины, чтобы Whisper правильно их писал. Проект выбирается после звонка."))
            if s.assistant != .none {
                VStack(spacing: 8) {
                    Button { m.discover() } label: {
                        Label(L("Найти проекты через %@", s.assistant.title), systemImage: "magnifyingglass")
                            .padding(.horizontal, 8).padding(.vertical, 2)
                    }
                    .controlSize(.large)
                    .disabled(m.discovering)
                    Text(s.assistant == .claude
                         ? L("Claude посмотрит твои сессии Claude Code и спросит открытые, о чём там работа.")
                         : L("Codex посмотрит прошлые сессии и соберёт проекты, людей и термины."))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            if m.discovering {
                DiscoverProgress(m: m)
            } else if !m.discoverResult.isEmpty {
                Label(m.discoverResult, systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(L("Или потом: меню Sozvon → Проекты. Собеседники звонков сами дописываются в свой проект."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}
