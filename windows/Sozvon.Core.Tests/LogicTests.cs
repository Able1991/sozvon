using Sozvon.Core.Calls;
using Sozvon.Core.Engine;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

public class TranscriptTests
{
    [Fact]
    public void Timestamps()
    {
        Assert.Equal(307, Transcript.Timestamp("05:07"));
        Assert.Equal(3723, Transcript.Timestamp("1:02:03"));
        Assert.Equal(3723, Transcript.Timestamp("01:02:03"));
        Assert.Null(Transcript.Timestamp("5:7"));
        Assert.Null(Transcript.Timestamp("05:60"));
        Assert.Null(Transcript.Timestamp("abc"));
    }

    [Fact]
    public void ParsesBothFormats()
    {
        var plain = Transcript.Parse("[00:05] Анна: Привет: всем")!.Value;
        Assert.Equal(new TranscriptLine(5, "Анна", "Привет: всем"), plain.Line);
        Assert.Equal("[00:05] Анна: ", plain.Prefix);
        var bold = Transcript.Parse("**[01:00] Иван:** текст")!.Value;
        Assert.Equal(new TranscriptLine(60, "Иван", "текст"), bold.Line);
        Assert.Equal(new TranscriptLine(1, "Я", ""), Transcript.Parse("[00:01] Я:")!.Value.Line);
        Assert.Null(Transcript.Parse("# Заголовок"));
        Assert.Null(Transcript.Parse("[aa:bb] Анна: x"));
    }

    [Fact]
    public void LinesReadsLfAndCrlf()
    {
        Assert.Equal(["Анна", "Иван"], Transcript.Lines("# h\r\n[00:00] Анна: a\r\n[00:01] Иван: b\r\n").Select(l => l.Speaker));
        Assert.Equal("a", Transcript.Lines("[00:00] Анна: a\r\n")[0].Text);
    }

    [Fact]
    public void RenameSwapAndPeopleHeader()
    {
        const string md = "# Звонок\nДлительность: 05:00 · Участники: Анна, Я\n\n**[00:00] Анна:** Привет\n**[00:02] Я:** Да\n";
        var renamed = Transcript.RenameSpeaker(md, "Анна", "Анна Петрова");
        Assert.Contains("Участники: Анна Петрова, Я", renamed);
        Assert.Contains("**[00:00] Анна Петрова:** Привет", renamed);
        var swapped = Transcript.SwapSpeakers(md, "Анна", "Я");
        Assert.Contains("Участники: Я, Анна", swapped);
        Assert.Contains("**[00:00] Я:** Привет", swapped);
    }

    [Fact]
    public void ReassignRebuildsPeopleAndKeepsLineEnds()
    {
        const string md = "Длительность: 05:00 · Участники: Анна, Я\r\n**[00:00] Анна:** Привет\r\n**[00:02] Я:** Да\r\n";
        var line = Transcript.Lines(md)[0];
        var result = Transcript.Reassign(md, line, 0, "Я")!;
        Assert.Contains("Участники: Я\r\n", result);
        Assert.Contains("**[00:00] Я:** Привет\r\n", result);
        Assert.Null(Transcript.Reassign(md, line, 1, "Иван"));
    }

    [Fact]
    public void FixWordIsWholeWordOnlyInTheChosenLine()
    {
        const string text = "[00:00] А: кот который\n[00:01] А: кот который\n";
        var second = Transcript.Lines(text)[1];
        var result = Transcript.Fix(text, second, 0, "кот", "пёс $1")!;
        Assert.Equal("[00:00] А: кот который\n[00:01] А: пёс $1 который\n", result);
        Assert.Null(Transcript.Fix(text, second, 0, "нет", "x"));
        Assert.True(Transcript.ContainsWord("кот", "кот"));
        Assert.False(Transcript.ContainsWord("который", "кот"));
    }

    [Fact]
    public void LineIndexAndCleanSpeakerAndOffsets()
    {
        Assert.Null(Transcript.LineIndex(1, [2, 5]));
        Assert.Equal(1, Transcript.LineIndex(5, [2, 5, 9]));
        Assert.Equal("Анна", Transcript.CleanSpeaker("  Анна "));
        Assert.Null(Transcript.CleanSpeaker("a:b"));
        Assert.Null(Transcript.CleanSpeaker(new string('x', 81)));
        Assert.Equal(new TrackOffsets(0.5, 0), TrackOffsets.From(new AudioTimes(10, 9.5)));
    }
}

