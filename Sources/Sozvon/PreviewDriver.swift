// Screenshot mode: --preview <what> [--tab N] [--appearance dark|light] [--setup-state S] [--snap <png>]. Compiled only with
// -D SOZVON_PREVIEW (./build.sh preview) and changes state only through recording machine and queue transitions.

#if SOZVON_PREVIEW
import AppKit
import ScreenCaptureKit
import SozvonCore
import SwiftUI

@MainActor
enum PreviewDriver {
    /// The capsule screens: shown even though the demo data has no engine.
    static var panelAlways = false
    /// true if screenshot mode was launched (the normal launch doesn't continue).
    static func run(_ app: AppDelegate) -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--preview"), i + 1 < args.count else { return false }
        // Force an appearance for snapshots of both themes, whatever the system uses.
        if let a = args.firstIndex(of: "--appearance"), a + 1 < args.count {
            switch args[a + 1] {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: break
            }
        }
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
            Task {
                _ = await CallInfoPrompt.answer(CallInfo(), title: L("О чём был звонок?"), okTitle: L("Расшифровать"),
                                                allowLater: true)
            }
        case "callinfo-sure":
            // The project and the people are known: the form goes ahead by itself after a countdown.
            Task {
                // l10n-ignore-start: fictional call content in the language of the interface, for the screenshots
                let en = Engine.uiLanguage == "en"
                let info = CallInfo(profile: "acme", names: en ? "Anna Petrova, Oleg" : "Анна Петрова, Олег",
                                    topic: en ? "Release planning" : "Планирование релиза", languages: en ? [.en] : [.ru])
                // l10n-ignore-end
                _ = await CallInfoPrompt.answer(info,
                                                title: L("О чём был звонок?"), okTitle: L("Расшифровать"),
                                                allowLater: true, countdown: 9)
            }
        case "callinfo-proj":
            Task {
                _ = await CallInfoPrompt.ask(CallInfo(profile: "acme", names: "Анна"),  // l10n-ignore
                                             title: L("О чём был звонок?"), okTitle: L("Расшифровать"))
            }
        case "projects": app.showProjects()
        case "setup":
            // --setup-state installing|failed|cancelled|fresh|installed|discovering|found|denied
            SetupModel.previewState = args.firstIndex(of: "--setup-state").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            let step = tab.flatMap(SetupModel.Step.init(rawValue:)) ?? .welcome
            app.showSetup(step: step)
        case "repair":
            SetupModel.previewState = args.firstIndex(of: "--setup-state").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            let step = tab.flatMap(SetupModel.Step.init(rawValue:)) ?? .model
            app.showSetup(step: step, repair: true)
        case "settings":
            // --engine-error: the MCP server does not answer (SettingsEngineError board); --tall: no height cap.
            SettingsPreview.engineError = args.contains("--engine-error")
            SettingsPreview.tall = args.contains("--tall")
            app.showSettings(tab: tab)
            NSApp.activate(ignoringOtherApps: true)
        case "calls":
            // --live: a call being recorded on top of the list ("Now"); --size WxH: the window size of the boards.
            let live = Paths.calls.appendingPathComponent(
                Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) 12-37",
                                           timeZone: .current, calendar: .current)))
            if args.contains("--live") {
                try? FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
                app.calls.recordingDir = live
                // The recording machine syncs recordingDir on its own changes: set it again once the window is up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { app.calls.recordingDir = live }
            } else {
                try? FileManager.default.removeItem(at: live)
            }
            app.showCalls()
            if let s = args.firstIndex(of: "--size").flatMap({ $0 + 1 < args.count ? args[$0 + 1] : nil }),
               case let wh = s.split(separator: "x").compactMap({ Double($0) }), wh.count == 2,
               let w = WindowsRegistry.shared.window("calls") {
                w.setContentSize(NSSize(width: wh[0], height: wh[1]))
                w.center()
            }
        case "panel-idle":
            FloatingPanel.showWhenIdle = true
            panelAlways = true
            app.stateChanged()
        case "menu": openMenu()
        case "menu-rec":
            record()
            app.processing.preview(processing: nil, lastTranscript: URL(fileURLWithPath: "/tmp/x"))
            openMenu()
        case "panel-stop":
            // Transition: recording → "Recorded" → transcription → idle.
            record()
            for i in 0..<PanelModel.bars { app.panel.model.push(mic: i < 16 ? 0.6 : 0.05, sys: i >= 16 ? 0.6 : 0.03) }
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
        case "prompt":
            // The call prompt on the idle capsule.
            FloatingPanel.showWhenIdle = true
            app.panel.model.callPrompt = L("Идёт звонок в %@. Записать?", "Zoom")
            app.panel.sync()
        case "panel-countdown":
            // "Record automatically": the call prompt counting down to the start.
            panelAlways = true
            app.stateChanged()
            app.panel.model.startIn = 7
            app.panel.model.callPrompt = L("Звонок в %@ · запись через %@ с", "Zoom", 7)
            app.panel.sync()
        case "panel-ending":
            // "Stop when the call ends": the call app let go of the microphone.
            record()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                app.panel.model.stopIn = 24
                app.panel.sync()
            }
        case "panel-saved":
            // "Recorded · 22 min" between the stop and the "what was the call about" answer.
            app.panel.model.state = .recording
            app.panel.model.elapsed = "22:04"
            app.panel.model.state = .saved
            app.panel.sync()
        case "panel-processing":
            app.processing.preview(processing: demo)
            app.panel.model.state = .processing
            app.panel.sync()
        case "voicesheet", "voicesheet-add":
            showSheet(VoiceSampleSheet(add: args.contains("voicesheet-add")))
        case "savedvoices":
            showSheet(SavedVoicesSheet())
        case "fixword":
            let line = TranscriptLine(start: 9, speaker: "Sarah", text: "We need a retry policy and a signature header.")  // l10n-ignore
            showFormSheet(FixWordSheet(line: line) { _, _ in })
        case "rename", "rename-taken":
            // l10n-ignore-start
            let lines = [TranscriptLine(start: 3, speaker: "Sarah", text: "Let's start with the webhooks."),
                         TranscriptLine(start: 9, speaker: "Tom", text: "We need a retry policy and a signature header."),
                         TranscriptLine(start: 15, speaker: "Sarah", text: "Agreed, three attempts.")]
            // l10n-ignore-end
            showFormSheet(RenameSpeakerSheet(target: FixTarget(line: lines[1]), lines: lines, suggestions: ["Sarah", "Tom Baker"],
                                         name: args.contains("rename-taken") ? "Sarah" : nil) { _ in })
        case "projecteditor":
            if let p = Project.all().first { showFormSheet(ProjectEditor(project: p) { _ in }) }
        case "reminders":
            if let call = Call.all().first(where: { $0.hasSummary }) {
                let summary = (try? String(contentsOf: call.summaryURL, encoding: .utf8)) ?? ""
                showFormSheet(RemindersSheet(call: call, items: ActionItems.parse(summary), me: Settings.shared.name))
            }
        case "capsules":
            // Every capsule state side by side (the real panels are too small for the snapshot filter).
            showSheet(CapsuleStates())
        case "panel", "panel-warn":
            record()
            // Demo conversation in the shown (recent) half: me first, then the other participant.
            for i in 0..<PanelModel.bars {
                let t = Float(i)
                let me: Float = i < 16 ? 0.45 + 0.4 * abs(sin(t * 1.3)) : 0.05
                let them: Float = i >= 16 ? 0.4 + 0.45 * abs(sin(t * 0.9 + 1)) : 0.03
                app.panel.model.push(mic: me, sys: them)
            }
            if args.contains("panel-warn") { app.panel.model.warning = .them(seconds: 154) }
            if args.contains("--marks") { app.panel.model.marks = 2 }
            app.panel.sync()
        default:
            return false
        }
        if let j = args.firstIndex(of: "--snap"), j + 1 < args.count {
            let out = URL(fileURLWithPath: args[j + 1])
            let delay = args.firstIndex(of: "--snap-delay").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 3
            // Stage Manager keeps a window of an inactive app in its strip; a floating window stays on screen,
            // so the window server draws it (glass included) and the capture below sees it.
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay - 0.7)) {
                MainActor.assumeIsolated {
                    // Never take the user's typing or clicks while the window is briefly on top.
                    NSApp.setActivationPolicy(.accessory)
                    for w in NSApp.windows where w.frame.width > 150 && w.isVisible {
                        w.makeFirstResponder(nil)
                        w.resignKey()
                        w.ignoresMouseEvents = true
                        w.level = .floating
                        w.orderFrontRegardless()
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Task { @MainActor in
                    await snapshot(to: out)
                    // Not terminate(): a preview "recording" would wait for a finalize that never comes.
                    exit(0)
                }
            }
        }
        return true
    }

    private static var sheetWindow: NSWindow?

    /// A sheet's content alone in a window over the window background, for snapshots of the sheet itself.
    static func showSheet<V: View>(_ view: V) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: view.fixedSize())
        host.sizingOptions = [.preferredContentSize]
        w.contentViewController = host
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        sheetWindow = w
    }

    /// A form sheet (SZWFormSheet) alone in a window that sizes itself to the form, the way a sheet does.
    static func showFormSheet<V: View>(_ view: V) {
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        sheetWindow = w
    }

    /// Render every app window (with its title bar and toolbar) into PNGs, without it being on screen:
    /// Stage Manager or another active app does not matter.
    static func snapshot(to out: URL) async {
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        // ScreenCaptureKit captures the window as the window server draws it (glass included), even when it is
        // behind other windows or in the Stage Manager strip; drawing the view ourselves is the fallback.
        let shareable = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        var n = 0
        for w in NSApp.windows where w.isVisible {
            var png: Data?
            if w.windowNumber > 0, w.frame.width > 150,
               let scw = shareable?.windows.first(where: { $0.windowID == CGWindowID(w.windowNumber) }) {
                let cfg = SCStreamConfiguration()
                let scale = w.backingScaleFactor
                cfg.width = Int(w.frame.width * scale)
                cfg.height = Int(w.frame.height * scale)
                cfg.showsCursor = false
                if let img = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: scw), configuration: cfg) {
                    png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
                }
            }
            if png == nil, let view = w.contentView?.superview ?? w.contentView, view.bounds.width > 150,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                png = rep.representation(using: .png, properties: [:])
            }
            guard let png else { continue }
            let name = n == 0 ? out.path : out.deletingPathExtension().path + "-\(n).png"
            try? png.write(to: URL(fileURLWithPath: name))
            n += 1
        }
    }
}
#endif

