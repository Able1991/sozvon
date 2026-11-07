import Foundation
import XCTest
@testable import SozvonCore

final class PathsTests: TempDirTestCase {
    func testDataDirFromSettings() {
        XCTAssertEqual(Paths.data.path, data.path, "engineDir из настроек")
        XCTAssertTrue(Paths.isDevEngine, "свой движок = режим разработчика")
        XCTAssertEqual(Paths.calls.path, calls.path)
        XCTAssertEqual(Paths.python.path, data.appendingPathComponent(".venv/bin/python3").path)
    }

    func testEngineScriptInBin() {
        XCTAssertEqual(Paths.engineScript("process_call.py").path,
                       data.appendingPathComponent("bin/process_call.py").path, "bin/ по контракту, без запасного scripts/")
    }

    func testEngineScriptOverride() {
        let dir = tmp.appendingPathComponent("dev")
        XCTAssertEqual(Paths.engineScript("x.py", data: data, override: dir).path, dir.appendingPathComponent("x.py").path)
    }
}

final class ProjectTests: TempDirTestCase {
    func testSlugify() {
        XCTAssertEqual(Project.slugify("Acme.io / ВидеоМир"), "acme-io-videomir")
        XCTAssertEqual(Project.slugify("Щука и Ёж"), "schuka-i-ezh", "кириллица")
        XCTAssertEqual(Project.slugify("!!!"), "project", "пустой slug")
        XCTAssertEqual(Project.slugify(String(repeating: "a", count: 100)).count, 40, "slug обрезается")
        XCTAssertTrue(Project.isValidSlug(Project.slugify("Любое Название 2")))
    }

    func testValidSlug() {
        XCTAssertTrue(Project.isValidSlug("acme_2-x"))
        XCTAssertFalse(Project.isValidSlug(""))
        XCTAssertFalse(Project.isValidSlug("Acme"))
        XCTAssertFalse(Project.isValidSlug("../etc"))
        XCTAssertFalse(Project.isValidSlug(String(repeating: "a", count: 65)))
    }

    func testSplitList() {
        XCTAssertEqual(splitList(" Анна, Иван ,,\nОлег "), ["Анна", "Иван", "Олег"])
    }

    func testSaveKeepsForeignFields() throws {
        let acme = Project(slug: "acme", title: "Acme / Holding", context: "c", people: ["Анна"], terms: ["HPA"])
        try acme.save()
        let file = Paths.profiles.appendingPathComponent("acme.json")
        var raw = try json(file)
        XCTAssertEqual(raw["schema"] as? Int, 1, "схема проекта")
        raw["replacements"] = [["кубер", "Kubernetes"]]
        try JSONSerialization.data(withJSONObject: raw).write(to: file)
        var edited = try XCTUnwrap(Project.all().first)
        edited.people.append("Иван")
        try edited.save()
        raw = try json(file)
        XCTAssertEqual(raw["replacements"] as? [[String]], [["кубер", "Kubernetes"]], "replacements сохранились")
        XCTAssertEqual(Project.all().first?.people, ["Анна", "Иван"], "люди обновились")
        XCTAssertEqual(Project.all().first?.shortTitle, "Acme")
    }

    func testInvalidProfileFileIgnored() throws {
        try write("{\"title\": \"x\"}", Paths.profiles.appendingPathComponent("Bad Name.json"))
        try write("not json", Paths.profiles.appendingPathComponent("broken.json"))
        XCTAssertTrue(Project.all().isEmpty)
    }

    func testUniqueSlug() throws {
        try Project(slug: "acme", title: "Acme").save()
        try Project(slug: "acme-2", title: "Acme").save()
        XCTAssertEqual(Project.uniqueSlug(for: "Acme"), "acme-3")
        XCTAssertEqual(Project.uniqueSlug(for: "Other"), "other")
    }

