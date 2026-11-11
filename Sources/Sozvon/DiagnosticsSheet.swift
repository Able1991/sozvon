// "Diagnostics…" in Settings > About: the environment checks, and the scrubbed logs for support as a zip or a folder.
// What goes into the archive, and what never does, is decided in SozvonCore (Diagnostics.swift).

import AppKit
import SozvonCore
import SwiftUI
import UniformTypeIdentifiers

enum DiagnosticsRunner {
    /// All checks. Reads files and probes the MCP server, so the caller awaits it away from the UI.
    @MainActor
    static func run() async -> [DiagnosticCheck] {
        let model = Settings.shared.model
        let dev = Paths.isDevEngine
        let local = await Task.detached { DiagnosticChecks.local(data: Paths.data, model: model, isDevEngine: dev) }.value
        let health = await MCPHealth.probe()
        let micHint = L("Разреши в Системных настройках: «Конфиденциальность и безопасность» → «Микрофон».")
        let screenHint = L("Разреши в Системных настройках: «Конфиденциальность и безопасность» → «Запись экрана и системного аудио».")
        // `local`: Python, model, ffmpeg, speaker models, then free space; permissions and the server go before the space.
        return Array(local.prefix(4)) + [
            DiagnosticChecks.permission(title: L("Микрофон"), granted: Permissions.mic, hint: micHint),
            DiagnosticChecks.permission(title: L("Запись экрана и системного аудио"), granted: Permissions.screen, hint: screenHint),
            DiagnosticChecks.mcp(health),
        ] + local.dropFirst(4) + [
            DiagnosticChecks.versions(app: AboutVersion.text, engineBundled: Engine.bundledVersion,
                                      engineInstalled: DiagnosticChecks.installedEngineVersion(data: Paths.data)),
        ]
    }
}

/// The app version as About shows it.
enum AboutVersion {
    static var text: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty || build == Updates.current ? Updates.current : "\(Updates.current) (\(build))"
    }
}

struct DiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var checks: [DiagnosticCheck]?
    @State private var saving = false
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        SZWFormSheet(L("Диагностика"), subtitle: L("Что работает, а что мешает записи и расшифровке."), width: 520, maxHeight: 460) {
            Section {
                if let checks {
                    ForEach(checks) { row($0) }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("Проверяю…")).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFooter(L("В архив попадают проверки и журналы без текста разговоров: ни расшифровок, ни саммари, ни аудио, ни паролей, ни голосов. Пути к домашней папке и названия звонков заменены."))
                    if let result {
                        if failed { SettingsWarning(result) } else { Text(result).font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
        } actions: {
            Button(L("Закрыть")) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(L("Показать логи"), action: showLogs)
                .disabled(checks == nil || saving)
                .help(L("Те же очищенные журналы, что в архиве, в папке в Finder: посмотреть и отправить"))
            Button(L("Сохранить архив…"), action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(checks == nil || saving)
        }
        .task { checks = await DiagnosticsRunner.run() }
    }

    private func row(_ c: DiagnosticCheck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: Self.symbol(c.state)).foregroundStyle(Self.color(c.state)).frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title)
                Text(c.hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Self.stateName(c.state))
    }

    private static func symbol(_ s: DiagnosticState) -> String {
        switch s {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        }
    }

    private static func color(_ s: DiagnosticState) -> Color {
        switch s {
        case .ok: return .green
        case .warning: return .orange
        case .problem: return .red
        }
    }

    private static func stateName(_ s: DiagnosticState) -> String {
        switch s {
        case .ok: return L("Хорошо")
        case .warning: return L("Внимание")
        case .problem: return L("Проблема")
        }
    }

    /// The scrubbed logs in ~/Library/Logs/Sozvon/Diagnostics, shown in Finder.
    private func showLogs() {
        guard let checks else { return }
        let folder = Paths.logs.appendingPathComponent("Diagnostics", isDirectory: true)
        saving = true
        result = nil
        Task {
            let error: String? = await Task.detached {
                do {
                    try DiagnosticArchive.writeFolder(checks: checks, logs: Paths.logs, data: Paths.data, calls: Paths.calls,
                                                      home: Paths.home.path, to: folder)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            saving = false
            failed = error != nil
            if let error {
                result = L("Не получилось собрать журналы: %@", error)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
    }

    private func save() {
        guard let checks else { return }
        let panel = NSSavePanel()
        panel.title = L("Сохранить архив диагностики")
        panel.prompt = L("Сохранить")
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = DiagnosticArchive.fileName()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saving = true
        result = nil
        Task {
            let error: String? = await Task.detached {
                do {
                    try DiagnosticArchive.build(checks: checks, logs: Paths.logs, data: Paths.data, calls: Paths.calls,
                                                home: Paths.home.path, to: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            saving = false
            failed = error != nil
            result = error.map { L("Не получилось сохранить архив: %@", $0) } ?? L("Архив сохранён: %@", url.lastPathComponent)
        }
    }
}
