// Projects: list and editor (profiles/<slug>.json).

import AppKit
import SozvonCore
import SwiftUI

struct ProjectEditor: View {
    @State var project: Project
    let done: (Project?) -> Void
    @State private var people = ""
    @State private var terms = ""

    var isNew: Bool { project.slug.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(L("Название"), text: $project.title, prompt: Text("Acme Corp"))
                    TextField(L("О чём созвоны"), text: $project.context, prompt: Text(L("Инфраструктура видеоплатформы")), axis: .vertical)
                        .lineLimit(2...3)
                } header: {
                    Text(isNew ? L("Новый проект") : project.title).font(.headline).foregroundStyle(.primary)
                }
                Section {
                    TextField(L("Люди"), text: $people, prompt: Text(L("Анна Петрова, Иван")), axis: .vertical).lineLimit(2...4)
                    TextField(L("Термины"), text: $terms, prompt: Text(L("Kubernetes, HPA, стримкодер")), axis: .vertical).lineLimit(2...5)
                } footer: {
                    Text(L("Через запятую. Самое важное первым: в подсказку Whisper влезает около 25 слов."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button(L("Отмена")) { done(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Сохранить")) {
                    var p = project
                    if p.slug.isEmpty { p.slug = Project.uniqueSlug(for: p.title) }
                    p.people = splitList(people)
                    p.terms = splitList(terms)
                    p.save()
                    done(p)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(project.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440, height: 430)
        .onAppear {
            people = project.people.joined(separator: ", ")
            terms = project.terms.joined(separator: ", ")
        }
    }
}

struct ProjectsView: View {
    @State private var projects = Project.all()
    @State private var editing: Project? = nil
    @State private var watcher: DirectoryWatcher?
    @StateObject private var m = SetupModel()
    private let assistant = Settings.shared.assistant

    var body: some View {
        VStack(spacing: 0) {
            List {
                if projects.isEmpty {
                    Text(L("Проектов пока нет")).foregroundStyle(.secondary)
                }
                ForEach(projects) { p in
                    Button { editing = p } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title)
                                Text(L("%@ чел. · %@ терм.", p.people.count, p.terms.count)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            if m.discovering {
                DiscoverProgress(m: m).padding(.horizontal, 16).padding(.top, 10)
            } else if !m.discoverResult.isEmpty {
                HStack {
                    Label(m.discoverResult, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 20).padding(.top, 10)
            }
            HStack {
                Button { editing = Project(slug: "", title: "") } label: { Label(L("Новый"), systemImage: "plus") }
                if assistant != .none {
                    Button { m.discover() } label: { Label(L("Найти через %@", assistant.title), systemImage: "magnifyingglass") }
                        .disabled(m.discovering)
                }
                Spacer()
                Button(L("Папка")) { NSWorkspace.shared.open(Paths.profiles) }
            }
            .padding(16)
        }
        .frame(height: 420)
        .onChange(of: m.discovering) { _, d in if !d { projects = Project.all() } }
        // The list picks up changes to the projects folder by itself (search, manual edits, other windows).
        .onAppear {
            let w = DirectoryWatcher(Paths.profiles) {
                let fresh = Project.all()
                if fresh != projects { projects = fresh }
            }
            w.start()
            watcher = w
        }
        .onDisappear {
            watcher?.stop()
            watcher = nil
        }
        .sheet(item: $editing) { p in
            ProjectEditor(project: p) { _ in
                editing = nil
                projects = Project.all()
            }
        }
    }
}
