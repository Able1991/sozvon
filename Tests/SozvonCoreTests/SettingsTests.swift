import Foundation
import XCTest
@testable import SozvonCore

@MainActor
final class SettingsTests: TempDirTestCase {
    func testEnvKeepsForeignKeysAndWritesContractKeys() throws {
        try write("HF_TOKEN=old\nCUSTOM=keep\n# comment\n", Paths.env)
        let s = Settings()
        XCTAssertEqual(s.hfToken, "old", "читает HF_TOKEN")
        s.name = "Аня"
        s.hfToken = "hf_new"
        s.assistant = .codex
        s.save()
        let env = try String(contentsOf: Paths.env, encoding: .utf8)
        XCTAssertTrue(env.contains("CUSTOM=keep"), "чужой ключ сохранён")
        XCTAssertTrue(env.contains("# comment"), "комментарий сохранён")
        XCTAssertTrue(env.contains(#"HF_TOKEN="hf_new""#) && !env.contains("HF_TOKEN=old"), "токен заменён")
        XCTAssertTrue(env.contains(#"SOZVON_ME="Аня""#) && env.contains(#"SOZVON_LLM="codex""#), "имя и помощник")
        XCTAssertTrue(env.contains(#"SOZVON_ENV_VERSION="1""#), "версия файла")
        let perm = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: Paths.env.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perm.intValue, 0o600, ".env только для владельца")
        let s2 = Settings()
        XCTAssertEqual(s2.assistant, .codex)
        XCTAssertEqual(s2.name, "Аня", "настройки перечитываются")
    }

    func testLegacyNameAliasIsMigrated() throws {
        try write("CALL_ME_NAME=Олег\nSOZVON_LLM=none\n", Paths.env)
        let s = Settings()
        XCTAssertEqual(s.name, "Олег", "старое имя ключа принимается")
        s.save()
        let env = try String(contentsOf: Paths.env, encoding: .utf8)
        XCTAssertTrue(env.contains(#"SOZVON_ME="Олег""#))
        XCTAssertFalse(env.contains("CALL_ME_NAME"), "старый ключ убран")
    }

    func testNewKeyWinsOverAlias() {
        let v = SettingsValues(env: ["CALL_ME_NAME": "old", "SOZVON_ME": "new"], detect: { .none })
        XCTAssertEqual(v.name, "new")
    }

    func testDefaultsAndParsing() {
        let v = SettingsValues(env: [:], detect: { .claude })
        XCTAssertEqual(v.assistant, .claude, "помощник по умолчанию: установленный")
        XCTAssertEqual(v.languages, [.ru])
        XCTAssertEqual(v.model, .turbo)
        let w = SettingsValues(env: ["SOZVON_LANGUAGE": "auto", "SOZVON_MODEL": "large-v3", "SOZVON_LANG_SWITCH": "1",
                                     "SOZVON_LLM": "bogus"], detect: { .none })
        XCTAssertEqual(w.languages, [])
        XCTAssertEqual(w.model, .large)
        XCTAssertTrue(w.languageSwitch)
        XCTAssertEqual(w.assistant, .none, "неизвестный помощник: определяем заново")
    }

    func testEnvMerge() {
        let out = EnvFile.merge("A=1\n# c\nB=2\n\n", set: [("B", "3"), ("C", "4")], remove: ["A"])
        XCTAssertEqual(out, "# c\nB=\"3\"\nC=\"4\"\n")
        XCTAssertEqual(EnvFile.dictionary("X = 1\n#Y=2\nZ=a=b"), ["X": "1", "Z": "a=b"])
    }

    func testEnvValuesQuotedAndReadBack() {
        let tricky = #"Иван #2 "Ваня" \ конец"#
        let out = EnvFile.merge("", set: [("SOZVON_ME", tricky), ("N", "a\nb")])
        XCTAssertEqual(out, #"SOZVON_ME="Иван #2 \"Ваня\" \\ конец""# + "\n" + #"N="a\nb""# + "\n",
                       "как читает python-dotenv: двойные кавычки, \\ и \" экранированы")
        XCTAssertEqual(EnvFile.dictionary(out), ["SOZVON_ME": tricky, "N": "a\nb"])
        XCTAssertEqual(EnvFile.dictionary("A='x #1'\nB=y # c\nC=\"q\" # c"), ["A": "x #1", "B": "y", "C": "q"],
                       "одинарные кавычки и комментарии после значения")
    }
}
