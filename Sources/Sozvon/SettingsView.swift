// Settings window: a standard Mac preferences window. Toolbar tabs (NSTabViewController, .toolbar style) over
// four grouped SwiftUI forms; the window takes each pane's height with an animation. Claude and Codex
// integration, engine status and the own server live here too.

import AppKit
import Combine
import SozvonCore
import SwiftUI

/// Which pane the Settings window shows; showSettings(tab:) switches it while the window is open.
@MainActor
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var tab: SettingsView.Tab = .general
}

// MARK: - Window

/// The preferences window's content: one toolbar tab per pane, the window title follows the tab, the window
/// animates to the height of each pane (up to a cap, the form scrolls beyond), nothing is focused on open or
/// on a tab switch (a stray keystroke must not overwrite the name field).
final class SettingsTabController: NSTabViewController {
    /// Pane width, like the preferences windows of Apple's apps.
    static let width: CGFloat = 580
    /// Content heights measured per pane, kept across window openings so a reopened window starts right.
    private static var heights: [SettingsView.Tab: CGFloat] = [:]

    private let nav: SettingsNav
    private var tabWatch: AnyCancellable?
    private var didAppear = false

    /// Taller panes scroll instead of growing the window past this (toolbar excluded).
    static var maxHeight: CGFloat {
        #if SOZVON_PREVIEW
        if SettingsPreview.tall { return 2000 }
        #endif
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return min(720, screen - 140)
    }

    init(nav: SettingsNav, reinstall: @escaping () -> Void, onPanelChange: @escaping () -> Void) {
        self.nav = nav
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        // No crossfade: on macOS 26 a pane shown for the first time through it keeps a scroll edge "pocket" as
        // tall as the toolbar over its top (a blurred band over the first section until the next visit).
        transitionOptions = [.allowUserInteraction]
        for tab in SettingsView.Tab.allCases {
            let pane = SettingsPane(tab: tab, reinstall: reinstall, onPanelChange: onPanelChange) { [weak self] h in
                self?.measured(tab, h)
            }
            let host = SettingsPaneHost(rootView: pane)
            // The window size is ours (see fit), SwiftUI only lays out inside it.
            host.sizingOptions = []
            // The pane sits below the toolbar (no full-size content), so it has no safe area to keep clear.
            host.safeAreaRegions = []
            host.title = tab.title
            host.view.frame.size = NSSize(width: Self.width, height: Self.height(tab))
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            addTabViewItem(item)
        }
        selectedTabViewItemIndex = SettingsView.Tab.allCases.firstIndex(of: nav.tab) ?? 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func height(_ tab: SettingsView.Tab) -> CGFloat {
        min(heights[tab] ?? 460, maxHeight)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.frame.size = NSSize(width: Self.width, height: Self.height(nav.tab))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.title = nav.tab.title
        // A deep link (sozvon://settings/cloud) switches the tab of the open window. Setting the same tab
        // again (clicking the current one) is not a switch: keep the focus.
        tabWatch = nav.$tab.removeDuplicates().sink { [weak self] tab in
            MainActor.assumeIsolated {
                guard let self, let i = SettingsView.Tab.allCases.firstIndex(of: tab) else { return }
                if self.selectedTabViewItemIndex != i { self.selectedTabViewItemIndex = i }
                self.clearFocus()
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        didAppear = true
        fit(animated: false)
        clearFocus()
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        let tab = SettingsView.Tab.allCases[selectedTabViewItemIndex]
        if nav.tab != tab { nav.tab = tab }
        view.window?.title = tab.title
        fit(animated: didAppear)
    }

    /// A pane reported its form's content height (on first layout and whenever rows appear or go).
    private func measured(_ tab: SettingsView.Tab, _ height: CGFloat) {
        let h = height.rounded(.up)
        guard h > 0, Self.heights[tab] != h else { return }
        Self.heights[tab] = h
        if tab == nav.tab { fit(animated: didAppear) }
    }

    /// Resize the window to the selected pane, keeping its top edge in place.
    private func fit(animated: Bool) {
        guard let window = view.window else { return }
        let content = NSSize(width: Self.width, height: Self.height(nav.tab))
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        guard abs(frame.height - window.frame.height) > 0.5 || abs(frame.width - window.frame.width) > 0.5 else { return }
        var target = window.frame
        target.origin.y += target.height - frame.height
        target.size = frame.size
        window.setFrame(target, display: true, animate: animated)
    }

    private func clearFocus() {
        clearSettingsFocus(view.window)
    }
}

/// A pane's hosting controller: SwiftUI focuses the first text field once the pane is in the window, take
/// that back so typing doesn't land in the name field.
private final class SettingsPaneHost: NSHostingController<SettingsPane> {
    override func viewDidAppear() {
        super.viewDidAppear()
        clearSettingsFocus(view.window)
    }
}

/// Drop the focus now and again over the next passes: SwiftUI hands it to a field asynchronously.
@MainActor
private func clearSettingsFocus(_ window: NSWindow?) {
    guard let window else { return }
    window.makeFirstResponder(nil)
    for delay in [0.0, 0.05, 0.2] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
            MainActor.assumeIsolated {
                if window?.firstResponder is NSText || window?.firstResponder is NSTextField {
                    window?.makeFirstResponder(nil)
                }
            }
        }
    }
}

/// One pane in its tab: the form, reporting how tall its content is.
private struct SettingsPane: View {
    let tab: SettingsView.Tab
    let reinstall: () -> Void
    let onPanelChange: () -> Void
    let onHeight: (CGFloat) -> Void

