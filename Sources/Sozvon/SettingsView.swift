// Settings window: tabs like System Settings, Claude and Codex integration, engine status.

import AppKit
import SozvonCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var s = Settings.shared
    /// While an engine install or update is running, don't start another.
    @ObservedObject private var installer = EngineInstaller.shared
    @State private var panelOn = FloatingPanel.enabled
    @State private var panelIdle = FloatingPanel.showWhenIdle
    @State private var sounds = Sounds.enabled
    @State private var checkUpdates = Updates.enabled
    @State private var gentle = Engine.gentle
    @State private var updateStatus = ""
    @State private var uiLanguage = (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first ?? ""
    @State private var languageChanged = false
    enum Tab: CaseIterable {
        case general, recognition, panel, integrations, advanced
        var title: String {
            switch self {
            case .general: return L("Основные")
            case .recognition: return L("Распознавание")
            case .panel: return L("Панель")
            case .integrations: return L("Claude и Codex")
            case .advanced: return L("Дополнительно")
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .recognition: return "waveform"
            case .panel: return "pip"
            case .integrations: return "puzzlepiece.extension"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
    }

    let tab: Tab
    let reinstall: () -> Void
    var onPanelChange: () -> Void = {}

    // One tab of the system-style settings window (NSTabViewController, toolbar style).
    // Everything applies immediately, with no "Save" button.
    var body: some View {
        Group {
            switch tab {
            case .general: general
            case .recognition: recognition
            case .panel: panel
            case .integrations: IntegrationsView()
            case .advanced: advanced
            }
        }
        // "Advanced" is longer than the others (engine status), so it scrolls.
        .scrollDisabled(tab != .advanced)
        // All tabs share one height, so the window doesn't jump when switching.
        .frame(width: 480, height: 300, alignment: .top)
        .onChange(of: s.name) { s.save() }
        .onChange(of: s.hfToken) { s.save() }
        .onChange(of: s.languages) { s.save() }
        .onChange(of: s.languageSwitch) { s.save() }
        .onChange(of: s.model) { s.save() }
        .onChange(of: s.assistant) { s.save() }
        .onChange(of: panelOn) { _, v in FloatingPanel.enabled = v; onPanelChange() }
        .onChange(of: panelIdle) { _, v in FloatingPanel.showWhenIdle = v; onPanelChange() }
        .onChange(of: sounds) { _, v in Sounds.enabled = v; if v { Sounds.play(.start) } }
        .onChange(of: checkUpdates) { _, v in Updates.enabled = v }
        .onChange(of: gentle) { _, v in Engine.gentle = v }
    }

    private var general: some View {
        Form {
            Section {
                TextField(L("Имя в расшифровке"), text: $s.name, prompt: Text(L("Аня")))
                Picker(L("Язык интерфейса"), selection: $uiLanguage) {
                    Text(L("Как в системе")).tag("")
                    Text(verbatim: "Русский").tag("ru")  // l10n-ignore
                    Text(verbatim: "English").tag("en")
                }
                .onChange(of: uiLanguage) { _, v in
                    if v.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
                    else { UserDefaults.standard.set([v], forKey: "AppleLanguages") }
                    languageChanged = true
                }
                if languageChanged {
                    Button(L("Перезапустить Sozvon")) { Permissions.relaunch() }
                }
            }
            Section {
                Picker(L("Помощник для саммари"), selection: $s.assistant) {
                    ForEach(Assistant.allCases) { a in
                        Text(a.title + (a.isAvailable ? "" : L(" (не найден)"))).tag(a)
                    }
                }
            } footer: {
                Text(s.assistant.subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var recognition: some View {
        Form {
            Section {
                Picker(L("Модель"), selection: $s.model) {
                    ForEach(WhisperModel.allCases) { md in
                        Text(md.title + " · " + md.size).tag(md)
                    }
                }
                if !s.model.isDownloaded {
                    Button(L("Скачать модель…")) { s.save(); reinstall() }
                        .disabled(installer.isRunning)
                }
            } footer: {
                Text(s.model.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("Не мешать работе"), isOn: $gentle)
            } footer: {
                Text(gentle ? L("Расшифровка уступает твоим программам: Zoom, браузер и сборки не тормозят.")
                     : L("Расшифровка на полной скорости, Mac может подтормаживать."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LanguagesPicker(title: L("Языки звонков"), selection: $s.languages)
                if s.languages.count != 1 {
                    Toggle(L("Язык может меняться посреди речи"), isOn: $s.languageSwitch)
                }
            } footer: {
                Text(s.languages.count == 1
                     ? L("Можно отметить несколько: язык будет определяться среди них. Для конкретного звонка меняется в окне после записи.")
                     : L("Язык определяется для каждой дорожки. Со сменой посреди речи ещё и для каждой фразы, это медленнее на 20-30%."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var panel: some View {
        Form {
            Section {
                Toggle(L("Плавающая панель во время записи"), isOn: $panelOn)
                Toggle(L("Показывать панель и без записи"), isOn: $panelIdle).disabled(!panelOn)
                Toggle(L("Звук при старте и остановке записи"), isOn: $sounds)
            } footer: {
                Text(L("Панель поверх всех окон, даже поверх Zoom на весь экран: таймер, голоса и кнопка стоп. Перетаскивается мышью."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var advanced: some View {
        Form {
            Section {
                LabeledContent(L("Записи")) {
                    Button((Paths.calls.path as NSString).abbreviatingWithTildeInPath) { NSWorkspace.shared.open(Paths.calls) }
                        .buttonStyle(.link)
                }
                LabeledContent(L("Папка данных")) {
                    Button(L("Показать в Finder")) { NSWorkspace.shared.open(Paths.data) }.buttonStyle(.link)
                }
                LabeledContent(L("Движок")) {
                    Button(L("Переустановить…"), action: reinstall)
                        .disabled(installer.isRunning)
                        .help(installer.isRunning ? L("Движок обновляется") : "")
                }
            }
            EngineStatusSection()
            Section {
                Toggle(L("Проверять обновления"), isOn: $checkUpdates)
                LabeledContent(L("Версия")) {
                    HStack(spacing: 8) {
                        Text(updateStatus.isEmpty ? Updates.current : updateStatus).foregroundStyle(.secondary)
                        Button(L("Проверить")) {
                            updateStatus = L("Проверяю…")
                            Task {
                                if let r = await Updates.check(force: true) {
                                    updateStatus = L("Доступна %@", r.version)
                                    NSWorkspace.shared.open(r.url)
                                } else {
                                    updateStatus = L("%@, последняя", Updates.current)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                SecureField(L("Свой токен Hugging Face"), text: $s.hfToken, prompt: Text(L("не обязательно")))
            } footer: {
                Text(L("Не обязателен: все модели качаются без него. С токеном выше лимиты Hugging Face, если с одного адреса качают многие."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// "Claude and Codex" tab: connect Sozvon as an MCP server so the assistant can see calls.
/// Assistant CLIs run off the main thread so the window doesn't freeze.
struct IntegrationsView: View {
    @State private var connected: [Assistant: Bool] = [:]
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                ForEach([Assistant.claude, .codex]) { a in
                    LabeledContent {
                        if a.cliPath == nil {
                            Text(L("не установлен")).foregroundStyle(.secondary)
                        } else if connected[a] == true {
                            HStack(spacing: 8) {
                                Label(L("Подключён"), systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green).labelStyle(.titleAndIcon)
                                Button(L("Отключить")) {
                                    perform { MCP.disconnect(a); return "" }
                                }
                                .disabled(busy)
                            }
                        } else {
                            Button(L("Подключить")) {
                                perform {
                                    let (ok, out) = MCP.connect(a)
                                    return ok ? "" : out
                                }
                            }
                            .disabled(busy)
                        }
                    } label: {
                        Label(a.title, systemImage: a.symbol)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Ассистент сможет искать по звонкам, читать саммари и расшифровки: «что решили с клиентом на прошлой неделе?». Один общий сервер на все сессии, работает, пока запущен Sozvon. Данные читаются с этого Mac."))
                    if !message.isEmpty { Text(message).foregroundStyle(.orange) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { perform { "" } }
    }

    /// Run a CLI action in the background, then re-check where Sozvon is connected.
    private func perform(_ action: @escaping @Sendable () -> String) {
        busy = true
        Task {
            let (msg, state) = await Task.detached {
                let msg = action()
                var r: [Assistant: Bool] = [:]
                for a in [Assistant.claude, .codex] { r[a] = MCP.isConnected(a) }
                return (msg, r)
            }.value
            message = msg
            connected = state
            busy = false
        }
    }
}

/// "Engine status" section: Python, model, MCP server, last error.
struct EngineStatusSection: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var server = MCPServer.shared
    @State private var python = false
    @State private var model = false
    @State private var mcp: MCPHealth?
    @State private var failure: Engine.Failure?

    var body: some View {
        Section {
            row(python, L("Python"), python ? L("окружение на месте") : L("не установлен"))
            row(model, s.model.title, model ? L("скачана") : L("не скачана"))
            row(mcp == .listening, L("MCP-сервер"), mcp.map { "127.0.0.1:\(String(MCP.port)) · " + $0.title } ?? L("проверяю…"))
            if let f = server.lastFailure {
                Text(f).font(.caption).foregroundStyle(.orange)
            }
            if let failure {
                LabeledContent(L("Последняя ошибка")) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(failure.message).lineLimit(2).multilineTextAlignment(.trailing)
                        Text(failure.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        if let log = failure.log, FileManager.default.fileExists(atPath: log.path) {
                            Button(L("Журнал")) { NSWorkspace.shared.open(log) }.buttonStyle(.link)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(L("Состояние движка"))
                Spacer()
                Button(L("Проверить")) { refresh() }.buttonStyle(.link).font(.caption)
            }
        }
        .onAppear(perform: refresh)
    }

    private func row(_ ok: Bool, _ title: String, _ detail: String) -> some View {
        LabeledContent {
            Text(detail).foregroundStyle(.secondary)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(ok ? .green : .orange)
            }
        }
    }

    private func refresh() {
        python = FileManager.default.isExecutableFile(atPath: Paths.python.path)
        model = s.model.isDownloaded
        failure = Engine.lastFailure
        mcp = nil
        Task { mcp = await MCPHealth.probe() }
    }
}
