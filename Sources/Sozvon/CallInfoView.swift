// Окно «О чём был звонок»: проект, тема, собеседники, термины, язык, саммари.

import AppKit
import SozvonCore
import SwiftUI

struct CallInfoView: View {
    static let newTag = "__new_project__"
    @State var info: CallInfo
    let title: String
    let okTitle: String
    let done: (CallInfo?) -> Void
    @State private var projects = Project.all()
    /// Прошлые звонки: из них подсказки собеседников. Читаются один раз при открытии окна, в фоне и без размеров папок.
    @State private var pastCalls: [Call] = []
    @State private var newProject: Project? = nil
    private let assistant = Settings.shared.assistant

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker(L("Проект"), selection: $info.profile) {
                        Text(L("Без проекта")).tag("")
                        ForEach(projects) { p in Text(p.title).tag(p.slug) }
                        Divider()
                        Text(L("Новый проект…")).tag(CallInfoView.newTag)
                    }
                    .onChange(of: info.profile) { old, new in
                        if new == CallInfoView.newTag {
                            info.profile = old
                            newProject = Project(slug: "", title: "")
                        }
                    }
                } header: {
                    Text(title).font(.headline).foregroundStyle(.primary).padding(.bottom, 4)
                }
                Section {
                    TextField(L("Тема"), text: $info.topic, prompt: Text(L("запуск рекламной кампании")))
                    TextField(L("Собеседники"), text: $info.names, prompt: Text(L("Анна, Иван")))
                    let known = knownPeople(info.profile, calls: pastCalls, projects: projects, me: Settings.shared.name)
                    if !known.isEmpty {
                        PeopleChips(people: known, names: $info.names)
                    }
                    TextField(L("Ключевые слова"), text: $info.terms, prompt: Text(L("HPA, стримкодер")))
                    LanguagesPicker(title: L("Язык"), selection: $info.languages)
                } footer: {
                    Text(L("Собеседников без себя, через запятую, по порядку, кто заговорит первым. Всё можно оставить пустым."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle(isOn: $info.summary) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Саммари"))
                            Text(assistant == .none ? L("Помощник не выбран в настройках")
                                 : L("Через %@, текст уйдёт в %@", assistant.title, assistant.vendor))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(assistant == .none)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Button(L("Не расшифровывать")) { done(nil) }
                Spacer()
                Button(okTitle) { done(info) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(minHeight: 510)
        .onAppear {
            if assistant == .none { info.summary = false }
        }
        .task { pastCalls = await Task.detached(priority: .userInitiated) { Call.all() }.value }
        .sheet(item: $newProject) { p in
            ProjectEditor(project: p) { saved in
                newProject = nil
                if let saved {
                    projects = Project.all()
                    info.profile = saved.slug
                }
            }
        }
    }
}

/// Окно «О чём был звонок» как ожидание ответа. Одно окно за раз: предыдущее
/// («Проект и собеседники» во время записи) закрывается, его ожидание завершается без изменений.
@MainActor
enum CallInfoPrompt {
    static let key = "callinfo"

    static var isOpen: Bool { WindowsRegistry.shared.window(key) != nil }

    static func bringToFront() { WindowsRegistry.shared.window(key)?.makeKeyAndOrderFront(nil) }

    /// Ответ или nil («Не расшифровывать», закрыли окно, открыли другое).
    static func ask(_ initial: CallInfo, title: String, okTitle: String) async -> CallInfo? {
        WindowsRegistry.shared.close(key)
        return await withCheckedContinuation { cont in
            var resumed = false
            let finish: (CallInfo?) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: result)
                WindowsRegistry.shared.close(key)
            }
            let spec = WindowSpec.hosting(key, width: 460, level: .floating) {
                CallInfoView(info: initial, title: title, okTitle: okTitle, done: finish)
            }
            WindowsRegistry.shared.show(spec, onClose: { finish(nil) })
        }
    }
}
