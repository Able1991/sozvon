import Foundation
import XCTest
@testable import SozvonCore

@MainActor
final class ProcessRunnerTests: TempDirTestCase {
    /// Строки и код завершения, собранные на главном потоке.
    @MainActor final class Collected {
        var lines: [String] = []
        var code: Int32?
    }

    private func run(_ exe: String, _ args: [String], log: URL?, timeout: TimeInterval = 5) -> (Collected, RunningProcess?) {
        let c = Collected()
        let done = expectation(description: "done")
        let p = ProcessRunner.run(URL(fileURLWithPath: exe), args, environment: ["PATH": "/usr/bin:/bin"], log: log,
                                  onLine: { c.lines.append($0) }) { code in
            c.code = code
            done.fulfill()
        }
        wait(for: [done], timeout: timeout)
        return (c, p)
    }

    func testAllLinesThenDoneWithLog() throws {
        let log = tmp.appendingPathComponent("run.log")
        let (c, _) = run("/bin/sh", ["-c", "for i in 1 2 3; do echo line$i; done; printf tail >&2; exit 3"], log: log)
        XCTAssertEqual(c.code, 3, "код завершения")
        XCTAssertEqual(c.lines, ["line1", "line2", "line3", "tail"], "все строки дошли, и хвост без перевода строки")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "line1\nline2\nline3\ntail", "журнал")
    }

    func testLaunchFailure() throws {
        let log = tmp.appendingPathComponent("f.log")
        let (c, p) = run("/nonexistent/bin", [], log: log)
        XCTAssertNil(p)
        XCTAssertEqual(c.code, -1, "ошибка запуска -> -1")
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("Не удалось запустить"), "ошибка в журнале")
        XCTAssertEqual(c.lines.count, 1)
    }

    func testAppendLog() throws {
        let log = tmp.appendingPathComponent("a.log")
        try write("old\n", log)
        _ = run("/bin/echo", ["new"], log: log)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "new\n", "по умолчанию журнал заново")
        let c = Collected()
        let done = expectation(description: "done")
        ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), ["more"], environment: [:], log: log, appendLog: true) {
            c.code = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "new\nmore\n", "дописывание")
    }

    func testEnvironmentAndDirectory() throws {
        let (c, _) = run("/bin/sh", ["-c", "echo $FOO; pwd"], log: nil)
        XCTAssertEqual(c.lines.first, "")
        let c2 = Collected()
        let done = expectation(description: "done")
        ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo $FOO; pwd -P"], environment: ["FOO": "bar"],
                          currentDirectory: URL(fileURLWithPath: "/private/tmp"), onLine: { c2.lines.append($0) }) { _ in
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(c2.lines, ["bar", "/private/tmp"])
    }

    func testTerminateStopsWholeProcessGroup() throws {
        let pidFile = tmp.appendingPathComponent("child.pid")
        let c = Collected()
        let done = expectation(description: "done")
        let started = Date()
        // Внук держит вывод открытым: без остановки всей группы конец вывода не наступил бы.
        let p = try XCTUnwrap(ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "sleep 30 & echo $! > '\(pidFile.path)'; echo ready; wait"], environment: [:],
            onLine: { c.lines.append($0) }) { code in
                c.code = code
                done.fulfill()
            })
        XCTAssertEqual(getpgid(p.pid), p.pid, "своя группа процессов")
        let until = Date().addingTimeInterval(5)
        while !c.lines.contains("ready") && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        p.terminate()
        wait(for: [done], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(c.code, 128 + SIGTERM)
        let child = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // Осиротевший процесс launchd подбирает не мгновенно: ждём до 2 секунд.
        let gone = Date().addingTimeInterval(2)
        while kill(child, 0) == 0 && Date() < gone { usleep(50_000) }
        XCTAssertEqual(kill(child, 0), -1, "внук тоже остановлен")
    }

    func testAsyncVariant() async {
        let code = await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/false"), [], environment: [:])
        XCTAssertEqual(code, 1)
    }

    func testWaitStatusDecoding() {
        XCTAssertEqual(ProcessRunner.exitCode(fromWaitStatus: 0), 0)
        XCTAssertEqual(ProcessRunner.exitCode(fromWaitStatus: 3 << 8), 3)
        XCTAssertEqual(ProcessRunner.exitCode(fromWaitStatus: SIGKILL), 128 + SIGKILL)
    }
}