#if SOZVON_PREVIEW
/// The capsule's states on the design's wallpaper, drawn with the --glass fill and the capsule shadow.
private struct CapsuleStates: View {
    private static func model(_ state: PanelModel.State, prompt: String? = nil, warn: Bool = false,
                              marks: Int = 0) -> PanelModel {
        let m = PanelModel()
        m.state = .recording
        m.elapsed = state == .saved ? "22:04" : (warn ? "4:51" : "12:37")
        for i in 0..<PanelModel.bars {
            let t = Float(i)
            m.push(mic: i < 16 ? 0.45 + 0.4 * abs(sin(t * 1.3)) : 0.05, sys: i >= 16 ? 0.4 + 0.45 * abs(sin(t * 0.9 + 1)) : 0.03)
        }
        if warn { m.warning = .them(seconds: 154) }
        m.marks = marks
        m.state = state
        m.callPrompt = prompt
        return m
    }

    private let rows: [[PanelModel]] = [
        [model(.recording, marks: 2)],
        [model(.idle), model(.recording, warn: true)],
        [model(.idle, prompt: L("Идёт звонок в %@. Записать?", "Zoom"))],
        [model(.saved), model(.processing)],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 22) {
                    ForEach(rows[r].indices, id: \.self) { i in
                        PanelView(m: rows[r][i]).fixedSize()
                            .szSurface(Color(nsColor: SZW.glass), radius: FloatingPanel.cornerRadius, shadow: .capsule)
                            .opacity(rows[r][i].state == .idle && rows[r][i].callPrompt == nil ? 0.86 : 1)
                    }
                }
            }
        }
        .padding(28).padding(.top, 20)
        .frame(width: 560, alignment: .leading)
        .background(LinearGradient(colors: [SZ.dynamic(0xdfe7f5ff, 0x3b4a73ff, name: "wallA"),
                                            SZ.dynamic(0x6f82a8ff, 0x0b0d16ff, name: "wallB")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
#endif
