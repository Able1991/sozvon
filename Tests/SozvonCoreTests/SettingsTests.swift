import Foundation
import XCTest
@testable import SozvonCore

@MainActor
final class SettingsTests: TempDirTestCase {
    func testEnvKeepsForeignKeysAndWritesContractKeys() throws {
        try write("HF_TOKEN=old\nCUSTOM=keep\n# comment\n", Paths.env)
        let s = Settings()
        s.name = "Аня"
        s.assistant = .codex
        s.save()
        let env = try String(contentsOf: Paths.env, encoding: .utf8)
        XCTAssertTrue(env.contains("CUSTOM=keep"), "a foreign key is kept")
        XCTAssertTrue(env.contains("# comment"), "the comment is kept")
        XCTAssertTrue(env.contains("HF_TOKEN=old"), "a hand-set HF_TOKEN is kept as is")
        XCTAssertTrue(env.contains(#"SOZVON_ME="Аня""#) && env.contains(#"SOZVON_LLM="codex""#), "name and assistant")
        XCTAssertTrue(env.contains(#"SOZVON_ENV_VERSION="1""#), "file version")
        let perm = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: Paths.env.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perm.intValue, 0o600, ".env is for the owner only")
        let s2 = Settings()
        XCTAssertEqual(s2.assistant, .codex)
        XCTAssertEqual(s2.name, "Аня", "settings are read again")
    }

    func testLegacyNameAliasIsMigrated() throws {
        try write("CALL_ME_NAME=Олег\nSOZVON_LLM=none\n", Paths.env)
        let s = Settings()
        XCTAssertEqual(s.name, "Олег", "the old key name is accepted")
        s.save()
        let env = try String(contentsOf: Paths.env, encoding: .utf8)
        XCTAssertTrue(env.contains(#"SOZVON_ME="Олег""#))
        XCTAssertFalse(env.contains("CALL_ME_NAME"), "the old key is removed")
    }

    func testNewKeyWinsOverAlias() {
        let v = SettingsValues(env: ["CALL_ME_NAME": "old", "SOZVON_ME": "new"], detect: { .none })
        XCTAssertEqual(v.name, "new")
    }

    func testDefaultsAndParsing() {
        let v = SettingsValues(env: [:], detect: { .claude })
        XCTAssertEqual(v.assistant, .claude, "default assistant: the installed one")
        XCTAssertEqual(v.languages, [.ru])
        XCTAssertEqual(v.model, .turbo)
        let w = SettingsValues(env: ["SOZVON_LANGUAGE": "auto", "SOZVON_MODEL": "large-v3", "SOZVON_LANG_SWITCH": "1",
                                     "SOZVON_LLM": "bogus"], detect: { .none })
        XCTAssertEqual(w.languages, [])
        XCTAssertEqual(w.model, .large)
        XCTAssertTrue(w.languageSwitch)
        XCTAssertEqual(w.assistant, .none, "unknown assistant: detect again")
    }

    func testCursorAssistantRoundTrips() throws {
        XCTAssertEqual(SettingsValues(env: ["SOZVON_LLM": "cursor"], detect: { .none }).assistant, .cursor)
        let s = Settings()
        s.assistant = .cursor
        s.save()
        let env = try String(contentsOf: Paths.env, encoding: .utf8)
        XCTAssertTrue(env.contains(#"SOZVON_LLM="cursor""#))
        XCTAssertEqual(Settings().assistant, .cursor)
        XCTAssertEqual(Assistant.cursor.cli, "cursor-agent")
        XCTAssertEqual(Assistant.cursor.vendor, "Cursor")
    }

    /// Voice prints are biometric data: they go to the own server only when the user turned that on.
    func testSyncVoicesIsOptIn() throws {
        let server = ["SOZVON_SERVER_URL": "https://x.workers.dev", "SOZVON_SERVER_PASSWORD": "a-long-enough-password-1"]
        func values(_ extra: [String: String]) -> SettingsValues {
            SettingsValues(env: server.merging(extra) { $1 }, detect: { .none })
        }
        XCTAssertFalse(SettingsValues().syncVoices, "a new install: off")
        XCTAssertFalse(values([:]).syncVoices, "a connected server, the key absent: off")
        XCTAssertTrue(values(["SOZVON_SYNC_VOICES": "1"]).syncVoices, "a connected server with the key on: kept")
        XCTAssertFalse(values(["SOZVON_SYNC_VOICES": "0"]).syncVoices)
        XCTAssertFalse(SettingsValues(env: ["SOZVON_SYNC_VOICES": "1"], detect: { .none }).syncVoices,
                       "no server: the 1 older versions wrote on every save was never a choice")
        XCTAssertTrue(SettingsValues.managedKeys.contains("SOZVON_SYNC_VOICES"))
    }

    func testSyncVoicesRoundTripsAndANewServerStartsOff() throws {
        // What 0.1.5 and older left in .env for a user without a server.
        try write("SOZVON_SYNC_VOICES=\"1\"\n", Paths.env)
        let s = Settings()
        XCTAssertFalse(s.syncVoices)
        s.serverURL = "https://x.workers.dev"
        s.serverPassword = "a-long-enough-password-1"
        s.save()
        XCTAssertTrue(try String(contentsOf: Paths.env, encoding: .utf8).contains(#"SOZVON_SYNC_VOICES="0""#),
                      "connecting a server does not turn voice prints on")
        s.syncVoices = true
        s.save()
        XCTAssertTrue(try String(contentsOf: Paths.env, encoding: .utf8).contains(#"SOZVON_SYNC_VOICES="1""#))
        XCTAssertTrue(Settings().syncVoices, "read back")
        s.serverURL = ""
        s.serverPassword = ""
        s.save()
        XCTAssertFalse(s.syncVoices, "the server is gone: the next one starts off")
        XCTAssertTrue(try String(contentsOf: Paths.env, encoding: .utf8).contains(#"SOZVON_SYNC_VOICES="0""#))
        s.serverURL = "https://y.workers.dev"
        s.serverPassword = "a-long-enough-password-2"
        s.save()
        XCTAssertFalse(Settings().syncVoices)
    }

    func testSyncAudioDefaultsOnAndRoundTrips() throws {
        XCTAssertTrue(SettingsValues(env: [:], detect: { .none }).syncAudio, "absent key: on")
        XCTAssertFalse(SettingsValues(env: ["SOZVON_SYNC_AUDIO": "0"], detect: { .none }).syncAudio)
        XCTAssertTrue(SettingsValues.managedKeys.contains("SOZVON_SYNC_AUDIO"))
        let s = Settings()
        s.syncAudio = false
        s.save()
        XCTAssertTrue(try String(contentsOf: Paths.env, encoding: .utf8).contains(#"SOZVON_SYNC_AUDIO="0""#))
        let back = Settings()
        XCTAssertFalse(back.syncAudio, "read back")
        XCTAssertFalse(back.syncVoices, "the other toggle is independent")
        XCTAssertTrue(SettingsValues().syncAudio, "call audio stays on by default")
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
                       "as python-dotenv reads it: double quotes, \\ and \" are escaped")
        XCTAssertEqual(EnvFile.dictionary(out), ["SOZVON_ME": tricky, "N": "a\nb"])
        XCTAssertEqual(EnvFile.dictionary("A='x #1'\nB=y # c\nC=\"q\" # c"), ["A": "x #1", "B": "y", "C": "q"],
                       "single quotes and comments after the value")
    }

    func testSilenceAlertsDefaultOnAndFollowTheKey() throws {
        let suite = "sozvon.tests.silence.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertTrue(SilenceAlerts.isEnabled(in: d), "on by default")
        d.set(false, forKey: SilenceAlerts.key)
        XCTAssertFalse(SilenceAlerts.isEnabled(in: d), "off when the key says so")
        d.set(true, forKey: SilenceAlerts.key)
        XCTAssertTrue(SilenceAlerts.isEnabled(in: d))
    }
}

final class LanguageChoiceTests: XCTestCase {
    func testTogglingKeepsCanonicalOrder() {
        XCTAssertEqual(SpeechLanguage.toggling(.ru, in: [.en]), [.ru, .en], "order as in the list of languages")
        XCTAssertEqual(SpeechLanguage.toggling(.en, in: [.ru, .en]), [.ru], "a second click removes the language")
        XCTAssertEqual(SpeechLanguage.toggling(.de, in: []), [.de], "from \"detect automatically\" to one language")
    }

    func testTogglingAutoClears() {
        XCTAssertEqual(SpeechLanguage.toggling(.auto, in: [.ru, .en]), [])
        XCTAssertEqual(SpeechLanguage.toggling(.ru, in: [.ru]), [], "removing the last language means detect automatically")
    }

    func testInterfaceLanguageTag() {
        XCTAssertEqual(InterfaceLanguage.tag(nil), "", "no override: as in the system")
        XCTAssertEqual(InterfaceLanguage.tag([]), "")
        XCTAssertEqual(InterfaceLanguage.tag(["ru-RU"]), "ru", "the region is dropped")
        XCTAssertEqual(InterfaceLanguage.tag(["en_GB", "ru"]), "en")
        XCTAssertEqual(InterfaceLanguage.tag(["fr"]), "", "an untranslated language shows as the system one")
    }
}

/// The summary language: absent or "auto" is the conversation's; a chosen one goes to the engine as SOZVON_SUMMARY_LANGUAGE.
final class SummaryLanguageSettingTests: XCTestCase {
    func testByDefaultTheSummaryFollowsTheConversation() {
        let v = SettingsValues(env: [:], detect: { .none })
        XCTAssertNil(v.summaryLanguage)
        XCTAssertTrue(v.pairs.contains { $0 == (SettingsValues.Key.summaryLanguage, "auto") })
    }

    func testAChosenLanguageIsSavedAndRead() {
        var v = SettingsValues(env: [:], detect: { .none })
        v.summaryLanguage = .ru
        XCTAssertTrue(v.pairs.contains { $0 == (SettingsValues.Key.summaryLanguage, "ru") })
        XCTAssertEqual(SettingsValues(env: [SettingsValues.Key.summaryLanguage: "ru"], detect: { .none }).summaryLanguage, .ru)
        XCTAssertNil(SettingsValues(env: [SettingsValues.Key.summaryLanguage: "auto"], detect: { .none }).summaryLanguage)
        XCTAssertNil(SettingsValues(env: [SettingsValues.Key.summaryLanguage: "klingon"], detect: { .none }).summaryLanguage)
    }
}

/// The summary language: absent or "auto" is the conversation's; a chosen one goes to the engine as SOZVON_SUMMARY_LANGUAGE.
final class SummaryLanguageSettingTests: XCTestCase {
    func testByDefaultTheSummaryFollowsTheConversation() {
        let v = SettingsValues(env: [:], detect: { .none })
        XCTAssertNil(v.summaryLanguage)
        XCTAssertTrue(v.pairs.contains { $0 == (SettingsValues.Key.summaryLanguage, "auto") })
    }

    func testAChosenLanguageIsSavedAndRead() {
        var v = SettingsValues(env: [:], detect: { .none })
        v.summaryLanguage = .ru
        XCTAssertTrue(v.pairs.contains { $0 == (SettingsValues.Key.summaryLanguage, "ru") })
        XCTAssertEqual(SettingsValues(env: [SettingsValues.Key.summaryLanguage: "ru"], detect: { .none }).summaryLanguage, .ru)
        XCTAssertNil(SettingsValues(env: [SettingsValues.Key.summaryLanguage: "auto"], detect: { .none }).summaryLanguage)
        XCTAssertNil(SettingsValues(env: [SettingsValues.Key.summaryLanguage: "klingon"], detect: { .none }).summaryLanguage)
    }
}