public class TranscriptEditTests : TempFolders
{
    private string CallWithTranscript()
    {
        var dir = MakeCall("2026-11-04 15-01", new System.Text.Json.Nodes.JsonObject
        {
            ["status"] = "done",
            ["names"] = new System.Text.Json.Nodes.JsonArray("Анна"),
            ["speaker_tracks"] = new System.Text.Json.Nodes.JsonObject { ["Анна"] = "system", ["Я"] = "mic" },
        });
        WriteText(Path.Combine(dir, "transcript.txt"), "[00:00] Анна: Привет\n[00:02] Я: Да\n");
        WriteText(Path.Combine(dir, "transcript.md"), "**[00:00] Анна:** Привет\n**[00:02] Я:** Да\n");
        return dir;
    }

    [Fact]
    public void RenameUpdatesFilesNamesAndTracks()
    {
        var dir = CallWithTranscript();
        Assert.True(TranscriptEdit.RenameSpeaker(dir, "Анна", "Анна Петрова"));
        Assert.Contains("Анна Петрова: Привет", File.ReadAllText(Path.Combine(dir, "transcript.txt")));
        Assert.Contains("Анна Петрова:** Привет", File.ReadAllText(Path.Combine(dir, "transcript.md")));
        var c = Json(dir);
        Assert.Equal(["Анна Петрова"], Foundation.JsonFields.Texts(c, "names"));
        Assert.Equal("system", c["speaker_tracks"]!["Анна Петрова"]!.GetValue<string>());
        Assert.Null(c["speaker_tracks"]!["Анна"]);
        Assert.Equal(TranscriptEditFailure.NotFound, Assert.Throws<TranscriptEditException>(() => TranscriptEdit.RenameSpeaker(dir, "Нет", "X")).Failure);
        Assert.Equal(TranscriptEditFailure.BadName, Assert.Throws<TranscriptEditException>(() => TranscriptEdit.RenameSpeaker(dir, "Я", "a:b")).Failure);
    }

    [Fact]
    public void ReassignMarksTracksBoth()
    {
        var dir = CallWithTranscript();
        var line = Transcript.Lines(File.ReadAllText(Path.Combine(dir, "transcript.txt")))[0];
        Assert.True(TranscriptEdit.ReassignLine(dir, line, 0, "Я"));
        Assert.Equal("both", Json(dir)["speaker_tracks"]!["Я"]!.GetValue<string>());
    }
}

public class ProcessingQueueTests
{
    private const string A = @"C:\calls\a", B = @"C:\calls\b", C = @"C:\calls\c";

    private static ProcessingJob Job(string dir, ProcessingKind kind = ProcessingKind.Transcribe) => new(dir, kind);

    [Fact]
    public void OneAtATimeInOrder()
    {
        var q = new ProcessingQueue();
        Assert.Equal(QueueAdmission.Queued, q.Admit(A));
        q.Admit(B);
        q.Admit(C);
        Assert.Equal(Job(A), q.StartNext(false));
        Assert.Equal(Job(A), q.Running);
        Assert.Null(q.StartNext(false));
        Assert.Equal([Job(B), Job(C)], q.Waiting);
        q.Finish(A);
        Assert.Equal(Job(B), q.StartNext(false));
        q.Finish(B);
        Assert.Equal(Job(C), q.StartNext(false));
        q.Finish(C);
        Assert.Null(q.StartNext(false));
        Assert.True(q.IsEmpty);
    }

