// Shared MCP server: one `server.py --http` process on 127.0.0.1, a child of Sozvon
// (so it has the same macOS permissions for Documents). If it crashes: a few restarts with a delay.

import Foundation
import SozvonCore

@MainActor
final class MCPServer: ObservableObject {
    static let shared = MCPServer()
    static let maxRestarts = 5

    /// Last failure (for the "Engine status" section in Settings).
    @Published private(set) var lastFailure: String?
    private var process: RunningProcess?
    private var restarts = 0
    /// Stopped on purpose (quit, restart): don't bring it back up.
    private var stopped = false
    /// Launch number: exit of an old process must not affect the new one.
    private var generation = 0

    var isRunning: Bool { process != nil }

    func start() {
        stopped = false
        launch()
    }

    private func launch() {
        guard process == nil, !stopped else { return }
        guard FileManager.default.isExecutableFile(atPath: Paths.python.path) else { return }
        let header = "\n=== \(ISO8601DateFormatter().string(from: Date())) server.py --http\n"
        AppLog.append(header, to: Paths.mcpLog)
        generation += 1
        let gen = generation
        process = ProcessRunner.run(Paths.python, [Paths.data.appendingPathComponent("server.py").path, "--http"],
                                    environment: Engine.environment(), currentDirectory: Paths.data,
                                    log: Paths.mcpLog, appendLog: true) { [weak self] code in
            self?.exited(code, generation: gen)
        }
        if process == nil { lastFailure = L("MCP-сервер не запустился, подробности в mcp.log") }
    }

    private func exited(_ code: Int32, generation gen: Int) {
        guard gen == generation else { return }
        process = nil
        guard !stopped else { return }
        lastFailure = L("MCP-сервер завершился с кодом %@, подробности в mcp.log", code)
        // Port taken by another copy, or a crash: a few quick retries, then once a minute
        // (the other copy may exit on its own, and MCP is needed for as long as the app runs).
        restarts += 1
        let delay: Double = restarts <= Self.maxRestarts ? 5 : 60
        mainAfter(delay) { [weak self] in self?.launch() }
    }

    /// Restart after an engine update: picks up the new server.py.
    func restart() {
        stop()
        mainAfter(1) { [weak self] in
            self?.restarts = 0
            self?.lastFailure = nil
            self?.start()
        }
    }

    func stop() {
        stopped = true
        generation += 1
        process?.terminate()
        process = nil
    }
}