    func testDeleteRemovesOnlyThatProject() throws {
        try Project(slug: "acme", title: "Acme").save()
        try Project(slug: "other", title: "Other").save()
        var removed: [URL] = []
        // Real deletion goes to the Trash; here the file is removed directly so the user's Trash stays clean.
        try Project.delete("acme") { url in
            removed.append(url)
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertEqual(removed.map(\.lastPathComponent), ["acme.json"])
        XCTAssertEqual(Project.all().map(\.slug), ["other"], "the other project stays")
        XCTAssertThrowsError(try Project.delete("../etc") { _ in XCTFail("invalid slug must not reach the file system") })
    }

    func testKnownPeople() throws {
        func call(_ names: String, _ profile: String) -> Call {
            Call(url: tmp, callID: "", date: nil, title: "", project: "", topic: "", languages: [], people: names,
                 duration: 0, bytes: 0, hasTranscript: false, hasSummary: false, hasAudio: false,
                 info: CallInfo(profile: profile, names: names), status: nil, isLegacy: false)
        }
        let calls = [call("Анна, Иван", "acme"), call("Анна, Я", "acme"), call("Олег", "other")]
        let projects = [Project(slug: "acme", title: "Acme", people: ["Анна Петрова", "Пётр"])]
        let people = knownPeople("acme", calls: calls, projects: projects, me: "я")
        XCTAssertEqual(people, ["Анна", "Иван", "Пётр"], "частые первыми, без себя, «Анна Петрова» не дублирует «Анна»")
        XCTAssertEqual(knownPeople("", calls: calls, projects: projects, me: ""), [])
    }
}

final class InstanceLockTests: TempDirTestCase {
    func testSecondCopyRejectedUntilReleased() throws {
        let first = try XCTUnwrap(InstanceLock.acquire(in: data))
        XCTAssertNil(InstanceLock.acquire(in: data), "вторая копия не берёт замок")
        first.release()
        let again = try XCTUnwrap(InstanceLock.acquire(in: data))
        again.release()
    }

    func testFileLockUsesSiblingLockLikeEngine() throws {
        let url = data.appendingPathComponent("profiles/acme.json")
        try Project(slug: "acme", title: "Acme").save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("profiles/acme.json.lock").path))
        XCTAssertEqual(Project.all().map(\.slug), ["acme"], "файл замка не считается проектом")
        // While the "engine" holds the lock, the edit waits; without the lock it goes through immediately.
        let fd = open(FileLock.lockURL(for: url).path, O_RDWR)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let done = expectation(description: "save")
        DispatchQueue.global().async {
            try? Project(slug: "acme", title: "Acme 2").save()
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(Project.all().first?.title, "Acme", "правка ждёт замка")
        flock(fd, LOCK_UN)
        close(fd)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(Project.all().first?.title, "Acme 2")
    }

    func testFileLockThrowsWithoutLockFile() throws {
        // The lock file can't be created (its folder is a regular file): the body never runs unlocked.
        let blocker = tmp.appendingPathComponent("blocker")
        try write("x", blocker)
        var ran = false
        XCTAssertThrowsError(try FileLock.with(blocker.appendingPathComponent("acme.json")) { ran = true }) { e in
            XCTAssertTrue(e is FileLock.Unavailable, "\(e)")
        }
        XCTAssertFalse(ran)
        XCTAssertThrowsError(try Project(slug: "acme", title: "Acme").save(in: blocker))
    }
}

final class ProjectTitleTests: XCTestCase {
    private let list = [Project(slug: "acme", title: "Acme"), Project(slug: "luch", title: "Студия «Луч» ")]

    func testEmpty() {
        XCTAssertEqual(Project.titleProblem("  ", slug: "", among: list), .empty)
    }

    func testDuplicateIgnoresCaseAndSpaces() {
        XCTAssertEqual(Project.titleProblem(" acme ", slug: "", among: list), .duplicate)
        XCTAssertEqual(Project.titleProblem("студия «луч»", slug: "acme", among: list), .duplicate)
    }

    func testOwnNameIsFine() {
        XCTAssertNil(Project.titleProblem("ACME", slug: "acme", among: list), "переименование того же проекта")
        XCTAssertNil(Project.titleProblem("Northwind", slug: "", among: list))
    }
}
