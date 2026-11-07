// "To Reminders": the summary's action items (yours checked by default) and the call's notes become
// reminders in the default list or in a "Sozvon" list.
//
// Access: EKEventStore.requestFullAccessToReminders (macOS 14+), with NSRemindersFullAccessUsageDescription
// in Info.plist (build.sh). Sozvon is not sandboxed, so the App Sandbox entitlement does not apply, but it is
// signed with the hardened runtime, and the hardened runtime's resource access list has its own
// com.apple.security.personal-information.calendars entitlement that covers EventKit (calendars and reminders);
// without it TCC denies access without asking. So Sozvon.entitlements carries it, like device.audio-input.

import AppKit
import EventKit
import SozvonCore
import SwiftUI

@MainActor
enum RemindersExport {
    static let listName = "Sozvon"
    private static let store = EKEventStore()

    enum Failure: LocalizedError {
        case denied, noList

        var errorDescription: String? {
            switch self {
            case .denied: return L("Нет доступа к Напоминаниям. Разреши его в Системных настройках, раздел «Конфиденциальность и безопасность» → «Напоминания».")
            case .noList: return L("Не нашёлся список для напоминаний")
            }
        }
    }

    struct Entry {
        var title: String
        var due: DateComponents?
    }

    static func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return true
        case .notDetermined: return (try? await store.requestFullAccessToReminders()) ?? false
        default: return false
        }
    }

    /// The list reminders go to; `create`: make the "Sozvon" list if it is missing.
    private static func target(sozvonList: Bool, create: Bool) throws -> EKCalendar? {
        guard sozvonList else { return store.defaultCalendarForNewReminders() }
        if !create { return store.calendars(for: .reminder).first { $0.title == listName } }
        return try sozvon()
    }

    /// Incomplete reminders in the target list, to spot ones already added from this call. Never asks for
    /// access (the sheet opening is not a reason to): without it, nil.
    static func existing(sozvonList: Bool) async -> [ReminderMatch.Existing]? {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let calendar = try? target(sozvonList: sozvonList, create: false) else { return nil }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [calendar])
        return await withCheckedContinuation { c in
            store.fetchReminders(matching: predicate) { list in
                c.resume(returning: (list ?? []).map {
                    ReminderMatch.Existing(title: $0.title ?? "", notes: $0.notes, url: $0.url)
                })
            }
        }
    }

    /// Add the reminders, skipping those already there (`isDuplicate`, checked against the list right now).
    /// `sozvonList`: into a "Sozvon" list (created next to the default list if missing). -> how many were added.
    static func add(_ entries: [Entry], notes: String, url: URL?, sozvonList: Bool,
                    isDuplicate: ([ReminderMatch.Existing], String) -> Bool) async throws -> (added: Int, skipped: Int) {
        guard await requestAccess() else { throw Failure.denied }
        let have = await existing(sozvonList: sozvonList) ?? []
        guard let calendar = try target(sozvonList: sozvonList, create: true) else { throw Failure.noList }
        var added = 0, skipped = 0
        for e in entries {
            if isDuplicate(have, e.title) { skipped += 1; continue }
            let r = EKReminder(eventStore: store)
            r.calendar = calendar
            r.title = e.title
            r.notes = notes
            r.url = url
            r.dueDateComponents = e.due
            try store.save(r, commit: false)
            added += 1
        }
        if added > 0 { try store.commit() }
        return (added, skipped)
    }

    private static func sozvon() throws -> EKCalendar? {
        if let c = store.calendars(for: .reminder).first(where: { $0.title == listName }) { return c }
        guard let source = store.defaultCalendarForNewReminders()?.source else { return nil }
        let c = EKCalendar(for: .reminder, eventStore: store)
        c.title = listName
        c.source = source
        try store.saveCalendar(c, commit: true)
        return c
    }

    static func openPrivacySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(u)
        }
    }
}

struct RemindersSheet: View {
    let call: Call
    let items: [ActionItem]
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<Int>
    @State private var pickedNotes: Set<String> = []
    @AppStorage("remindersSozvonList") private var sozvonList = false
    @State private var error: String?
    @State private var denied = false
    @State private var busy = false
    /// Incomplete reminders in the chosen list (empty until known, or without access).
    @State private var existing: [ReminderMatch.Existing] = []
    private let me: String

    init(call: Call, items: [ActionItem], me: String) {
        self.call = call
        self.items = items
        self.me = me
        _picked = State(initialValue: Set(items.indices.filter { !items[$0].done && ActionItems.isMine(items[$0].owner, me: me) }))
    }

    /// A due date relative to when it was said: the call for its tasks, the note's own time for a note
    /// ("завтра" in a note written two days after the call).
    private func due(_ text: String, from date: Date? = nil) -> DateComponents? {
        (date ?? call.date).flatMap { DueDate.parse(text, callDate: $0) }
    }

