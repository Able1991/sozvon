// Projects: list and editor (profiles/<slug>.json).

import AppKit
import SozvonCore
import SwiftUI

struct ProjectEditor: View {
    @State var project: Project
    let done: (Project?) -> Void
    @State private var people = ""
    @State private var terms = ""
    @State private var deletingVoice: VoiceRecord?
    @State private var voiceProblem: String?
    @ObservedObject private var voices = VoiceStore.shared
    /// The sheet's title: the name the project had when it opened, not the one being typed.
    private let heading: String
    /// The other projects, for the duplicate name check.
    private let others: [Project]

    init(project: Project, done: @escaping (Project?) -> Void) {
        _project = State(initialValue: project)
        self.done = done
        heading = project.slug.isEmpty ? L("Новый проект") : project.title
        others = Project.all().filter { $0.slug != project.slug }
    }

    /// One language, or Russian and English together: what a project's calls usually are.
    private static let languageChoices = ["ru", "en", "ru,en", "uk", "de", "es"]

    private var titleProblem: Project.TitleProblem? {
        Project.titleProblem(project.title, slug: project.slug, among: others)
    }

    /// Voice prints saved for this project's people.
    private var projectVoices: [VoiceRecord] {
        isNew ? [] : voices.records.filter { !$0.me && $0.profile == project.slug }
    }

    private var isNew: Bool { project.slug.isEmpty }

