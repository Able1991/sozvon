// Общий MCP-сервер: один процесс `server.py --http` на 127.0.0.1, дочерний для Sozvon
// (поэтому у него те же разрешения macOS на «Документы»). Упал: несколько перезапусков с паузой.

import Foundation
import SozvonCore

@MainActor
final class MCPServer: ObservableObject {
    static let shared = MCPServer()
    static let maxRestarts = 5

    /// Последний сбой (для блока «Состояние движка» в настройках).
    @Published private(set) var lastFailure: String?
    private var process: RunningProcess?
    private var restarts = 0
    /// Остановлен намеренно (выход, перезапуск): не поднимать снова.
    private var stopped = false
    /// Номер запуска: завершение старого процесса не должно трогать новый.
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
        if let h = try? FileHandle(forWritingTo: Paths.mcpLog) {
            h.seekToEndOfFile()
            h.write(Data(header.utf8))
            try? h.close()
        } else {
            try? header.write(to: Paths.mcpLog, atomically: true, encoding: .utf8)
        }
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
        // Порт занят другой копией или сбой: несколько быстрых попыток, потом раз в минуту
        // (копия могла завершиться сама, а MCP нужен всё время работы приложения).
        restarts += 1
        let delay: Double = restarts <= Self.maxRestarts ? 5 : 60
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.launch() }
        }
    }

    /// Перезапуск после обновления движка: новый server.py.
    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.restarts = 0
                self?.lastFailure = nil
                self?.start()
            }
        }
    }

    func stop() {
        stopped = true
        generation += 1
        process?.terminate()
        process = nil
    }
}