    private func noteDue(_ n: CallNote) -> DateComponents? { due(n.text, from: n.date) }
    private func noteTitle(_ n: CallNote) -> String { String(n.text.prefix(300)) }

    /// The line in a reminder's notes that names this call, also how a repeated export recognizes it.
    private var callLine: String { L("Звонок в Sozvon: %@", call.url.lastPathComponent) }
    private var reminderURL: URL { call.hasSummary ? call.summaryURL : call.url }

    private func isDuplicate(_ have: [ReminderMatch.Existing], _ title: String) -> Bool {
        ReminderMatch.contains(have, title: title, links: [callLine], urls: [call.summaryURL, call.url])
    }

    private func already(_ title: String) -> Bool { isDuplicate(existing, title) }

    /// The task itself; someone else's task keeps its owner, so the reminder still says whose it is.
    private func title(_ i: ActionItem) -> String {
        i.owner.isEmpty || ActionItems.isMine(i.owner, me: me) ? i.task : "\(i.owner): \(i.task)"
    }

    private var count: Int {
        picked.filter { !already(title(items[$0])) }.count
            + call.notes.filter { pickedNotes.contains($0.id) && !already(noteTitle($0)) }.count
    }

    var body: some View {
        SZWFormSheet(L("В Напоминания"), maxHeight: 520) {
            if !items.isEmpty {
                Section(L("Задачи")) {
                    ForEach(items.indices, id: \.self) { i in
                        toggle(isOn: Binding(get: { picked.contains(i) },
                                             set: { if $0 { picked.insert(i) } else { picked.remove(i) } }),
                               title: title(items[i]), due: due(items[i].task), already: already(title(items[i])))
                    }
                }
            }
            if !call.notes.isEmpty {
                Section(L("Заметки")) {
                    ForEach(call.notes) { n in
                        toggle(isOn: Binding(get: { pickedNotes.contains(n.id) },
                                             set: { if $0 { pickedNotes.insert(n.id) } else { pickedNotes.remove(n.id) } }),
                               title: n.text, due: noteDue(n), already: already(noteTitle(n)))
                    }
                }
            }
            Section {
                Picker(L("Список"), selection: $sozvonList) {
                    Text(L("По умолчанию")).tag(false)
                    Text(RemindersExport.listName).tag(true)
                }
            } footer: {
                if let error {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SettingsWarning(error)
                        Spacer(minLength: 8)
                        if denied {
                            Button(L("Открыть настройки")) { RemindersExport.openPrivacySettings() }
                                .controlSize(.small)
                        }
                    }
                }
            }
        } actions: {
            Button(L("Отмена"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(count > 0 ? L("Добавить (%@)", count) : L("Добавить"), action: add)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction).disabled(count == 0 || busy)
        }
        .task(id: sozvonList) { existing = await RemindersExport.existing(sozvonList: sozvonList) ?? [] }
    }

    /// A checkbox row: the text and its due date below. `already`: this call's reminder with the same title is in
    /// the list: shown, not added again.
    private func toggle(isOn: Binding<Bool>, title: String, due: DateComponents?, already: Bool) -> some View {
        Toggle(isOn: already ? .constant(false) : isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if already {
                    Label(L("Уже в Напоминаниях"), systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let due, let d = Calendar.current.date(from: due) {
                    Label(d.formatted(.dateTime.weekday(.wide).day().month(.wide)), systemImage: "calendar")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.checkbox)
        .disabled(already)
    }

    private func add() {
        var entries = items.indices.filter(picked.contains).map { RemindersExport.Entry(title: title(items[$0]), due: due(items[$0].task)) }
        entries += call.notes.filter { pickedNotes.contains($0.id) }.map {
            RemindersExport.Entry(title: noteTitle($0), due: noteDue($0))
        }
        entries = entries.filter { !already($0.title) }  // shown as "already there", not sent again
        // Call title and date, plus the folder name to find it in Sozvon; the URL opens the summary.
        var head = call.title
        if let d = call.date { head += " · " + d.formatted(date: .long, time: .shortened) }
        let notes = head + "\n" + callLine
        busy = true
        Task {
            defer { busy = false }
            do {
                let r = try await RemindersExport.add(entries, notes: notes, url: reminderURL, sozvonList: sozvonList,
                                                      isDuplicate: isDuplicate)
                if r.added == 0 && r.skipped > 0 {
                    existing = await RemindersExport.existing(sozvonList: sozvonList) ?? existing
                    self.error = L("Уже в Напоминаниях")
                } else {
                    dismiss()
                }
            } catch {
                if case RemindersExport.Failure.denied = error { denied = true }
                self.error = error.localizedDescription
            }
        }
    }
}
