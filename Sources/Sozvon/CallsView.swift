// "Calls" window: recordings grouped by day (like Voice Memos) and a call card
// with the summary, transcript and actions.

import AppKit
import SozvonCore
import SwiftUI

/// A sidebar row: bold title and start time, then a quiet line: the project and duration, or the
/// call's state (recording, transcribing, waiting for a description, not transcribed).
struct CallRow: View {
    let call: Call
    var processing = false
    var queued = false
    var recording = false
    var importing = false
    /// The List draws the selected row on an accent background: state colors turn white on it.
    @Environment(\.backgroundProminence) private var prominence
    private var selected: Bool { prominence == .increased }

    /// Duration for the row: "<1 min", "14 min", "1 h 05 min"; empty for zero.
    static func minutes(_ seconds: TimeInterval) -> String {
        let t = Int(seconds.rounded())
        guard t > 0 else { return "" }
        if t < 60 { return L("<1 мин") }
        let m = t / 60
        if m < 60 { return L("%@ мин", m) }
        return L("%@ ч %@ мин", m / 60, String(format: "%02d", m % 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(call.title).szFont(.bodySemibold).lineLimit(1)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let d = call.date {
                    Text(d, format: .dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            subtitle
                .szFont(.small).lineLimit(1)
                .foregroundStyle(.secondary)
                .help(call.people)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var duration: String { Self.minutes(call.duration) }

    /// "Project · 22 min" with its dot, or the call's state first.
    @ViewBuilder private var subtitle: some View {
        HStack(spacing: 5) {
            if recording {
                Circle().fill(SZ.red).frame(width: 7, height: 7)
                    .shadow(color: SZ.red, radius: 3)
                    .padding(.trailing, 3)
                Text(L("Идёт запись")).fontWeight(.medium).foregroundStyle(selected ? Color.white : SZ.red)
            } else if importing {
                Text(L("Импортируется…"))
            } else if processing {
                ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 12, height: 12)
                Text(L("Расшифровывается…"))
                dotted(duration)
            } else if queued {
                Image(systemName: "clock").font(.system(size: 9))
                    .foregroundStyle(selected ? Color.white : SZ.label3)
                Text(L("В очереди"))
                dotted(duration)
            } else if call.infoPending {
                SZBadge(L("Ждёт описания"))
                    .help(L("Нажми «Расшифровать…», чтобы описать звонок"))
                dotted(duration)
            } else if call.status == .failed && !call.hasTranscript {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                    .foregroundStyle(selected ? Color.white : SZ.orange)
                Text(L("Не получилось расшифровать"))
                dotted(duration)
            } else if !call.hasTranscript && !call.hasSummary {
                Image(systemName: "waveform.slash").font(.system(size: 9))
                    .foregroundStyle(selected ? Color.white : SZ.label3)
                Text(L("Без расшифровки"))
                dotted(duration)
            } else {
                let lead = call.project.isEmpty || call.project == call.title
                    ? shortPeople(splitList(call.people)) : call.project
                if !call.project.isEmpty {
                    SZWDot.view(selected ? .white : SZW.projectColor(call.project), size: 6)
                }
                if call.info.reflection {
                    Image(systemName: "brain").font(.system(size: 9))
                        .foregroundStyle(selected ? Color.white : SZ.label3)
                        .accessibilityHidden(true)
                    Text(L("Размышления"))
                }
                if !lead.isEmpty { Text(lead) }
                if lead.isEmpty && !call.info.reflection { Text(duration.isEmpty ? " " : duration) } else { dotted(duration) }
                if call.isDemo { SZBadge(L("Демо")) }
                if let why = call.summaryWarning {
                    SZBadge(L("Без саммари"))
                        .help(why.isEmpty ? L("Саммари не получилось. Подробности в process.log") : why)
                }
            }
        }
    }

    @ViewBuilder private func dotted(_ s: String) -> some View {
        if !s.isEmpty {
            Text(verbatim: "·")
            Text(s)
        }
    }
}

struct CallsView: View {
    @ObservedObject var m: CallsModel
    /// Summary (0) or transcript (1): the user's choice, kept across selections and launches.
    @AppStorage("callsTab") private var tab = 0
    @Environment(\.undoManager) private var undo

    init(m: CallsModel) {
        _m = ObservedObject(wrappedValue: m)
        #if SOZVON_PREVIEW
        // Screenshots pick the tab explicitly, whatever was chosen last time.
        UserDefaults.standard.set(CommandLine.arguments.contains("--transcript") ? 1 : 0, forKey: "callsTab")
        #endif
    }

    /// The chosen tab, or the other one when this call doesn't have it.
    static func shown(_ tab: Int, for c: Call) -> Int {
        if tab == 0 && !c.hasSummary { return 1 }
        if tab == 1 && !c.hasTranscript { return 0 }
        return tab
    }

    private func shownTab(for c: Call) -> Binding<Int> {
        Binding(get: {
            Self.shown(tab, for: c)
        }, set: { tab = $0 })
    }

    var body: some View {
        NavigationSplitView {
            CallsSidebar(m: m)
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SZ.windowBg)
        }
        .navigationTitle(L("Звонки"))
        .frame(minWidth: 820, minHeight: 520)
        // Drop an audio or video file anywhere in the window: it becomes a new call.
        .dropDestination(for: URL.self) { urls, _ in m.dropFiles(urls) }
        .onAppear {
            // The first call that is not being recorded (it has nothing to show yet).
            if m.selection == nil { m.selection = (m.firstListed ?? m.calls.first)?.id }
        }
    }

    @ViewBuilder private var detail: some View {
        if let c = m.selected {
            CallDetail(call: c, m: m, tab: shownTab(for: c)).id(c.id)
        } else if m.calls.isEmpty {
            ContentUnavailableView {
                Label(L("Звонков пока нет"), systemImage: "waveform")
            } description: {
                Text(L("Нажми «Записать» на панели или в меню Sozvon. Готовую запись можно перетащить сюда."))
            } actions: {
                Button(L("Импортировать запись…")) { m.chooseImport() }
            }
        } else {
            ContentUnavailableView {
                Label(L("Выбери звонок"), systemImage: "list.bullet.rectangle")
            } description: {
                Text(L("Итоги, расшифровка и запись звонка откроются здесь."))
            }
        }
    }
}

/// The sidebar: search, project filter, the call being recorded under "Now", then calls by day.
struct CallsSidebar: View {
    @ObservedObject var m: CallsModel
    @Environment(\.undoManager) private var undo
    @FocusState private var searching: Bool
    @AppStorage("callsTab") private var callsTab = 0

    var body: some View {
        list
        .searchable(text: $m.search, placement: .sidebar, prompt: L("Поиск по звонкам"))
        .searchFocused($searching)
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker(L("Проект"), selection: $m.projectFilter) {
                        Text(L("Все проекты")).tag("")
                        Text(L("Размышления")).tag(CallsModel.reflectionsFilter)
                        if !m.filterProjects.isEmpty { Divider() }
                        ForEach(m.filterProjects) { p in Text(p.shortTitle).tag(p.slug) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(L("Проект"), systemImage: m.projectFilter.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                              : "line.3.horizontal.decrease.circle.fill")
                }
                .help(L("Показать звонки одного проекта"))
            }
            ToolbarItem {
                Button { m.chooseImport() } label: {
                    Label(L("Импортировать запись…"), systemImage: "square.and.arrow.down")
                }
                .help(L("Импортировать запись…"))
                .disabled(m.importing != nil)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let p = m.importing {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Импорт «%@»", p.name)).szFont(.small).foregroundStyle(SZ.label2).lineLimit(1)
                    ProgressView(value: p.fraction).controlSize(.small).tint(SZ.accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(SZ.bar)
                .overlay(alignment: .top) { Rectangle().fill(SZ.sep).frame(height: 1) }
            }
        }
        .background {
            // ⌘F: inside the transcript on its tab, otherwise the search across calls. ⌥⌘F: always across calls.
            Button(L("Найти в расшифровке")) {
                if let c = m.selected, CallsView.shown(callsTab, for: c) == 1 { m.transcriptFindRequest += 1 } else { searching = true }
            }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
            Button(L("Поиск по звонкам")) { searching = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// The system sidebar list: native selection, keyboard navigation and type-select.
    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $m.selection) {
                if let live = m.live {
                    Section(L("Сейчас")) { row(live) }
                }
                ForEach(m.groups, id: \.0) { group in
                    Section(group.0) { ForEach(group.1) { c in row(c) } }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand { if let c = m.selected { m.trash(c, undo: undo) } }
            .onChange(of: m.selection) { _, id in if let id { proxy.scrollTo(id) } }
            .overlay { empty }
            .safeAreaInset(edge: .bottom, spacing: 0) { filterBar }
        }
    }

    /// Under the list while a project filter is on (as Mail's "Filtered by"): which one, and Clear.
    @ViewBuilder private var filterBar: some View {
        let title = m.projectFilter == CallsModel.reflectionsFilter ? L("Размышления")
            : m.filterProjects.first(where: { $0.slug == m.projectFilter })?.shortTitle
        if let title {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(.tint)
                Text(L("Только «%@»", title)).lineLimit(1)
                Spacer(minLength: 0)
                Button(L("Сбросить")) { m.projectFilter = "" }.buttonStyle(.link)
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
        }
    }

    @ViewBuilder private var empty: some View {
        if m.calls.isEmpty {
            // The detail explains how to get the first call; the sidebar only says there are none.
            Text(L("Нет звонков")).font(.title3).foregroundStyle(.tertiary)
        } else if m.filtered.isEmpty && m.live == nil {
            if m.search.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView(L("В этом проекте звонков нет"), systemImage: "tray")
            } else {
                ContentUnavailableView.search(text: m.search)
            }
        }
    }

    private func row(_ c: Call) -> some View {
        CallRow(call: c, processing: m.isProcessing(c.url), queued: m.isQueued(c.url), recording: m.isRecording(c.url), importing: m.isImporting(c.url))
            .tag(c.id)
            .id(c.id)
        .contextMenu {
            if c.infoPending && c.hasAudio && !m.isBusy(c.url) {
                Button(L("Описать…")) { m.onRetranscribe(c) }
            }
            if c.hasTranscript { Button(L("Открыть расшифровку")) { NSWorkspace.shared.open(c.transcriptURL) } }
            Button(L("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([c.url]) }
            if c.hasAudio && !m.isBusy(c.url) && !c.infoPending {
                Button(c.hasTranscript ? L("Расшифровать заново…") : L("Расшифровать…")) { m.onRetranscribe(c) }
            }
            if m.isQueued(c.url) { Button(L("Убрать из очереди")) { m.onRemoveFromQueue(c) } }
            Divider()
            Button(L("Удалить в корзину")) { m.trash(c, undo: undo) }
                .disabled(m.isBusy(c.url))
        }
    }

}
