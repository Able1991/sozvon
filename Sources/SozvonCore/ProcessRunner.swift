// Запуск процессов движка: своя группа процессов (останавливается целиком через killpg),
// построчный вывод на главный поток, журнал на диске.

import Foundation
import os

/// Запущенный процесс. Он лидер своей группы: остановка доходит до всех потомков (uv, curl, python).
public final class RunningProcess: Sendable {
    public let pid: pid_t

    init(pid: pid_t) { self.pid = pid }

    /// Остановить процесс со всей группой. Недокачанное докачается при следующем запуске.
    public func terminate(_ signal: Int32 = SIGTERM) {
        killpg(pid, signal)
    }
}

public enum ProcessRunner {
    public typealias LineHandler = @MainActor @Sendable (String) -> Void
    public typealias DoneHandler = @MainActor @Sendable (Int32) -> Void

    /// Код завершения процесса, убитого сигналом: 128 + номер сигнала, как в shell.
    public static func exitCode(fromWaitStatus st: Int32) -> Int32 {
        let signal = st & 0x7f
        return signal == 0 ? (st >> 8) & 0xff : 128 + signal
    }

    /// Запустить процесс. Строки вывода (stdout и stderr вместе) приходят на главный поток по порядку,
    /// `done` вызывается после конца вывода и завершения процесса, когда журнал уже закрыт.
    /// Не запустился: в журнал и в `onLine` пишется причина, `done(-1)`, результат nil.
    @discardableResult
    public static func run(_ exe: URL, _ args: [String], environment: [String: String],
                           currentDirectory: URL? = nil, log: URL? = nil, appendLog: Bool = false,
                           onLine: LineHandler? = nil, done: @escaping DoneHandler) -> RunningProcess? {
        let logFD: Int32 = log.map {
            open($0.path, O_WRONLY | O_CREAT | O_CLOEXEC | (appendLog ? O_APPEND : O_TRUNC), 0o644)
        } ?? -1

        @Sendable func emit(_ line: String) {
            guard let onLine else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
        }
        func fail(_ reason: String) -> RunningProcess? {
            let msg = L("Не удалось запустить: %@", reason)
            if logFD >= 0 {
                writeAll(logFD, Data((msg + "\n").utf8))
                close(logFD)
            }
            emit(msg)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(-1) } }
            return nil
        }

        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return fail(String(cString: strerror(errno))) }
        let readFD = fds[0], writeFD = fds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        if let currentDirectory { posix_spawn_file_actions_addchdir_np(&actions, currentDirectory.path) }

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        // Своя группа процессов; наследуются только 0, 1, 2; сигналы по умолчанию и без маски.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attrs, Int16(flags))
        posix_spawnattr_setpgroup(&attrs, 0)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attrs, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attrs, &none)

        let argv: [UnsafeMutablePointer<CChar>?] = ([exe.path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe.path, &actions, &attrs, argv, envp)
        close(writeFD)  // наша копия пишущего конца не нужна, иначе конец вывода не наступит
        guard rc == 0 else {
            close(readFD)
            return fail(String(cString: strerror(rc)))
        }

        let status = OSAllocatedUnfairLock(initialState: Int32(0))
        let group = DispatchGroup()
        group.enter()  // конец вывода
        group.enter()  // завершение процесса
        Thread.detachNewThread {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(readFD, &chunk, chunk.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                let d = Data(chunk[0..<n])
                if logFD >= 0 { writeAll(logFD, d) }
                buffer.append(d)
                while let nl = buffer.firstIndex(of: 10) {
                    emit(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...nl)
                }
            }
            if !buffer.isEmpty { emit(String(decoding: buffer, as: UTF8.self)) }
            close(readFD)
            if logFD >= 0 { close(logFD) }
            group.leave()
        }
        let child = pid
        Thread.detachNewThread {
            var st: Int32 = 0
            while waitpid(child, &st, 0) < 0 && errno == EINTR {}
            let code = exitCode(fromWaitStatus: st)
            status.withLock { $0 = code }
            group.leave()
        }
        group.notify(queue: .main) {
            let code = status.withLock { $0 }
            MainActor.assumeIsolated { done(code) }
        }
        return RunningProcess(pid: child)
    }

    /// То же с ожиданием: код завершения.
    public static func run(_ exe: URL, _ args: [String], environment: [String: String],
                           currentDirectory: URL? = nil, log: URL? = nil, appendLog: Bool = false,
                           onLine: LineHandler? = nil) async -> Int32 {
        await withCheckedContinuation { cont in
            run(exe, args, environment: environment, currentDirectory: currentDirectory, log: log,
                appendLog: appendLog, onLine: onLine) { cont.resume(returning: $0) }
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }
                off += n
            }
        }
    }

    /// Короткая команда с ожиданием и полным выводом (CLI помощников). Не для главного потока.
    public static func capture(_ exe: String, _ args: [String], environment: [String: String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
