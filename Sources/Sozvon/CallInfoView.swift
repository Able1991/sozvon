// "What was the call about" window: project, topic, participants, terms, language, summary.
// After a recording it can be put off ("Later"): the call waits for its description (call.json info_pending).

import AppKit
import SozvonCore
import SwiftUI

/// How the "What was the call about" window was answered.
enum CallInfoAnswer {
    case transcribe(CallInfo)
    /// "Later": keep the answers typed so far (nil: the window was closed, keep what call.json has).
    case later(CallInfo?)
    /// "Don't Transcribe", or a cancelled edit.
    case cancel
}

struct CallInfoView: View {
    @State var info: CallInfo
    let title: String
    let okTitle: String
    /// Offer "Later" as the main secondary action ("Don't Transcribe" stays, quieter).
    var allowLater = false
    /// Seconds until the form goes ahead by itself (the project and the people are known); editing stops it.
    @State var countdown: Int? = nil
    let done: (CallInfoAnswer) -> Void
    @State private var projects = Project.all()
    /// Past calls, used to suggest participants. Read once when
    /// the window opens, in the background, without folder sizes.
    @State private var pastCalls: [Call] = []
    @State private var newProject: Project? = nil
    private let assistant = Settings.shared.assistant

    private var project: Project? { projects.first { $0.slug == info.profile } }

    /// The project menu's "New Project…" item: a tag no project slug can have.
    private static let newProjectTag = "\u{0}new"