    var body: some View {
        SettingsView(tab: tab, reinstall: reinstall, onPanelChange: onPanelChange)
            .onScrollGeometryChange(for: CGFloat.self) { g in
                g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom
            } action: { _, h in
                onHeight(h)
            }
            .frame(width: SettingsTabController.width)
            .frame(maxHeight: .infinity)
            .modifier(NoTopScrollEdge())
    }
}

/// No scroll edge blur under the toolbar: the pane starts below it, there is nothing to blend into.
private struct NoTopScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

// MARK: - Panes

/// One pane. Everything applies immediately, with no "Save" button (except the own server address).
struct SettingsView: View {
    enum Tab: CaseIterable {
        case general, recognition, assistants, server
        var title: String {
            switch self {
            case .general: return L("Основные")
            case .recognition: return L("Распознавание")
            case .assistants: return L("Ассистенты")
            case .server: return L("Облако")
            }
        }
        /// The toolbar tab's SF Symbol.
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .recognition: return "waveform"
            case .assistants: return "sparkles"
            case .server: return "cloud"
            }
        }
    }

    let tab: Tab
    let reinstall: () -> Void
    var onPanelChange: () -> Void = {}

    var body: some View {
        switch tab {
        case .general: GeneralPane(onPanelChange: onPanelChange)
        case .recognition: RecognitionPane(reinstall: reinstall)
        case .assistants: AssistantsPane()
        case .server: ServerView()
        }
    }
}

// MARK: General

private struct GeneralPane: View {
    let onPanelChange: () -> Void
    @ObservedObject private var s = Settings.shared
    // Read straight from the defaults: the capsule's hide button turns the panel off while Settings is open.
    @AppStorage(FloatingPanel.defaultsKey) private var panelOn = true
    @AppStorage(FloatingPanel.idleKey) private var panelIdle = true
    @State private var sounds = Sounds.enabled
    @State private var callPrompt = CallPromptController.enabled
    @State private var silenceAlerts = SilenceAlerts.enabled
    @State private var checkUpdates = Updates.enabled
    @State private var keepAudio = AudioCleanup.days
    @State private var calendar = CalendarPrefill.enabled
    @State private var updateStatus = ""
    @State private var uiLanguage = GeneralPane.chosenLanguage()
    @State private var calendarDenied = CalendarPrefill.denied
    /// The interface language override Sozvon was started with ("" for the system's):
    /// only to tell whether a relaunch is needed, the picker shows `chosenLanguage()`.
    private static let launchLanguage = chosenLanguage()

