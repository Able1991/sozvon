// "Change…" next to the calls folder (setup assistant, Settings > Recognition > Files): pick a folder, offer to
// move the calls there, apply it at once. The rules and the move itself are in SozvonCore (CallsFolder.swift).

import AppKit
import SozvonCore
import SwiftUI

@MainActor final class CallsFolderChanger: ObservableObject {
    static let shared = CallsFolderChanger()

    /// Recording or transcribing now: the folder stays (AppDelegate sets it).
    static var isBusy: () -> Bool = { false }
    /// After a change: the MCP server and the Calls window follow the new folder (AppDelegate sets it).
    static var onChanged: () -> Void = {}

    /// "Moving 3 of 40" while calls are moved, nil otherwise.
    @Published private(set) var moving: String?
    @Published private(set) var current = Paths.calls

    func change() {
        guard moving == nil else { return }
        if Self.isBusy() {
            alert(L("Сейчас идёт запись или расшифровка"), L("Папку звонков можно сменить, когда они закончатся."))
            return
        }
        let panel = NSOpenPanel()
        panel.title = L("Папка звонков")
        panel.prompt = L("Выбрать")
        panel.message = L("Здесь будут лежать записи, расшифровки и саммари.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = current.deletingLastPathComponent()
        guard panel.runModal() == .OK, let new = panel.url else { return }
        apply(new)
    }

    func apply(_ new: URL) {
        let old = Paths.calls
        if let problem = CallsFolder.problem(from: old, to: new, data: Paths.data) {
            if problem != .same { alert(L("Эта папка не подходит"), Self.text(problem)) }
            return
        }
        let calls = CallsFolder.calls(in: old)
        guard !calls.isEmpty else { return switchTo(new) }
        let a = NSAlert()
        a.messageText = L("Перенести звонки в «%@»?", new.lastPathComponent)
        a.informativeText = L("Звонков: %@. Они переедут из «%@» вместе с аудио и заметками. Если не переносить, Sozvon будет показывать только звонки из новой папки, а старые останутся на месте.",
                              calls.count, (old.path as NSString).abbreviatingWithTildeInPath)
        a.addButton(withTitle: L("Перенести"))
        a.addButton(withTitle: L("Не переносить"))
        a.addButton(withTitle: L("Отмена"))
        switch a.runModal() {
        case .alertFirstButtonReturn: move(from: old, to: new)
        case .alertSecondButtonReturn: switchTo(new)
        default: return
        }
    }

    private func move(from old: URL, to new: URL) {
        moving = L("Переношу звонки…")
        Task {
            let error: String? = await Task.detached {
                do {
                    try CallsFolder.move(from: old, to: new,
                                         trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                                         progress: { done, total in
                                             Task { @MainActor in
                                                 CallsFolderChanger.shared.moving = L("Переношу звонки: %@ из %@", done, total)
                                             }
                                         })
                    return nil
                } catch CallsFolder.MoveError.taken(let names) {
                    return L("В новой папке уже есть звонки с такими же именами: %@. Ничего не перенесено.", names.prefix(3).joined(separator: ", "))
                } catch CallsFolder.MoveError.copyMismatch(let name) {
                    return L("Копия звонка «%@» не совпала с оригиналом. Оригинал остался на месте, папка не сменилась.", name)
                } catch {
                    return error.localizedDescription
                }
            }.value
            moving = nil
            if let error {
                // What already moved stays in the new folder: switch to it only when everything is there.
                alert(L("Не получилось перенести звонки"), error)
                if !CallsFolder.calls(in: new).isEmpty, CallsFolder.calls(in: old).isEmpty { switchTo(new) }
                return
            }
            switchTo(new)
        }
    }

    private func switchTo(_ new: URL) {
        let isDefault = new.standardizedFileURL.path == CallsFolder.defaultURL.standardizedFileURL.path
        CallsFolder.choose(isDefault ? nil : new)
        try? FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        current = Paths.calls
        Self.onChanged()
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private static func text(_ p: CallsFolder.Problem) -> String {
        switch p {
        case .same: return ""
        case .inside: return L("Она внутри нынешней папки звонков. Выбери папку рядом или в другом месте.")
        case .contains: return L("Нынешняя папка звонков лежит внутри неё. Выбери другую папку.")
        case .engineData: return L("Это папка движка Sozvon: при переустановке звонки пропали бы. Выбери другую.")
        }
    }
}

/// The calls folder with "Show in Finder" and "Change…", and the move progress under it.
struct CallsFolderRow: View {
    @ObservedObject private var changer = CallsFolderChanger.shared
    var title = L("Папка звонков")

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button(L("Показать в Finder")) { NSWorkspace.shared.open(changer.current) }
                Button(L("Сменить папку…")) { changer.change() }.disabled(changer.moving != nil)
            }
        } label: {
            Text(title)
            Text(verbatim: changer.moving ?? (changer.current.path as NSString).abbreviatingWithTildeInPath)
                .monospaced()
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
