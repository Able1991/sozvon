// Режим скриншотов: --preview <что> [--tab N]. Собирается только с -D SOZVON_PREVIEW
// (./build.sh preview) и меняет состояние только через переходы машины записи и очереди.

#if SOZVON_PREVIEW
import AppKit
import SozvonCore

@MainActor
enum PreviewDriver {
    /// true, если запущен режим скриншотов (обычный запуск дальше не идёт).
    static func run(_ app: AppDelegate) -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--preview"), i + 1 < args.count else { return false }
        let tab = args.firstIndex(of: "--tab").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
        let demo = Paths.calls.appendingPathComponent("2026-11-04 15-01")
        let since = Date().addingTimeInterval(-754)

        func record() {
            app.recording.preview { m in
                m.begin(demo)
                m.started(RecordingSession(dir: demo, startedAt: since, info: CallInfo()))
            }
        }
        func openMenu() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.menu.button?.performClick(nil) }
        }

        switch args[i + 1] {
        case "callinfo":
            Task { _ = await CallInfoPrompt.ask(CallInfo(), title: L("О чём был звонок?"), okTitle: L("Расшифровать")) }
        case "callinfo-proj":
            Task {
                _ = await CallInfoPrompt.ask(CallInfo(profile: "acme", names: "Анна"),  // l10n-ignore
                                             title: L("О чём был звонок?"), okTitle: L("Расшифровать"))
            }
        case "projects": app.showProjects()
        case "settings": app.showSettings(tab: tab)
        case "calls": app.showCalls()
        case "panel-idle":
            FloatingPanel.showWhenIdle = true
            app.stateChanged()
        case "menu": openMenu()
        case "menu-rec":
            record()
            app.processing.preview(processing: nil, lastTranscript: URL(fileURLWithPath: "/tmp/x"))
            openMenu()
        case "panel-stop":
            // Переход: запись → «Записано» → расшифровка → ожидание.
            record()
            for i in 0..<PanelModel.bars { app.panel.model.push(mic: i < 11 ? 0.6 : 0.05, sys: i >= 11 ? 0.6 : 0.03) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                app.recording.preview { m in
                    m.stop(finalize: Task {})
                    m.finalized()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                app.recording.dismissSaved(demo)
                app.processing.preview(processing: demo)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { app.processing.preview(processing: nil) }
        case "panel", "panel-warn":
            record()
            // Демо-разговор: сначала я, потом собеседник.
            for i in 0..<PanelModel.bars {
                let t = Float(i)
                let me: Float = i < 11 ? 0.45 + 0.4 * abs(sin(t * 1.3)) : 0.05
                let them: Float = i >= 11 ? 0.4 + 0.45 * abs(sin(t * 0.9 + 1)) : 0.03
                app.panel.model.push(mic: me, sys: them)
            }
            if args.contains("panel-warn") { app.panel.model.systemSilent = 83 }
            app.panel.sync()
        default:
            return false
        }
        return true
    }
}
#endif
