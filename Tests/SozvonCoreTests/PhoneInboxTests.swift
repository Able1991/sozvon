// Recordings from the phone: which files of the watched folder are ready, and where they go afterwards.

import Foundation
import XCTest
@testable import SozvonCore

final class PhoneInboxTests: XCTestCase {
    var dir: URL!
    let fm = FileManager.default
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: dir) }

    @discardableResult
    func file(_ name: String, age: TimeInterval = 600) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: u)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: u.path)
        return u
    }

    func testOnlyFinishedAudioIsReady() throws {
        try file("Заметка.m4a")
        try file("b.MP3")
        try file("notes.txt")
        try file(".hidden.m4a")
        try file("still-copying.m4a", age: 2)
        XCTAssertEqual(PhoneInbox.scan(dir, now: now).ready.map(\.lastPathComponent).sorted(), ["b.MP3", "Заметка.m4a"].sorted())
    }

    func testICloudPlaceholdersAreAskedToDownload() throws {
        try file(".Заметка.m4a.icloud")
        try file(".notes.txt.icloud")
        let s = PhoneInbox.scan(dir, now: now)
        XCTAssertEqual(s.ready, [])
        XCTAssertEqual(s.notDownloaded.map(\.lastPathComponent), [".Заметка.m4a.icloud"])
    }

    func testOldestFirst() throws {
        try file("new.m4a", age: 100)
        try file("old.m4a", age: 5000)
        XCTAssertEqual(PhoneInbox.scan(dir, now: now).ready.map(\.lastPathComponent), ["old.m4a", "new.m4a"])
    }

    func testSubfoldersAreLeftAlone() throws {
        let sub = dir.appendingPathComponent(PhoneInbox.doneFolder)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("done.m4a"))
        XCTAssertEqual(PhoneInbox.scan(dir, now: now).ready, [])
    }

    func testFileMovesAsideAndNeverOverwrites() throws {
        let a = try file("a.m4a")
        let moved = try PhoneInbox.moveAside(a, to: PhoneInbox.doneFolder)
        XCTAssertEqual(moved.lastPathComponent, "a.m4a")
        XCTAssertFalse(fm.fileExists(atPath: a.path))
        let again = try file("a.m4a")
        let second = try PhoneInbox.moveAside(again, to: PhoneInbox.doneFolder)
        XCTAssertEqual(second.lastPathComponent, "a 2.m4a")
        XCTAssertTrue(fm.fileExists(atPath: moved.path))
    }

    func testShortcutHelpOpensTheSectionInTheInterfaceLanguage() {
        XCTAssertEqual(PhoneInbox.shortcutDocsURL(language: "ru").fragment, "phone-shortcut")
        XCTAssertEqual(PhoneInbox.shortcutDocsURL(language: "en").fragment, "en-phone-shortcut")
    }

    func testMoveAsideOutOfTheDoneFolderGoesNextToIt() throws {
        let a = dir.appendingPathComponent("a.m4a")
        try Data("x".utf8).write(to: a)
        let claimed = try PhoneInbox.moveAside(a, to: PhoneInbox.doneFolder)
        let failed = try PhoneInbox.moveAside(claimed, to: PhoneInbox.failedFolder, in: dir)
        XCTAssertEqual(failed.deletingLastPathComponent().standardizedFileURL,
                       dir.appendingPathComponent(PhoneInbox.failedFolder).standardizedFileURL)
    }

    func testTopicComesFromAGivenNameOnly() {
        XCTAssertEqual(PhoneInbox.topic(of: URL(fileURLWithPath: "/x/Идея про тарифы.m4a")), "Идея про тарифы")
        XCTAssertEqual(PhoneInbox.topic(of: URL(fileURLWithPath: "/x/New Recording 12.m4a")), "")
        XCTAssertEqual(PhoneInbox.topic(of: URL(fileURLWithPath: "/x/Think Out Loud 2.m4a")), "", "our iPhone shortcut's file name")
        XCTAssertEqual(PhoneInbox.topic(of: URL(fileURLWithPath: "/x/Новая запись 3.m4a")), "")
        XCTAssertEqual(PhoneInbox.topic(of: URL(fileURLWithPath: "/x/20261108 121314.m4a")), "")
    }
}