    [Fact]
    public void DuplicatesAndPathSpelling()
    {
        var q = new ProcessingQueue();
        q.Admit(A);
        Assert.True(q.Contains(@"C:\CALLS\.\a\"));
        Assert.Equal(QueueAdmission.Duplicate, q.Admit(A));
        q.StartNext(false);
        Assert.Equal(QueueAdmission.Duplicate, q.Admit(A, ProcessingKind.SummaryOnly));
    }

    [Fact]
    public void HeldAndEngineUpdateStopTheQueue()
    {
        var q = new ProcessingQueue();
        q.Admit(A);
        q.Admit(B);
        Assert.Null(q.StartNext(true));
        Assert.Equal(2, q.Waiting.Count);
        Assert.True(q.BeginEngineUpdate());
        Assert.False(q.BeginEngineUpdate());
        Assert.False(q.CanStartNext);
        Assert.Null(q.StartNext(false));
        q.EndEngineUpdate();
        Assert.Equal(Job(A), q.StartNext(false));
    }

    [Fact]
    public void RemoveTakesOnlyWaiting()
    {
        var q = new ProcessingQueue();
        q.Admit(A);
        q.Admit(B);
        q.StartNext(false);
        Assert.False(q.Remove(A));
        Assert.True(q.Remove(B));
        Assert.False(q.Contains(B));
    }
}

public class RunOutcomeTests
{
    [Fact]
    public void ParseLine()
    {
        Assert.Equal(new ResultLine(true, 0, ""), RunOutcome.ParseLine("RESULT: ok"));
        Assert.Equal(new ResultLine(true, 0, "abc"), RunOutcome.ParseLine("RESULT: ok abc"));
        Assert.Equal(new ResultLine(false, 4, "модель не скачана"), RunOutcome.ParseLine("RESULT: error 4 модель не скачана"));
        Assert.Equal(new ResultLine(false, 2, ""), RunOutcome.ParseLine("RESULT: error 2"));
        Assert.Equal(new ResultLine(false, null, "что-то"), RunOutcome.ParseLine("RESULT: error что-то"));
        Assert.Null(RunOutcome.ParseLine("STATUS: ok"));
        Assert.Null(RunOutcome.ParseLine("RESULT: maybe"));
    }

    [Fact]
    public void ExitCodes()
    {
        Assert.Equal(new RunOutcome.Ok(), RunOutcome.Parse(0, ["x", "RESULT: ok"]));
        Assert.Equal(new RunOutcome.NoAudio("нет звука"), RunOutcome.Parse(2, ["RESULT: error 2 нет звука"]));
        Assert.Equal(new RunOutcome.EngineBroken("нет torch"), RunOutcome.Parse(3, ["RESULT: error 3 нет torch"]));
        Assert.Equal(new RunOutcome.ModelMissing("нет модели"), RunOutcome.Parse(4, ["RESULT: error 4 нет модели"]));
        Assert.Equal(new RunOutcome.Damaged("битый файл"), RunOutcome.Parse(5, ["RESULT: error 5 битый файл", ""]));
        Assert.Equal(new RunOutcome.Failed(1, "ValueError: x"), RunOutcome.Parse(1, ["Traceback", "ValueError: x"]));
        Assert.Equal(new RunOutcome.Failed(143, ""), RunOutcome.Parse(143, []));
    }

    [Fact]
    public void ResultRefinesGenericCode()
    {
        Assert.Equal(new RunOutcome.ModelMissing("нет модели"), RunOutcome.Parse(1, ["RESULT: error 4 нет модели"]));
        Assert.Equal(new RunOutcome.Damaged("битый"), RunOutcome.Parse(0, ["RESULT: error 5 битый"]));
        Assert.Equal(new RunOutcome.Failed(1, "что-то"), RunOutcome.Parse(0, ["RESULT: error что-то"]));
        Assert.Equal(new RunOutcome.NoAudio("x"), RunOutcome.Parse(2, ["RESULT: error 4 x"]));
    }
}

public class EnvFileTests : TempFolders
{
    [Fact]
    public void Merge()
    {
        Assert.Equal("# c\nB=\"3\"\nC=\"4\"\n", EnvFile.Merge("A=1\n# c\nB=2\n\n", [("B", "3"), ("C", "4")], ["A"]));
        Assert.Equal(new Dictionary<string, string> { ["X"] = "1", ["Z"] = "a=b" }, EnvFile.ToDictionary("X = 1\n#Y=2\nZ=a=b"));
    }

    [Fact]
    public void QuotedValuesReadBack()
    {
        const string tricky = "Иван #2 \"Ваня\" \\ конец";
        var text = EnvFile.Merge("", [("SOZVON_ME", tricky), ("N", "a\nb")]);
        Assert.Equal("SOZVON_ME=\"Иван #2 \\\"Ваня\\\" \\\\ конец\"\nN=\"a\\nb\"\n", text);
        Assert.Equal(new Dictionary<string, string> { ["SOZVON_ME"] = tricky, ["N"] = "a\nb" }, EnvFile.ToDictionary(text));
        Assert.Equal(new Dictionary<string, string> { ["A"] = "x #1", ["B"] = "y", ["C"] = "q" }, EnvFile.ToDictionary("A='x #1'\nB=y # c\nC=\"q\" # c"));
    }

    [Fact]
    public void CrlfFilesAreHandled()
    {
        Assert.Equal(new Dictionary<string, string> { ["A"] = "1", ["B"] = "two" }, EnvFile.ToDictionary("A=1\r\nB=\"two\"\r\n"));
        Assert.Equal("KEEP=x\nA=\"2\"\n", EnvFile.Merge("KEEP=x\r\nA=1\r\n", [("A", "2")]));
    }

    [Fact]
    public void SaveKeepsForeignKeysAndComments()
    {
        var env = Path.Combine(Data, ".env");
        WriteText(env, "HF_TOKEN=old\nCUSTOM=keep\n# comment\n");
        new SettingsValues { Name = "Аня", Assistant = Assistant.Codex, Languages = [SpeechLanguage.Ru], Model = WhisperModel.GigaAm }.Save(env);
        var text = File.ReadAllText(env);
        Assert.Contains("CUSTOM=keep", text);
        Assert.Contains("# comment", text);
        Assert.Contains("HF_TOKEN=old", text);
        Assert.Contains("SOZVON_ME=\"Аня\"", text);
        Assert.Contains("SOZVON_LLM=\"codex\"", text);
        Assert.Contains("SOZVON_ENV_VERSION=\"1\"", text);
        Assert.NotEqual(0xEF, File.ReadAllBytes(env)[0]);
        var back = SettingsValues.Load(env, () => Assistant.None);
        Assert.Equal("Аня", back.Name);
        Assert.Equal(Assistant.Codex, back.Assistant);
        Assert.Equal(WhisperModel.GigaAm, back.Model);
    }

    [Fact]
    public void DefaultsAndParsing()
    {
        var v = SettingsValues.FromEnv(new Dictionary<string, string>(), () => Assistant.Claude);
        Assert.Equal(Assistant.Claude, v.Assistant);
        Assert.Equal([SpeechLanguage.Ru], v.Languages);
        Assert.Equal(WhisperModel.Turbo, v.Model);
        Assert.True(v.SyncVoices);
        var w = SettingsValues.FromEnv(new Dictionary<string, string>
        {
            ["SOZVON_LANGUAGE"] = "auto", ["SOZVON_MODEL"] = "large-v3", ["SOZVON_LANG_SWITCH"] = "1", ["SOZVON_LLM"] = "bogus", ["SOZVON_SYNC_AUDIO"] = "0",
        }, () => Assistant.None);
        Assert.Empty(w.Languages);
        Assert.Equal(WhisperModel.Large, w.Model);
        Assert.True(w.LanguageSwitch);
        Assert.Equal(Assistant.None, w.Assistant);
        Assert.False(w.SyncAudio);
    }

    [Fact]
    public void LanguageToggling()
    {
        Assert.Equal([SpeechLanguage.Ru, SpeechLanguage.En], SpeechLanguages.Toggling(SpeechLanguage.Ru, [SpeechLanguage.En]));
        Assert.Empty(SpeechLanguages.Toggling(SpeechLanguage.Auto, [SpeechLanguage.Ru]));
        Assert.Equal("auto", SpeechLanguages.Serialize([]));
    }
}

public class CallGuessTests
{
    private static readonly Project Acme = new("acme", "Acme", PeopleList: ["Анна Петрова"]);
    private static readonly Project Beta = new("beta", "Beta");
    private static readonly IReadOnlyList<Project> Projects = [Acme, Beta];
    private static readonly DateTimeOffset T0 = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

    private static (CallInfo Info, bool Sure) Fill(CallInfo? info = null, string last = "", CalendarEvent? e = null, HeardVoice[]? heard = null, DateTimeOffset? at = null) =>
        CallGuess.Fill(info ?? new CallInfo(), last, at ?? T0.AddSeconds(60), e, heard ?? [], Projects);

    private static CalendarEvent Meeting(string title, params string[] people) =>
        new(title, T0, T0.AddHours(1), AttendeeList: people.Select(p => new CalendarAttendee(p)).ToList(), HasCallLink: true);

    [Fact]
    public void CalendarAndVoicesAgree()
    {
        var r = Fill(e: Meeting("Acme: планирование", "Анна Петрова"), heard: [new("Анна Петрова", "acme", 300), new("Олег", "", 40)]);
        Assert.Equal("acme", r.Info.Profile);
        Assert.Equal("Анна Петрова, Олег", r.Info.Names);
        Assert.Equal("Acme: планирование", r.Info.Topic);
        Assert.True(r.Sure);
    }

    [Fact]
    public void VoicesAloneGiveTheProject()
    {
        var r = Fill(heard: [new("Анна Петрова", "acme", 120)]);
        Assert.Equal("acme", r.Info.Profile);
        Assert.True(r.Sure);
    }

    [Fact]
    public void DisagreementAndNothingKnown()
    {
        var r = Fill(e: Meeting("Acme sync", "Анна Петрова"), heard: [new("Пётр", "beta", 300)]);
        Assert.Equal("acme", r.Info.Profile);
        Assert.False(r.Sure);
        var none = Fill();
        Assert.Equal(new CallInfo(), none.Info);
        Assert.False(none.Sure);
    }

    [Fact]
    public void TypedStaysAndLastProjectIsNotEvidence()
    {
        var typed = Fill(new CallInfo { Profile = "beta", Names = "Маша" }, heard: [new("Анна Петрова", "acme", 300)]);
        Assert.Equal("Маша", typed.Info.Names);
        Assert.Equal("beta", typed.Info.Profile);
        var seeded = Fill(new CallInfo { Profile = "acme" }, "acme", heard: [new("Пётр", "beta", 120)]);
        Assert.Equal("beta", seeded.Info.Profile);
        Assert.True(seeded.Sure);
        var kept = Fill(new CallInfo { Profile = "acme" }, "acme", Meeting("Созвон", "Иван"));
        Assert.Equal("acme", kept.Info.Profile);
        Assert.False(kept.Sure);
    }

    [Fact]
    public void MeetingMustBeGoingOnAndShortVoicesAreNotEnough()
    {
        var ev = Meeting("Acme sync", "Анна Петрова");
        Assert.True(Fill(e: ev, at: T0.AddSeconds(-120)).Sure);
        Assert.False(Fill(e: ev, at: T0.AddSeconds(3900)).Sure);
        Assert.False(Fill(heard: [new("Анна Петрова", "acme", 8)]).Sure);
        var unsure = Fill(e: Meeting("Созвон", "Иван"), heard: [new("Влад", "acme", 600, true)], at: T0.AddHours(2));
        Assert.Equal("acme", unsure.Info.Profile);
        Assert.Equal("Иван", unsure.Info.Names);
        Assert.False(unsure.Sure);
    }

    [Fact]
    public void AReflectionIsNeverSure()
    {
        var r = CallGuess.Fill(new CallInfo { Profile = "acme", Names = "Анна", Topic = "мысли", Reflection = true }, "", T0, null, [], Projects);
        Assert.False(r.Sure);
    }

    [Fact]
    public void SameNameAndBestEvent()
    {
        Assert.True(CallGuess.Same("Анна", "анна петрова"));
        Assert.False(CallGuess.Same("Анна Петрова", "Анна Смирнова"));
        var plain = new CalendarEvent("x", T0, T0.AddHours(1));
        var linked = new CalendarEvent("y", T0, T0.AddHours(1), HasCallLink: true);
        Assert.Equal(linked, CalendarMatch.Best([plain, linked], T0));
        Assert.Null(CalendarMatch.Best([plain], T0.AddHours(3)));
        Assert.Equal(["ivan.petrov"], CalendarMatch.People(new CalendarEvent("x", T0, T0, AttendeeList: [new("", "ivan.petrov@x.io"), new("Я", IsMe: true)])));
    }
}

public class RecordingMachineTests
{
    private const string Dir = @"C:\calls\a", Other = @"C:\calls\b";

    private static RecordingSession Session(string dir = Dir) => new(dir, DateTimeOffset.UnixEpoch, new CallInfo());

    [Fact]
    public void HappyPath()
    {
        var m = new RecordingMachine();
        Assert.Equal("idle", m.State.Name);
        Assert.True(m.Begin(Dir));
        Assert.Equal("starting", m.State.Name);
        Assert.True(m.Started(Session()));
        Assert.True(m.UpdateInfo(new CallInfo { Profile = "acme" }));
        Assert.Equal("acme", m.Stop(Task.CompletedTask)!.Info.Profile);
        Assert.True(m.State.IsCapturing);
        Assert.True(m.Finalized());
        Assert.Equal("saved", m.State.Name);
        Assert.True(m.DismissSaved(Dir));
        Assert.Equal("idle", m.State.Name);
    }

    [Fact]
    public void InvalidTransitions()
    {
        var m = new RecordingMachine();
        Assert.False(m.StartFailed());
        Assert.Null(m.Stop(Task.CompletedTask));
        Assert.False(m.Finalized());
        m.Begin(Dir);
        Assert.False(m.Begin(Other));
        Assert.False(m.Started(Session(Other)));
        Assert.True(m.StartFailed());
    }

    [Fact]
    public void NewRecordingWhileSavedQuestionOpen()
    {
        var m = new RecordingMachine();
        m.Begin(Dir);
        m.Started(Session());
        m.Stop(Task.CompletedTask);
        m.Finalized();
        Assert.True(m.Begin(Other));
        Assert.False(m.DismissSaved(Dir));
        Assert.True(m.State.IsStarting);
    }

    [Fact]
    public void Elapsed() => Assert.Equal("12:34", Session().Elapsed(DateTimeOffset.FromUnixTimeSeconds(754)));
}

public class ReminderPlannerTests
{
    private static readonly DateTimeOffset T0 = DateTimeOffset.FromUnixTimeSeconds(2_000_000);
    private static DateTimeOffset At(double minutes) => T0.AddMinutes(minutes);
    private static readonly PendingCall A = new(@"C:\c\a", "2026-11-04 15-04", null), B = new(@"C:\c\b", "2026-11-04 16-00", null);

    [Fact]
    public void WaitsForTenIdleMinutesAndRepeatsHourly()
    {
        var r = new ReminderPlanner(At(0));
        Assert.Empty(r.Due([A], At(9.9), false));
        Assert.Equal([A], r.Due([A], At(10), false));
        Assert.Empty(r.Due([A], At(30), false));
        Assert.Equal([B], r.Due([A, B], At(40), false));
        Assert.Equal([A], r.Due([A, B], At(70), false));
    }

    [Fact]
    public void NeverWhileBusyAndBusyResetsIdle()
    {
        var r = new ReminderPlanner(At(0));
        Assert.Empty(r.Due([A], At(30), true));
        r.Activity(false, At(40));
        Assert.Empty(r.Due([A], At(49), false));
        Assert.Equal([A], r.Due([A], At(50), false));
    }

    [Fact]
    public void DescribedCallIsForgotten()
    {
        var r = new ReminderPlanner(At(0));
        Assert.Equal([A], r.Due([A], At(10), false));
        Assert.Empty(r.Due([], At(11), false));
        Assert.Equal([A], r.Due([A], At(12), false));
    }
}

public class CallListTests : TempFolders
{
    private Call Make(string id, string profile = "", bool reflection = false)
    {
        var fields = new System.Text.Json.Nodes.JsonObject { ["status"] = "done" };
        if (profile.Length > 0) fields["profile"] = profile;
        if (reflection) fields["kind"] = "reflection";
        return Call.Load(MakeCall(id, fields))!;
    }

    [Fact]
    public void Filters()
    {
        var acme = Make("2026-11-05 10-00", "acme");
        var other = Make("2026-11-05 11-00", "other");
        var reflection = Make("2026-11-05 12-00", reflection: true);
        Call[] all = [acme, other, reflection];
        Assert.Equal(3, CallFilter.Apply(all, "").Count);
        Assert.Equal([acme], CallFilter.Apply(all, "acme"));
        Assert.Equal([reflection], CallFilter.Apply(all, CallFilter.Reflections));
        Assert.True(CallFilter.IsShown(other, "acme", isLive: true));
        Assert.False(CallFilter.IsShown(other, "acme", isLive: false));
    }

    [Fact]
    public void DayGroupsKeepOrderAndLabels()
    {
        var now = Call.ParseId("2026-11-05 18-00")!.Value;
        var labels = new CallDays.Labels("Today", "Yesterday", "Undated", _ => "OLD");
        var t1 = Make("2026-11-05 10-00");
        var t2 = Make("2026-11-05 09-00");
        var y = Make("2026-11-04 23-59");
        var old = Make("2026-10-01 08-00");
        var undated = Make("no-date-folder");
        var groups = CallDays.Group([t1, t2, y, old, undated], now, labels);
        Assert.Equal(["Today", "Yesterday", "OLD", "Undated"], groups.Select(g => g.Title));
        Assert.Equal([t1, t2], groups[0].Calls);
    }
}