    /// The interface language override saved now ("" for the system's), possibly not applied yet.
    private static func chosenLanguage() -> String {
        InterfaceLanguage.tag(
            UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])
    }

    var body: some View {
        Form {
            Section(L("Профиль")) {
                LabeledContent {
                    TextField(L("Как тебя подписывать"), text: $s.name, prompt: Text(L("Аня")))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 220)
                        .accessibilityLabel(L("Как тебя подписывать"))
                } label: {
                    Text(L("Как тебя подписывать"))
                    Text(L("Имя пишется в расшифровке рядом с твоими репликами"))
                }
                Picker(L("Язык интерфейса"), selection: $uiLanguage) {
                    Text(L("Как в системе")).tag("")
                    Divider()
                    Text(verbatim: "Русский").tag("ru")  // l10n-ignore
                    Text(verbatim: "English").tag("en")
                }
                if uiLanguage != Self.launchLanguage {
                    LabeledContent(L("Язык сменится после перезапуска")) {
                        Button(L("Перезапустить Sozvon")) { Permissions.relaunch() }
                    }
                }
            }

            Section {
                Toggle(isOn: $panelOn) {
                    Text(L("Плавающая панель"))
                    Text(L("Капсула под строкой меню, поверх всех окон"))
                }
                Toggle(isOn: $panelIdle) {
                    Text(L("Показывать панель и без записи"))
                    Text(L("Капсула видна, даже когда запись не идёт"))
                }
                .disabled(!panelOn)
                Toggle(isOn: $callPrompt) {
                    Text(L("Предлагать запись при звонке"))
                    Text(L("Zoom, Google Meet, FaceTime, Telegram"))
                }
                .help(L("Когда Zoom, Telegram, браузер или другое приложение для звонков включает микрофон, панель спросит, записать ли звонок. Сам Sozvon ничего не записывает."))
                Toggle(isOn: $silenceAlerts) {
                    Text(L("Предупреждать о тишине"))
                    Text(L("Если тебя или собеседников не слышно больше двух минут или тебя очень тихо слышно"))
                }
                Toggle(L("Звук при старте и остановке записи"), isOn: $sounds)
            } header: {
                Text(L("Запись"))
            } footer: {
                SettingsFooter(L("Запись начинается только по кнопке «Записать». Согласие собеседников на запись на тебе."))
            }

            PermissionsSection()

            VoicesSection()

            Section {
                Toggle(isOn: $calendar) {
                    Text(L("Подставлять тему из Календаря"))
                    Text(L("Название встречи и участники"))
                }
                if calendar && calendarDenied {
                    LabeledContent {
                        Button(L("Открыть настройки")) { Permissions.openPane("Privacy_Calendars") }
                    } label: {
                        Label(L("Нет доступа к Календарю"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Picker(L("Автоудаление аудио"), selection: $keepAudio) {
                    ForEach(AudioRetention.choices, id: \.self) { d in
                        Text(d == 0 ? L("Никогда") : d == 7 ? L("Через неделю") : L("Через %@ дней", d)).tag(d)
                    }
                }
            } header: {
                Text(L("После звонка"))
            } footer: {
                SettingsFooter(L("Стирается только звук старых звонков: расшифровка, итоги и заметки остаются. Час звонка освобождает 50-100 МБ."))
            }

            Section(L("Обновления")) {
                Toggle(L("Проверять автоматически"), isOn: $checkUpdates)
                LabeledContent {
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
                } label: {
                    Text(L("Версия"))
                    Text(updateStatus.isEmpty ? Self.version : updateStatus)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: s.name) { s.save() }
        .onChange(of: panelOn) { onPanelChange() }
        .onChange(of: panelIdle) { onPanelChange() }
        .onChange(of: callPrompt) { _, v in CallPromptController.enabled = v; onPanelChange() }
        .onChange(of: silenceAlerts) { _, v in SilenceAlerts.enabled = v }
        .onChange(of: sounds) { _, v in Sounds.enabled = v; if v { Sounds.play(.start) } }
        .onChange(of: checkUpdates) { _, v in Updates.enabled = v }
        .onChange(of: calendar) { _, v in
            CalendarPrefill.enabled = v
            guard v else { return }
            Task {
                _ = await CalendarPrefill.requestAccess()
                calendarDenied = CalendarPrefill.denied
            }
        }
        // Access granted in System Settings while the window was open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            calendarDenied = CalendarPrefill.denied
        }
        .onChange(of: keepAudio) { old, v in
            guard v != AudioCleanup.days else { return }
            if AudioCleanup.confirm(v) {
                AudioCleanup.days = v
                AudioCleanup.run()
            } else {
                keepAudio = old
            }
        }
        .onChange(of: uiLanguage) { _, v in
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
            else { UserDefaults.standard.set([v], forKey: "AppleLanguages") }
        }
    }

    /// "1.4.2 (318)": the version and the build number.
    private static var version: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty || build == Updates.current ? Updates.current : "\(Updates.current) (\(build))"
    }
}

/// "Permissions": what a recording needs from macOS, with a way to ask for each or open its switch.
private struct PermissionsSection: View {
    @StateObject private var p = RecordingPermissions()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            row(L("Микрофон"), L("Твой голос"), ok: p.mic) {
                Button(L("Разрешить")) { Task { await p.requestMic() } }
            }
            row(L("Запись экрана"),
                p.screen ? L("Через неё Sozvon слышит микрофон. Картинка не записывается")
                    : L("Включи Sozvon в списке, потом перезапусти"), ok: p.screen) {
                Button(L("Разрешить")) { p.requestScreen() }
                Button(L("Перезапустить")) { Permissions.relaunch() }
            }
            row(L("Запись системного аудио"), SystemAudioCopy.detail(p), ok: p.systemAudio == .granted) {
                if p.checkingSystemAudio {
                    ProgressView().controlSize(.small)
                } else {
                    Button(SystemAudioCopy.button(p)) { Task { await p.requestSystemAudio() } }
                }
            }
        } header: {
            Text(L("Разрешения"))
        } footer: {
            SettingsFooter(L("Включаются в Системных настройках: Конфиденциальность и безопасность."))
        }
        .onAppear { p.refresh() }
        .onReceive(timer) { _ in p.refresh() }
    }

    /// A permission: what it is for, and "Allowed" or the buttons to get it.
    private func row(_ title: String, _ detail: String, ok: Bool,
                     @ViewBuilder actions: () -> some View) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if ok { SZSettingsStatus(text: L("Разрешено")) } else { actions() }
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

// MARK: Recognition

private struct RecognitionPane: View {
    let reinstall: () -> Void
    @ObservedObject private var s = Settings.shared
    /// While an engine install or update is running, don't start another.
    @ObservedObject private var installer = EngineInstaller.shared
    @State private var gentle = Engine.gentle

    var body: some View {
        Form {
            Section {
                Picker(L("Модель распознавания"), selection: $s.model) {
                    ForEach(WhisperModel.allCases, id: \.self) { m in
                        Text(verbatim: m.title + " · " + m.size).tag(m)
                    }
                }
                if !s.model.isDownloaded {
                    LabeledContent(L("Модель не скачана")) {
                        Button(L("Скачать модель…")) { s.save(); reinstall() }
                            .disabled(installer.isRunning)
                    }
                }
                LabeledContent(L("Языки звонков")) {
                    LanguagesMenu(title: L("Языки звонков"), selection: $s.languages)
                }
                if s.languages.count != 1 {
                    Toggle(isOn: $s.languageSwitch) {
                        Text(L("Переключение языка посреди речи"))
                        Text(L("Язык определяется для каждой фразы, медленнее на 20-30%"))
                    }
                }
            } header: {
                Text(L("Модель"))
            } footer: {
                SettingsFooter(s.model.subtitle + " " + (s.languages.count == 1
                    ? L("Можно отметить несколько: язык будет определяться среди них. Для конкретного звонка меняется в окне после записи.")
                    : L("Язык определяется для каждой дорожки. Со сменой посреди речи ещё и для каждой фразы, это медленнее на 20-30%.")))
            }

            Section(L("Производительность")) {
                Toggle(isOn: $gentle) {
                    Text(L("Низкий приоритет"))
                    Text(L("Вентиляторы тише, расшифровка дольше"))
                }
                .help(L("Расшифровка уступает твоим программам: Zoom, браузер и сборки не тормозят."))
            }

            EngineSection(reinstall: reinstall)
        }
        .formStyle(.grouped)
        .onChange(of: s.languages) { s.save() }
        .onChange(of: s.languageSwitch) { s.save() }
        .onChange(of: s.model) { s.save() }
        .onChange(of: gentle) { _, v in Engine.gentle = v }
    }
}

/// Call languages as a pull-down: each item toggles a language, the button shows the summary ("Русский + English").
private struct LanguagesMenu: View {
    let title: String
    @Binding var selection: [SpeechLanguage]

    var body: some View {
        Menu(SpeechLanguage.summary(selection)) {
            ForEach(SpeechLanguage.real) { lang in
                Toggle(lang.title, isOn: Binding(get: { selection.contains(lang) }, set: { _ in toggle(lang) }))
            }
            Divider()
            Toggle(SpeechLanguage.auto.title, isOn: Binding(get: { selection.isEmpty }, set: { _ in toggle(.auto) }))
        }
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(SpeechLanguage.summary(selection))
    }

    private func toggle(_ lang: SpeechLanguage) {
        selection = SpeechLanguage.toggling(lang, in: selection)
    }
}

/// "Engine" and "Files": Python, model, MCP server, last error, the recordings and data folders and reinstall.
struct EngineSection: View {
    let reinstall: () -> Void
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var server = MCPServer.shared
    @ObservedObject private var installer = EngineInstaller.shared
    @State private var mcp: MCPHealth?
    @State private var failure: Engine.Failure?

    // Read on every render, not snapshotted: the model picker and a finished install (observed via
    // `installer`) redraw the rows with the current state.
    private var python: Bool { FileManager.default.isExecutableFile(atPath: Paths.python.path) }
    private var model: Bool { s.model.isDownloaded }

    var body: some View {
        Section {
            LabeledContent(L("Python")) {
                SZSettingsStatus(text: python ? L("Установлен") : L("Не установлен"), ok: python)
            }
            .onAppear(perform: refresh)
            .onChange(of: installer.isRunning) { _, running in if !running { refresh() } }
            LabeledContent {
                SZSettingsStatus(text: model ? L("Скачана") : L("Не скачана"), ok: model)
            } label: {
                Text(L("Модель"))
                Text(s.model.title)
            }
            LabeledContent {
                HStack(spacing: 10) {
                    if let mcp {
                        SZSettingsStatus(text: mcp == .listening ? L("Работает") : L("Не отвечает"), ok: mcp == .listening)
                    } else {
                        Text(L("Проверяю…")).foregroundStyle(.secondary)
                    }
                    Button(L("Проверить"), action: refresh)
                        .disabled(mcp == nil)
                }
            } label: {
                Text(L("MCP-сервер"))
                if mcp == .listening {
                    Text(verbatim: "127.0.0.1:\(MCP.port)").monospaced()
                }
            }
            // The exact answer stays in the tooltip: the row speaks plain words.
            .help(mcp.map { "127.0.0.1:\(String(MCP.port)) · " + $0.title } ?? "")
            if let failure {
                LabeledContent {
                    if let log = failure.log, FileManager.default.fileExists(atPath: log.path) {
                        Button(L("Журнал")) { NSWorkspace.shared.open(log) }
                    }
                } label: {
                    Text(L("Последняя ошибка"))
                    Text(failure.message + "\n" + failure.date.formatted(date: .abbreviated, time: .shortened))
                }
            }
        } header: {
            Text(L("Движок"))
        } footer: {
            if let f = serverFailure { SettingsWarning(f) }
        }

        Section(L("Файлы")) {
            pathRow(L("Папка записей"), Paths.calls)
            pathRow(L("Папка данных"), Paths.data)
            LabeledContent {
                Button(L("Переустановить…"), action: reinstall)
                    .disabled(installer.isRunning)
                    .help(installer.isRunning ? L("Движок обновляется") : "")
            } label: {
                Text(L("Движок"))
                Text(L("Python, модель и разбивка по голосам"))
            }
        }
    }

    /// A folder: its path in mono under the title (~ for home), and Show in Finder.
    private func pathRow(_ title: String, _ url: URL) -> some View {
        LabeledContent {
            Button(L("Показать в Finder")) { NSWorkspace.shared.open(url) }
        } label: {
            Text(title)
            Text(verbatim: (url.path as NSString).abbreviatingWithTildeInPath)
                .monospaced()
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var serverFailure: String? {
        #if SOZVON_PREVIEW
        if SettingsPreview.engineError { return L("MCP-сервер завершился с кодом %@, подробности в mcp.log", 1) }
        #endif
        return server.lastFailure
    }

    private func refresh() {
        failure = Engine.lastFailure
        mcp = nil
        Task {
            #if SOZVON_PREVIEW
            if SettingsPreview.engineError { mcp = .notListening; return }
            #endif
            mcp = await MCPHealth.probe()
        }
    }
}

// MARK: Assistants

private struct AssistantsPane: View {
    @ObservedObject private var s = Settings.shared

    var body: some View {
        Form {
            Section {
                Picker(L("Помощник для саммари"), selection: $s.assistant) {
                    ForEach(Assistant.allCases) { a in
                        Text(a.title + (a.isAvailable ? "" : L(" (не найден)"))).tag(a)
                    }
                }
            } header: {
                Text(L("Саммари"))
            } footer: {
                SettingsFooter(s.assistant.subtitle)
            }
            IntegrationsSection()
        }
        .formStyle(.grouped)
        .onChange(of: s.assistant) { s.save() }
    }
}

/// Claude Code and Codex: connect Sozvon as an MCP server so the assistant can see calls.
/// Assistant CLIs run off the main thread so the window doesn't freeze.
struct IntegrationsSection: View {
    /// nil until the first check of both CLIs has finished.
    @State private var connections: [Assistant: MCP.Connection]?
    @State private var busy = false
    @State private var message = ""
    /// The Terminal command just copied (its button briefly says so).
    @State private var copied: Assistant?

    var body: some View {
        Section {
            connection(.claude)
            connection(.codex)
        } header: {
            Text(L("Подключения"))
        } footer: {
            if !message.isEmpty { SettingsWarning(message) }
        }
        .onAppear { perform { "" } }

        Section {
            command(.claude)
            command(.codex)
        } header: {
            Text(L("Команда для терминала"))
        } footer: {
            SettingsFooter(L("Ассистент сможет искать по звонкам, читать саммари и расшифровки: «что решили с клиентом на прошлой неделе?». Один общий сервер на все сессии, работает, пока запущен Sozvon. Данные читаются с этого Mac."))
        }
    }

    private func connection(_ a: Assistant) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                status(a)
                action(a)
            }
        } label: {
            Text(a.title)
            Text(L("Видит звонки, саммари и заметки"))
        }
    }

    private func command(_ a: Assistant) -> some View {
        LabeledContent {
            Button(copied == a ? L("Скопировано") : L("Скопировать")) { copy(a) }
                .accessibilityLabel(L("Скопировать команду для %@", a.title))
        } label: {
            Text(a.title)
            // The short form; the copied command also carries the transport and the password header.
            Text(verbatim: (a == .claude ? "claude" : "codex") + " mcp add \(MCP.name) \(MCP.url)")
                .monospaced()
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .help(L("То же, что делает «Подключить», с паролем"))
        }
    }

    @ViewBuilder private func status(_ a: Assistant) -> some View {
        if a.cliPath == nil {
            Text(L("Не установлен")).foregroundStyle(.secondary)
        } else if let connections {
            switch connections[a] ?? .none {
            case .connected: SZSettingsStatus(text: L("Подключён"))
            case .outdated: SZSettingsStatus(text: L("Старая настройка"), ok: false)
                .help(L("Sozvon подключён по-старому: без общего сервера или пароля. Подключи заново."))
            case .none: EmptyView()
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private func action(_ a: Assistant) -> some View {
        if a.cliPath != nil, let connections {
            switch connections[a] ?? .none {
            case .connected:
                Button(L("Отключить…")) {
                    guard confirmDisconnect(a) else { return }
                    perform { MCP.disconnect(a); return "" }
                }
                .disabled(busy)
            case .outdated, .none:
                Button(connections[a] == .outdated ? L("Подключить заново") : L("Подключить")) {
                    perform {
                        let (ok, out) = MCP.connect(a)
                        return ok ? "" : out
                    }
                }
                .disabled(busy)
            }
        }
    }

    private func confirmDisconnect(_ a: Assistant) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("Отключить Sozvon от %@?", a.title)
        alert.informativeText = L("Ассистент перестанет видеть звонки. Подключить снова можно в любой момент.")
        alert.addButton(withTitle: L("Отключить"))
        alert.addButton(withTitle: L("Отменить"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func copy(_ a: Assistant) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MCP.manualSetup(a), forType: .string)
        copied = a
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == a { copied = nil } }
    }

    /// Run a CLI action in the background, then re-check how Sozvon is connected.
    private func perform(_ action: @escaping @Sendable () -> String) {
        busy = true
        Task {
            let (msg, state) = await Task.detached {
                let msg = action()
                var r: [Assistant: MCP.Connection] = [:]
                for a in [Assistant.claude, .codex] { r[a] = MCP.connection(a) }
                return (msg, r)
            }.value
            message = msg
            connections = state
            busy = false
        }
    }
}

// MARK: Cloud

/// "Cloud" tab (Облако): the user's own server with copies of finished calls (text, and optionally audio and
/// voice prints), for Claude or ChatGPT on the phone. "Connect Cloudflare" sets it up in one click; the address
/// and password can also be typed by hand in "Own address". Saving them (Enter or "Save", never per keystroke)
/// checks the server once and syncs everything.
struct ServerView: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var sync = ServerSync.shared
    @ObservedObject private var cloudflare = CloudflareConnector.shared
    @State private var copied: String?
    @State private var showPassword = false
    @State private var claudeHint = false
    /// What is typed in the manual fields; it reaches Settings only on Enter or "Save".
    // Filled once from the saved values, not on appear: switching tabs must not wipe what is being typed.
    @State private var urlDraft = Settings.shared.serverURL
    @State private var passwordDraft = Settings.shared.serverPassword

    var body: some View {
        let ready = s.hasServer || cloudflare.isWorking
        Form {
            Section {
                intro
                connect
            } footer: {
                if (cloudflare.phase == .done || cloudflare.isFailed), let notice = cloudflare.notice {
                    SettingsWarning(notice)
                }
            }

            if let mcp = sync.connectorURL {
                Section {
                    connected(mcp)
                } header: {
                    Text(L("Claude и ChatGPT"))
                } footer: {
                    SettingsFooter(claudeHint ? L("Адрес уже в буфере: вставь его, назови Sozvon и войди паролем")
                                   : L("Добавь адрес как коннектор и войди тем же паролем"))
                }
            }

            Section {
                TextField(L("Адрес сервера"), text: $urlDraft, prompt: Text(verbatim: "https://sozvon.example.com"))
                    .onSubmit(commitManual)
                    .accessibilityLabel(L("Адрес сервера"))
                LabeledContent(L("Пароль")) {
                    HStack(spacing: 6) {
                        Group {
                            if showPassword {
                                TextField(L("Пароль"), text: $passwordDraft, prompt: Text(verbatim: "••••••••••••"))  // l10n-ignore
                            } else {
                                SecureField(L("Пароль"), text: $passwordDraft, prompt: Text(verbatim: "••••••••••••"))  // l10n-ignore
                            }
                        }
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .monospaced()
                        .frame(minWidth: 120, maxWidth: 220)
                        .onSubmit(commitManual)
                        .accessibilityLabel(L("Пароль"))
                        eye
                        copyButton(passwordDraft, help: L("Скопировать пароль")).disabled(passwordDraft.isEmpty)
                    }
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        if s.hasServer {
                            Button(L("Синхронизировать")) { Task { await sync.checkAndSync() } }
                                .disabled(sync.isRunning || cloudflare.isWorking)
                        }
                        Button(L("Сохранить"), action: commitManual)
                            .disabled(urlDraft == s.serverURL && passwordDraft == s.serverPassword)
                    }
                    .fixedSize()
                } label: {
                    Text(L("Синхронизация"))
                    // The sync status may wrap; orange when the last check failed.
                    HStack(spacing: 5) {
                        if sync.isRunning { ProgressView().controlSize(.mini) }
                        Text(syncStatus).foregroundStyle(sync.failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text(L("Свой адрес"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsFooter(L("Сервер в твоём аккаунте Cloudflare: звонки не попадают к нам, удалить всё можно в любой момент. Текст звонков уходит всегда, звук и отпечатки голосов, только если включено ниже. Согласие собеседников на запись на тебе."))
                    Link(L("Как это устроено"), destination: OwnServer.docsURL)
                        .font(.footnote)
                        .pointerStyle(.link)
                }
            }

            Section {
                LabeledContent(L("Расшифровки, саммари и заметки")) { Text(L("Всегда")) }
                Toggle(L("Аудио звонков"), isOn: $s.syncAudio)
                Toggle(L("Отпечатки голосов"), isOn: $s.syncVoices)
            } header: {
                Text(L("Что отправляется"))
            } footer: {
                if ready {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsCaution(L("Звук звонков с голосами собеседников будет храниться в твоём аккаунте Cloudflare: за него и за согласие тех, кого ты записываешь, отвечаешь ты. Бесплатного хранилища хватит примерно на 80 часов звонков, дальше уходит только текст. Если выключить, новые записи перестанут отправляться."))
                        SettingsCaution(L("Отпечатки голосов относятся к биометрическим данным. Когда включено, они хранятся в твоём аккаунте Cloudflare, и отвечаешь за них ты. Если выключить, они останутся только на этом Mac, а уже отправленные пробудут на сервере, пока их не удалить."))
                    }
                } else {
                    SettingsFooter(L("Станет доступно после подключения сервера."))
                }
            }
            .disabled(!ready)
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(get: { !cloudflare.accounts.isEmpty }, set: { if !$0 { cloudflare.choose(nil) } })) {
            AccountPicker(accounts: cloudflare.accounts) { cloudflare.choose($0) }
        }
        // Connect Cloudflare (or another window) changed them: show the saved values.
        .onChange(of: s.serverURL) { urlDraft = s.serverURL }
        .onChange(of: s.serverPassword) { passwordDraft = s.serverPassword }
        .onChange(of: s.syncAudio) { _, on in s.save(); if on { sync.sync() } }
        .onChange(of: s.syncVoices) { _, on in s.save(); if on { sync.sync() } }
        .task { await sync.refresh() }
    }

    private var syncStatus: String {
        if !sync.status.isEmpty { return sync.status }
        return s.hasServer ? L("Настроен") : L("Не настроена")
    }

    /// Enter or "Save" in the manual fields: save both, then one check of the server and the password.
    /// Spaces and line breaks around a pasted address or password are dropped: the server would refuse them.
    private func commitManual() {
        urlDraft = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        passwordDraft = passwordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard urlDraft != s.serverURL || passwordDraft != s.serverPassword else { return }
        s.serverURL = urlDraft
        s.serverPassword = passwordDraft
        s.save()
        sync.settingsChanged()
    }

    /// The pane's lead row: what the own server is, like the top of a System Settings pane.
    private var intro: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Свой сервер, свои данные")).font(.headline)
                Text(L("Копии готовых звонков уходят на сервер в твоём аккаунте Cloudflare: так Claude и ChatGPT видят их и с телефона. У нас ничего не хранится."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// "Connect Cloudflare", its progress and errors, under the intro.
    @ViewBuilder private var connect: some View {
        switch cloudflare.phase {
        case .working(let step):
            LabeledContent {
                Button(L("Отменить")) { cloudflare.cancel() }
            } label: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step)
                }
            }
        case .failed(let message):
            LabeledContent {
                Button(L("Попробовать ещё раз")) { cloudflare.start() }
            } label: {
                Text(message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        case .idle, .done:
            // A build without the bundled server has no one-click setup: only "Own address" is left.
            if !s.hasServer && cloudflare.isAvailable {
                LabeledContent {
                    Button(L("Подключить Cloudflare")) { cloudflare.start() }
                        .buttonStyle(.borderedProminent)
                } label: {
                    Text(verbatim: "Cloudflare")
                    Text(L("Бесплатный тариф, мы не видим твоих данных"))
                }
            } else if cloudflare.canUpdate(serverVersion: sync.serverVersion) {
                LabeledContent {
                    Button(L("Обновить сервер")) { cloudflare.start() }
                } label: {
                    Text(L("Есть новая версия сервера: %@", cloudflare.bundle?.manifest.version ?? ""))
                }
            }
        }
    }

    /// Connector address, password and the buttons for Claude and ChatGPT.
    @ViewBuilder private func connected(_ mcp: URL) -> some View {
        LabeledContent(L("Адрес коннектора")) {
            HStack(spacing: 6) {
                Text(mcp.absoluteString).monospaced()
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                copyButton(mcp.absoluteString, help: L("Скопировать адрес для коннектора"))
            }
        }
        LabeledContent(L("Пароль")) {
            HStack(spacing: 6) {
                Text(verbatim: showPassword ? s.serverPassword : String(repeating: "•", count: 12))  // l10n-ignore
                    .monospaced()
                    .textSelection(.enabled).lineLimit(1)
                eye
                copyButton(s.serverPassword, help: L("Скопировать пароль"))
            }
        }
        LabeledContent(L("Подключить в приложении")) {
            HStack(spacing: 8) {
                Button(L("Открыть Claude")) {
                    put(mcp.absoluteString)
                    copied = mcp.absoluteString
                    claudeHint = true
                    NSWorkspace.shared.open(OwnServer.claudeConnectorsURL)
                }
                Button(L("Открыть ChatGPT")) { NSWorkspace.shared.open(OwnServer.chatGPTConnectorsURL) }
            }
        }
    }

    private var eye: some View {
        SZSmallIconButton(showPassword ? "eye.slash" : "eye",
                          label: showPassword ? L("Скрыть пароль") : L("Показать пароль")) { showPassword.toggle() }
    }

    private func copyButton(_ text: String, help: String) -> some View {
        SZSmallIconButton(copied == text && !text.isEmpty ? "checkmark" : "doc.on.doc", label: help) {
            put(text)
            copied = text
        }
    }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == text { copied = nil } }
    }
}

/// Several Cloudflare accounts were allowed: which one gets the server.
private struct AccountPicker: View {
    let accounts: [CloudflareAPI.Account]
    let done: (CloudflareAPI.Account?) -> Void
    @State private var selection: CloudflareAPI.Account?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("В какой аккаунт Cloudflare поставить сервер?")).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Picker(L("Аккаунт"), selection: $selection) {
                ForEach(accounts) { Text($0.name).tag(Optional($0)) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            HStack {
                Spacer()
                Button(L("Отменить")) { done(nil) }.keyboardShortcut(.cancelAction)
                Button(L("Продолжить")) { done(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { selection = accounts.first }
    }
}