    var body: some View {
        SZWFormSheet(heading, width: 520, columns: true) {
            TextField(L("Название") + ":", text: $project.title, prompt: Text("Acme Corp"))
            if titleProblem == .duplicate {
                Label(L("Проект с таким названием уже есть"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            TextField(L("О чём созвоны") + ":", text: $project.context, prompt: Text(L("Инфраструктура видеоплатформы")),
                      axis: .vertical)
                .lineLimit(2...3)
            TextField(L("Люди") + ":", text: $people, prompt: Text(L("Анна Петрова, Иван")), axis: .vertical)
                .lineLimit(2...4)
            TextField(L("Термины") + ":", text: $terms, prompt: Text(L("Kubernetes, HPA, стримкодер")), axis: .vertical)
                .lineLimit(2...5)
            Text(L("Через запятую. Самое важное первым: в подсказку Whisper влезает около 25 слов."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The call window takes it when the project is picked; the model for it follows (Settings → Recognition).
            Picker(L("Язык звонков") + ":", selection: Binding(
                get: { SpeechLanguage.serialize(project.languages) == "auto" ? "" : SpeechLanguage.serialize(project.languages) },
                set: { project.languages = SpeechLanguage.parse($0) })) {
                Text(L("Как в настройках")).tag("")
                Divider()
                ForEach(Self.languageChoices, id: \.self) { v in
                    Text(SpeechLanguage.summary(SpeechLanguage.parse(v))).tag(v)
                }
            }
            .fixedSize()
            if !projectVoices.isEmpty {
                LabeledContent(L("Голоса") + ":") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(projectVoices) { v in
                            HStack(spacing: 6) {
                                Label(v.name, systemImage: "waveform.circle").help(L("Голос сохранён"))
                                Spacer(minLength: 8)
                                Button(role: .destructive) { deletingVoice = v } label: {
                                    Label(L("Удалить голос"), systemImage: "trash")
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help(L("Удалить голос"))
                                .disabled(voices.isBusy)
                            }
                            .contextMenu {
                                Button(L("Удалить голос…"), role: .destructive) { deletingVoice = v }
                            }
                        }
                        if let voiceProblem { SettingsWarning(voiceProblem).font(.caption) }
                        Text(L("Sozvon узнаёт этих людей по голосу в звонках проекта. Голос сохраняется, когда ты точно называешь собеседника в расшифровке."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } actions: {
            Button(L("Отмена")) { done(nil) }.keyboardShortcut(.cancelAction)
            Button(L("Сохранить")) {
                var p = project
                p.title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
                p.context = p.context.trimmingCharacters(in: .whitespacesAndNewlines)
                if p.slug.isEmpty { p.slug = Project.uniqueSlug(for: p.title) }
                p.people = splitList(people)
                p.terms = splitList(terms)
                do {
                    try p.save()
                } catch {
                    let a = NSAlert()
                    a.messageText = L("Не получилось сохранить проект")
                    a.informativeText = error.localizedDescription
                    a.runModal()
                    return
                }
                done(p)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(titleProblem != nil)
        }
        .alert(L("Удалить голос «%@»?", deletingVoice?.name ?? ""), isPresented: Binding(
            get: { deletingVoice != nil }, set: { if !$0 { deletingVoice = nil } }
        ), presenting: deletingVoice) { v in
            Button(L("Удалить"), role: .destructive) {
                Task {
                    let outcome = await voices.delete(v)
                    voiceProblem = outcome.isOK ? nil : (outcome.message.isEmpty ? L("Не получилось удалить голос") : outcome.message)
                }
            }
            Button(L("Отмена"), role: .cancel) {}
        } message: { _ in
            Text(L("Sozvon перестанет узнавать этого человека по голосу. Голос снова сохранится, когда ты подпишешь его в расшифровке."))
        }
        .onAppear {
            voices.refresh()
            people = project.people.joined(separator: ", ")
            terms = project.terms.joined(separator: ", ")
        }
    }
}

struct ProjectsView: View {
    @State private var projects = Project.all()
    @State private var selection: Project.ID?
    @State private var editing: Project? = nil
    @State private var deleting: Project? = nil
    @State private var watcher: DirectoryWatcher?
    @State private var callsWatcher: DirectoryWatcher?
    /// Bumped on calls folder events: the call counts are recounted.
    @State private var callsVersion = 0
    /// Calls per project slug, read once in the background.
    @State private var callCounts: [String: Int] = [:]
    @ObservedObject private var discovery = ProjectDiscovery.shared
    @FocusState private var listFocused: Bool
    /// Observed, not read once: the assistant picked in Settings shows up in an open window.
    @ObservedObject private var settings = Settings.shared
    private var assistant: Assistant { settings.assistant }

    private var selected: Project? { projects.first { $0.id == selection } }

    /// "3 проекта · 10 человек": projects and distinct people across them.
    private var summary: String {
        let people = Set(projects.flatMap { $0.people.map { $0.lowercased() } }).count
        // l10n-ignore-start: plural forms are chosen in SZW.count
        return SZW.count(projects.count, ru: ("проект", "проекта", "проектов"), en: ("project", "projects"))
            + " · " + SZW.count(people, ru: ("человек", "человека", "человек"), en: ("person", "people"))
        // l10n-ignore-end
    }

    var body: some View {
        list
            // Wide enough for the title, "Find with Claude Code" and "+" side by side: narrower, macOS 26 tucks
            // "New Project" into the toolbar's overflow menu.
            .frame(minWidth: 640, minHeight: 300)
            .navigationTitle(L("Проекты"))
            .navigationSubtitle(projects.isEmpty ? "" : summary)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { discoverBar }
            .onChange(of: discovery.isRunning) { _, running in if !running { projects = Project.all() } }
            // The list picks up changes to the projects folder by itself (search, manual edits, other windows).
            .onAppear {
                let w = DirectoryWatcher(Paths.profiles) {
                    let fresh = Project.all()
                    if fresh != projects { projects = fresh }
                }
                w.start()
                watcher = w
                let cw = DirectoryWatcher(Paths.calls) { callsVersion += 1 }
                cw.start()
                callsWatcher = cw
                listFocused = true
            }
            .onDisappear {
                watcher?.stop()
                watcher = nil
                callsWatcher?.stop()
                callsWatcher = nil
            }
            // Recounted when the projects reload (a new or renamed project) or a call changes.
            .task(id: [projects.map(\.slug).joined(separator: "\n"), String(callsVersion)]) {
                let calls = await Task.detached(priority: .utility) { Call.all() }.value
                guard !Task.isCancelled else { return }
                callCounts = calls.reduce(into: [:]) { d, c in if !c.info.profile.isEmpty { d[c.info.profile, default: 0] += 1 } }
            }
            .onChange(of: projects) { _, list in
                if let s = selection, !list.contains(where: { $0.id == s }) { selection = nil }
            }
            .sheet(item: $editing) { p in
                ProjectEditor(project: p) { saved in
                    editing = nil
                    projects = Project.all()
                    if let saved { selection = saved.id }
                }
            }
            .alert(L("Удалить проект «%@»?", deleting?.title ?? ""), isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ), presenting: deleting) { p in
                Button(L("Удалить"), role: .destructive) { delete(p) }
                Button(L("Отмена"), role: .cancel) {}
            } message: { _ in
                Text(L("Звонки сохранят свои расшифровки. Уйдут только люди, термины и замены этого проекта. Файл попадёт в Корзину, его можно вернуть."))
            }
    }

    /// A native list: click selects, double-click or Return opens the editor, Delete asks to remove; the context
    /// menu acts on the clicked row (or, on the empty area, offers a new project).
    private var list: some View {
        List(selection: $selection) {
            ForEach(projects) { p in row(p).tag(p.id) }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .focused($listFocused)
        .contextMenu(forSelectionType: Project.ID.self) { ids in
            if let id = ids.first, let p = projects.first(where: { $0.id == id }) {
                rowMenu(p)
            } else {
                Button(L("Новый проект…")) { editing = Project(slug: "", title: "") }
                Button(L("Показать в Finder")) { NSWorkspace.shared.open(Paths.profiles) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let p = projects.first(where: { $0.id == id }) { editing = p }
        }
        .onDeleteCommand { deleting = selected }
        .overlay {
            if projects.isEmpty && !discovery.isRunning {
                ContentUnavailableView {
                    Label(L("Проектов пока нет"), systemImage: "folder")
                } description: {
                    Text(L("Проект это команда и её слова: имена, продукты, термины. С ними расшифровка точнее, а саммари знает, о ком речь."))
                } actions: {
                    Button(L("Новый проект…")) { editing = Project(slug: "", title: "") }
                }
            }
        }
        .accessibilityLabel(L("Проекты"))
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if assistant != .none {
            ToolbarItem(placement: .primaryAction) {
                Button { discovery.start() } label: {
                    Label(L("Найти через %@", assistant.title), systemImage: "sparkle.magnifyingglass")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(discovery.isRunning)
                .help(L("Найти через %@", assistant.title))
            }
        }
        if #available(macOS 26.0, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
        ToolbarItem(placement: .primaryAction) {
            Button { editing = Project(slug: "", title: "") } label: { Label(L("Новый проект"), systemImage: "plus") }
                .help(L("Новый проект"))
        }
    }

    /// Project search under the list: progress with "Stop", then its result.
    @ViewBuilder private var discoverBar: some View {
        if discovery.isRunning || !discovery.result.isEmpty {
            VStack(spacing: 0) {
                Divider()
                Group {
                    if discovery.isRunning {
                        ProjectDiscoveryProgress(discovery: discovery)
                    } else {
                        Label { Text(discovery.result) } icon: { ProjectDiscoveryIcon(outcome: discovery.outcome) }
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .background(.bar)
        }
    }

    private func row(_ p: Project) -> some View {
        // l10n-ignore-start: plural forms are chosen in SZW.count
        var parts = [SZW.count(p.people.count, ru: ("человек", "человека", "человек"), en: ("person", "people")),
                     SZW.count(p.terms.count, ru: ("термин", "термина", "терминов"), en: ("term", "terms"))]
        // l10n-ignore-end
        if let n = callCounts[p.slug] { parts.append(OwnServer.callsCount(n, language: Engine.uiLanguage)) }
        return HStack(spacing: 10) {
            SZWDot.view(SZW.projectColor(p.shortTitle), size: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title).font(.body.weight(.medium))
                Text(parts.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: L("Изменить…")) { editing = p }
    }

    @ViewBuilder private func rowMenu(_ p: Project) -> some View {
        Button(L("Изменить…")) { editing = p }
        Button(L("Показать в Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([Paths.profiles.appendingPathComponent("\(p.slug).json")])
        }
        Divider()
        Button(L("Удалить…"), role: .destructive) { deleting = p }
    }

    private func delete(_ p: Project) {
        do {
            try Project.delete(p.slug)
        } catch {
            let a = NSAlert()
            a.messageText = L("Не получилось удалить проект")
            a.informativeText = error.localizedDescription
            a.runModal()
        }
        projects = Project.all()
    }
}