    var body: some View {
        SZWFormSheet(title, subtitle: countdown.map { L("Проект и участники определились сами. Расшифрую через %@ с, если ничего не менять.", $0) }
                     ?? L("Тема и имена помогут расшифровке и саммари."), width: 580, columns: true) {
            Picker(L("Что это") + ":", selection: $info.reflection) {
                Text(L("Звонок")).tag(false)
                Text(L("Размышления")).tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            projectPicker
            TextField(L("Тема") + ":", text: $info.topic, prompt: Text(L("О чём говорили, двумя словами")))
            participants
            TextField(L("Ключевые слова") + ":", text: $info.terms, prompt: Text(L("HMAC, invoice.paid, песочница")))
                .help(L("Названия, термины, имена"))
            LabeledContent(L("Язык") + ":") { SZWLanguagesPopup(title: L("Язык"), selection: $info.languages) }
            LabeledContent(L("Саммари") + ":") {
                Toggle(isOn: $info.summary) {
                    Text(assistant == .none ? L("Помощник не выбран в настройках")
                         : L("Через %@, текст уйдёт в %@", assistant.title, assistant.vendor))
                }
                .toggleStyle(.checkbox)
                .disabled(assistant == .none)
            }
        } actions: {
            if allowLater {
                Button(L("Позже")) { done(.later(info)) }
                    .keyboardShortcut(.cancelAction)
                    .help(L("Закрыть и вернуться к звонку потом: меню Sozvon → «Ждут описания»"))
            }
            if countdown != nil {
                Button(L("Подождать")) { countdown = nil }
                    .help(L("Не расшифровывать сразу, сначала проверю"))
            }
            Button(countdown.map { "\(okTitle) (\($0))" } ?? okTitle) { done(.transcribe(info)) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } leading: {
            Button(L("Не расшифровывать")) { done(.cancel) }
                .keyboardShortcut(allowLater ? nil : .cancelAction)
                .help(L("Оставить запись без расшифровки"))
        }
        .onAppear {
            if assistant == .none { info.summary = false }
        }
        .task { pastCalls = await Task.detached(priority: .userInitiated) { Call.all() }.value }
        .task {
            while let n = countdown {
                if n <= 0 { done(.transcribe(info)); return }
                try? await Task.sleep(for: .seconds(1))
                if let c = countdown { countdown = c - 1 }
            }
        }
        .onChange(of: info) { old, new in
            var before = old
            if assistant == .none { before.summary = new.summary }  // set by onAppear, not by the user
            if before != new { countdown = nil }
        }
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

    /// A system pop-up menu: "No Project", the projects with their color dots, and "New Project…" that opens the editor.
    private var projectPicker: some View {
        Picker(L("Проект") + ":", selection: Binding(
            get: { info.profile },
            set: { v in
                if v == Self.newProjectTag { newProject = Project(slug: "", title: "") } else { info.profile = v }
            }
        )) {
            Text(L("Без проекта")).tag("")
            // A call may name a project whose file is gone: keep it selectable so the picker shows it.
            if !info.profile.isEmpty && project == nil { Text(info.profile).tag(info.profile) }
            if !projects.isEmpty { Divider() }
            ForEach(projects) { p in
                Label { Text(p.title) } icon: { SZWDot.image(SZW.projectColor(p.shortTitle)) }.tag(p.slug)
            }
            Divider()
            Text(L("Новый проект…")).tag(Self.newProjectTag)
        }
        .accessibilityValue(project?.title ?? L("Без проекта"))
    }

    /// Participants: the field, then the people seen in past calls of this project as suggestions
    /// (a checkmark: already in the field).
    @ViewBuilder private var participants: some View {
        let known = knownPeople(info.profile, calls: pastCalls, projects: projects, me: Settings.shared.name)
        TextField(L("Собеседники") + ":", text: $info.names, prompt: Text(L("Анна, Иван")))
        Text(L("Собеседников без себя, через запятую, по порядку, кто заговорит первым. Всё можно оставить пустым."))
            .font(.caption).foregroundStyle(.secondary)
            .frame(width: 340, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        if !known.isEmpty {
            LabeledContent {
                FlowLayout(spacing: 6) {
                    ForEach(known, id: \.self) { p in
                        let on = splitList(info.names).contains(p)
                        SZWSuggestion(title: p, on: on) {
                            var list = splitList(info.names)
                            if on { list.removeAll { $0 == p } } else { list.append(p) }
                            info.names = list.joined(separator: ", ")
                        }
                        .help(on ? L("Убрать из собеседников") : L("Добавить в собеседники"))
                    }
                }
                .frame(width: 340, alignment: .leading)
                .animation(.easeOut(duration: 0.15), value: info.names)
            } label: {
                Text(L("Похоже, это:"))
            }
            .help(project.map { L("из проекта %@", $0.shortTitle) } ?? "")
        }
    }
}

/// Shows the "What was the call about" window and awaits the answer. One window at a time: the previous one
/// ("Project and Participants" during recording) is closed and its wait ends with no changes.
@MainActor
enum CallInfoPrompt {
    static let key = "callinfo"

    static var isOpen: Bool { WindowsRegistry.shared.window(key) != nil }

    static func bringToFront() { WindowsRegistry.shared.window(key)?.makeKeyAndOrderFront(nil) }

    /// The answer, or nil ("Don't Transcribe", window closed, another window opened).
    static func ask(_ initial: CallInfo, title: String, okTitle: String) async -> CallInfo? {
        if case .transcribe(let info) = await answer(initial, title: title, okTitle: okTitle, allowLater: false) {
            return info
        }
        return nil
    }

    /// With `allowLater`, closing the window (or another window replacing it) means "Later", not "Don't Transcribe":
    /// a recorded call is never silently left without a way back.
    static func answer(_ initial: CallInfo, title: String, okTitle: String, allowLater: Bool,
                       countdown: Int? = nil) async -> CallInfoAnswer {
        WindowsRegistry.shared.close(key)
        return await withCheckedContinuation { cont in
            var resumed = false
            let finish: (CallInfoAnswer) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: result)
                WindowsRegistry.shared.close(key)
            }
            // The question is the window's heading (CallInfo design); the title stays for the Window menu and VoiceOver.
            let spec = WindowSpec.hosting(key, title: title, width: 580, transparentTitle: true, level: .floating) {
                CallInfoView(info: initial, title: title, okTitle: okTitle, allowLater: allowLater, countdown: countdown, done: finish)
            }
            let w = WindowsRegistry.shared.show(spec, onClose: { finish(allowLater ? .later(nil) : .cancel) })
            w.titleVisibility = .hidden
        }
    }
}
