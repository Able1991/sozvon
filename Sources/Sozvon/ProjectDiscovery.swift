// "Find projects with Claude Code / Codex / Cursor": `bin/discover_projects.py` asks the assistant to look through past
// sessions and writes the projects it finds. Used by the setup assistant and the Projects window.

import SozvonCore
import SwiftUI

@MainActor
final class ProjectDiscovery: ObservableObject {
    /// One search for the whole app: the setup assistant and the Projects window show the same run,
    /// closing either window doesn't orphan the script, and a second search can't start beside it.
    static let shared = ProjectDiscovery()

    /// How the last search ended: picks the icon next to `result`.
    enum Outcome { case none, found, stopped, failed }

    @Published private(set) var isRunning = false
    /// The script's final lines ("Found 3 projects: …"), or why the search stopped.
    @Published private(set) var result = ""
    @Published private(set) var outcome = Outcome.none
    /// The current step, from `STATUS: …` lines.
    @Published private(set) var status = ""
    @Published private(set) var started = Date()

    private var process: RunningProcess?
    /// Stopped by the user or failed to launch: lines still in flight are dropped.
    private var stopped = false
    /// Bumped on every start: callbacks of an earlier run are ignored.
    private var generation = 0

    private init() {}

    func start() {
        guard !isRunning else { return }
        generation += 1
        let run = generation
        isRunning = true
        stopped = false
        result = ""
        outcome = .none
        status = ""
        started = Date()
        process = ProcessRunner.run(Paths.python, [Paths.engineScript("discover_projects.py").path],
                                    environment: Engine.environment(), currentDirectory: Paths.data,
                                    onLine: { [weak self] line in
                                        guard let self, self.generation == run else { return }
                                        self.consume(line)
                                    }) { [weak self] code in
            guard let self, self.generation == run else { return }
            self.finish(code)
        }
        if process == nil {
            // The runner also reports the reason as an output line: drop it, one message is enough.
            stopped = true
            isRunning = false
            result = L("Не получилось запустить поиск: движок не установлен")
            outcome = .failed
        }
    }

    /// Stop a running search (the Stop button, quitting the app).
    func stop() {
        guard isRunning, !stopped else { return }
        stopped = true
        process?.terminate()
        result = L("Поиск остановлен")
        outcome = .stopped
    }

    private func finish(_ code: Int32) {
        isRunning = false
        process = nil
        guard !stopped else { return }
        outcome = code == 0 ? .found : .failed
    }

    private func consume(_ line: String) {
        guard !stopped else { return }
        if line.hasPrefix("STATUS: ") {
            withAnimation(.easeOut(duration: 0.2)) { status = String(line.dropFirst(8)) }
        } else {
            result += (result.isEmpty ? "" : "\n") + line
        }
    }

    #if SOZVON_PREVIEW
    /// Screenshot states of the setup assistant's Projects step.
    func preview(running: Bool, status: String = "", result: String = "", elapsed: TimeInterval = 0) {
        isRunning = running
        self.status = status
        self.result = result
        outcome = running || result.isEmpty ? .none : .found
        started = Date().addingTimeInterval(-elapsed)
    }
    #endif
}

/// How a finished search ended, as a status icon: found, stopped by the user, or failed.
struct ProjectDiscoveryIcon: View {
    let outcome: ProjectDiscovery.Outcome

    var body: some View {
        switch outcome {
        case .found:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .stopped:
            Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
        case .failed, .none:
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        }
    }
}

/// The search in progress: a small spinner, the current step, elapsed time and Stop.
struct ProjectDiscoveryProgress: View {
    @ObservedObject var discovery: ProjectDiscovery

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(discovery.status.isEmpty ? L("Ищу проекты…") : discovery.status)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let t = max(0, Int(ctx.date.timeIntervalSince(discovery.started)))
                    Text(L("%@ · обычно 2-5 минут", String(format: "%d:%02d", t / 60, t % 60)))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("Остановить")) { discovery.stop() }
        }
    }
}
