using System.Text.Json.Nodes;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;
using Sozvon.Core.Foundation;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

public class CallFolderNameTests
{
    private static string Name(string current, CallInfo info, string? project = null, IReadOnlyList<string>? people = null, string? root = null) =>
        CallFolderName.Build(current, info, project, people, root);

    [Fact]
    public void FullNameAndRenameKeepsOnlyTheDate()
    {
        var named = CallFolderName.Build("2026-11-04 15-01", new CallInfo { Profile = "acme", Names = "Анна, Иван", Topic = "запуск: этап 1/2" },
                                         [new Project("acme", "Acme / Holding")]);
        Assert.Equal("2026-11-04 15-01 · Acme · запуск- этап 1-2 · Анна, Иван", named);
        Assert.Equal("2026-11-04 15-01 · Олег", Name(named, new CallInfo { Names = "Олег" }));
    }

    [Fact]
    public void EdgeCasesLikeTheMac()
    {
        Assert.Equal("2026-11-04 15-01", Name("2026-11-04 15-01", new CallInfo()));
        Assert.Equal(120, Name("2026-11-04 15-01", new CallInfo { Topic = new string('x', 300) }).Length);
        Assert.Equal("short · t", Name("short", new CallInfo { Topic = "t" }));
        Assert.Equal("2026-11-04 15-01 · a b c", Name("2026-11-04 15-01", new CallInfo { Topic = "a\nb\tc" }));
        Assert.Equal("2026-11-04 15-01 · a-b", Name("2026-11-04 15-01", new CallInfo { Topic = "a\\b" }));
        Assert.Equal("2026-11-04 15-01", Name("2026-11-04 15-01", new CallInfo { Names = " ,  , " }, "  "));
        Assert.Equal("2026-11-04 15-01 · Анна, Иван", Name("2026-11-04 15-01", new CallInfo { Names = "Анна,Иван ," }));
        var cut = Name("2026-11-04 15-01", new CallInfo { Names = "Анна", Topic = new string('x', 101) });
        Assert.False(cut.EndsWith(' ') || cut.EndsWith('·'));
        Assert.True(cut.Length <= 120);
    }

    [Fact]
    public void WindowsForbiddenCharactersAndEndings()
    {
        Assert.Equal("2026-11-04 15-01 · a-b--c-d-e--f", Name("2026-11-04 15-01", new CallInfo { Topic = "a<b>:c|d?e*\"f" }));
        Assert.Equal("2026-11-04 15-01 · конец", Name("2026-11-04 15-01", new CallInfo { Topic = "конец..." }));
        Assert.Equal("2026-11-04 15-01 · ab", Name("2026-11-04 15-01", new CallInfo { Topic = "a\u0001b" }));
    }

    [Fact]
    public void ManyPeopleAreShortened()
    {
        Assert.Equal("2026-11-04 15-01 · Acme · планёрка · Анна, Олег, Иван +3",
                     Name("2026-11-04 15-01", new CallInfo { Names = "Анна, Олег, Иван, Мария, Пётр, Ли", Topic = "планёрка" }, "Acme"));
        Assert.Equal("Анна, Олег +4", TextRules.ShortPeople(["Анна", "Олег", "Иван", "Мария", "Пётр", "Ли"]));
    }

    [Fact]
    public void LongCallsFolderShortensTheNameToFitMaxPath()
    {
        var root = "C:\\" + new string('r', 150);
        var name = Name("2026-11-04 15-01", new CallInfo { Topic = new string('x', 200) }, root: root);
        Assert.True(root.Length + 1 + name.Length + 1 + 48 < 260, name);
        Assert.StartsWith("2026-11-04 15-01", name);
    }
}

public class CallFileTests : TempFolders
{
    private string Folder(string name)
    {
        var dir = Path.Combine(Calls, name);
        Directory.CreateDirectory(dir);
        return dir;
    }

    [Fact]
    public void RecordStoppedThenInfoKeepsEngineFields()
    {
        var dir = Folder("2026-11-04 15-01");
        var audio = new AudioTimes(10, 9.5, 60, 61);
        Assert.True(CallFile.RecordStopped(dir, DateTimeOffset.UnixEpoch, audio));
        var c = CallFile.Read(dir);
        Assert.Equal(1, c.Int("schema"));
        Assert.Equal("2026-11-04 15-01", c.Text("id"));
        Assert.Equal("recorded", c.Text("status"));
        Assert.Equal("1970-01-01T00:00:00Z", c.Text("created_at"));
        Assert.Equal(audio, AudioTimes.From(c.Object("audio")));

        CallFile.Update(dir, x => x["engine"] = new JsonObject { ["version"] = "abc", ["model"] = "turbo" });
        var info = new CallInfo { Profile = "acme", Names = "Анна, Иван", Topic = " запуск ", Terms = "HPA", Summary = false, Languages = [SpeechLanguage.Ru, SpeechLanguage.En] };
        CallFile.WriteInfo(dir, info);
        c = CallFile.Read(dir);
        Assert.Equal(["Анна", "Иван"], c.Texts("names"));
        Assert.Equal("запуск", c.Text("topic"));
        Assert.Equal("ru,en", c.Text("languages"));
        Assert.False(c.Flag("summary"));
        Assert.Equal("abc", c.Object("engine")!.Text("version"));
        Assert.Equal("recorded", c.Text("status"));
        Assert.Equal(info with { Topic = "запуск" }, CallFile.Info(c));
        Assert.Empty(Directory.GetFiles(dir, "*.tmp"));
        Assert.True(File.Exists(Path.Combine(dir, CallFile.LockName)));
    }

    [Fact]
    public void WrittenFileIsUtf8WithoutBomAndSchemaFirst()
    {
        var dir = Folder("2026-11-04 15-01");
        File.WriteAllText(CallFile.PathIn(dir), "{\"topic\": \"тема\", \"unknown_field\": {\"a\": [1, 2]}}");
        CallFile.Update(dir, c => c["schema"] = 1);
        var bytes = File.ReadAllBytes(CallFile.PathIn(dir));
        Assert.NotEqual(0xEF, bytes[0]);
        var text = System.Text.Encoding.UTF8.GetString(bytes);
        Assert.Contains("тема", text);
        Assert.True(text.IndexOf("schema") < text.IndexOf("topic"));
        Assert.Contains("unknown_field", text);
    }

    [Fact]
    public void BrokenFileIsNotOverwrittenByStrictEdit()
    {
        var dir = Folder("2026-11-04 15-01");
        File.WriteAllText(CallFile.PathIn(dir), "{broken");
        Assert.Throws<CallFileCorruptException>(() => CallFile.Edit(dir, _ => true));
        Assert.Equal("{broken", File.ReadAllText(CallFile.PathIn(dir)));
    }

    [Fact]
    public void AGoneFolderIsNeverRecreated()
    {
        var gone = Path.Combine(Calls, "2026-11-04 16-00");
        Assert.False(CallFile.SetStatus(gone, CallStatus.Failed));
        Assert.False(CallFile.SetFailedUnlessDone(gone));
        Assert.False(Directory.Exists(gone));
    }

    [Fact]
    public void StoppedRunKeepsAFinishedCallDoneAndFailsAnUnfinishedOne()
    {
        var dir = MakeCall("2026-11-04 15-01");
        CallFile.SetStatus(dir, CallStatus.Done);
        CallFile.SetFailedUnlessDone(dir);
        Assert.Equal("done", Json(dir).Text("status"));
        CallFile.SetStatus(dir, CallStatus.Processing);
        CallFile.SetFailedUnlessDone(dir);
        Assert.Equal("failed", Json(dir).Text("status"));
    }

    [Fact]
    public void ALockHeldHereMakesASecondWriterWaitAndTimeOut()
    {
        var dir = Folder("2026-11-04 15-01");
        using var hold = new ManualResetEventSlim();
        var holder = Task.Run(() => FileLock.With(CallFile.PathIn(dir), () =>
        {
            hold.Wait();
            return true;
        }));
        SpinWait.SpinUntil(() => File.Exists(FileLock.LockPath(CallFile.PathIn(dir))), 2000);
        Thread.Sleep(100);
        Assert.Throws<FileLockTimeoutException>(() => FileLock.With(CallFile.PathIn(dir), () => true, TimeSpan.FromMilliseconds(200)));
        hold.Set();
        holder.Wait();
    }

    [Fact]
    public void CallIdComesFromCallJsonOtherwiseTheName()
    {
        var dir = MakeCall("2026-11-04 15-01-2", folder: "2026-11-04 15-01 · Лишнее");
        Assert.Equal("2026-11-04 15-01-2", CallFile.CallId(dir));
        Assert.Equal("2026-01-02 03-04", CallFile.CallId(Folder("2026-01-02 03-04 · old")));
    }
}

public class CallFolderTests : TempFolders
{
    private static readonly DateTimeOffset Minute = new(new DateTime(2026, 11, 4, 15, 1, 7, DateTimeKind.Local));

    [Fact]
    public void IdFromName()
    {
        Assert.Equal("2026-11-04 15-01", CallFolder.IdFromName("2026-11-04 15-01"));
        Assert.Equal("2026-11-04 15-01", CallFolder.IdFromName("2026-11-04 15-01 · Acme · -2"));
        Assert.Equal("2026-11-04 15-01-2", CallFolder.IdFromName("2026-11-04 15-01-2"));
        Assert.Equal("2026-11-04 15-01-12", CallFolder.IdFromName("2026-11-04 15-01-12 · Acme"));
        Assert.Equal("2026-11-04 15-01", CallFolder.IdFromName("2026-11-04 15-01-x"));
        Assert.Equal("Разное", CallFolder.IdFromName("Разное"));
    }

    [Fact]
    public void ParseId()
    {
        Assert.NotNull(Call.ParseId("2026-11-04 15-01 · что угодно"));
        Assert.Null(Call.ParseId("2026-13-04 15-01"));
        Assert.Null(Call.ParseId("not a date at all"));
        Assert.Null(Call.ParseId("2026-11-04"));
    }

    [Fact]
    public void SameMinuteGetsANewFolderAndKeepsTheOld()
    {
        var first = CallFolder.Create(Calls, Minute);
        Assert.Equal("2026-11-04 15-01", Path.GetFileName(first));
        Assert.Equal("2026-11-04 15-01", Json(first).Text("id"));
        File.WriteAllText(Path.Combine(first, "mic.m4a"), "audio");

        var second = CallFolder.Create(Calls, Minute);
        Assert.Equal("2026-11-04 15-01-2", Path.GetFileName(second));
        Assert.Equal("audio", File.ReadAllText(Path.Combine(first, "mic.m4a")));

        Directory.Move(first, Path.Combine(Calls, "2026-11-04 15-01 · Acme"));
        var third = CallFolder.Create(Calls, Minute);
        Assert.Equal("2026-11-04 15-01-3", Path.GetFileName(third));

        CallFile.RecordStopped(second, Minute, new AudioTimes());
        CallFile.WriteInfo(second, new CallInfo { Topic = "запуск" });
        Assert.Equal("2026-11-04 15-01-2", Json(second).Text("id"));
        Assert.Equal(["2026-11-04 15-01-3", "2026-11-04 15-01-2", "2026-11-04 15-01"], Call.All(Calls).Select(c => c.CallId));
    }

    [Fact]
    public void DiscardRemovesOnlyAnUnusedFolder()
    {
        var used = CallFolder.Create(Calls, Minute);
        File.WriteAllText(Path.Combine(used, "system.m4a"), "audio");
        Assert.False(CallFolder.DiscardIfUnused(used));
        Assert.True(File.Exists(Path.Combine(used, "system.m4a")));
        var empty = CallFolder.Create(Calls, Minute);
        Assert.True(CallFolder.DiscardIfUnused(empty));
        Assert.False(Directory.Exists(empty));
    }
}

public class CallModelTests : TempFolders
{
    [Fact]
    public void LoadedOnlyFromCallJson()
    {
        var dir = Path.Combine(Calls, "2026-11-04 15-01 · Чужой · неправда · Кто-то");
        WriteText(CallFile.PathIn(dir), """
            {"schema": 1, "id": "2026-11-04 15-01", "status": "done", "profile": "acme", "names": ["Анна"],
             "topic": "запуск", "terms": "", "languages": "ru,en", "summary": true,
             "audio": {"mic_start": 1, "mic_seconds": 120.5, "system_start": 1, "system_seconds": 90}}
            """);
        WriteText(Path.Combine(dir, "transcript.md"), "x");
        var c = Call.Load(dir, new Dictionary<string, string> { ["acme"] = "Acme" }, withSize: true)!;
        Assert.False(c.IsLegacy);
        Assert.Equal("2026-11-04 15-01", c.CallId);
        Assert.Equal("запуск", c.Title);
        Assert.Equal("Acme", c.Project);
        Assert.Equal("Анна", c.People);
        Assert.Equal([SpeechLanguage.Ru, SpeechLanguage.En], c.Languages);
        Assert.Equal(120.5, c.Duration);
        Assert.Equal(CallStatus.Done, c.Status);
        Assert.True(c.HasTranscript);
        Assert.False(c.HasSummary);
        Assert.NotNull(c.Date);
        Assert.True(c.Bytes > 0);
        Assert.Equal(0, Call.Load(dir)!.Bytes);
    }

    [Fact]
    public void ProjectTitleFallbacks()
    {
        var dir = MakeCall("2026-11-04 15-01", new JsonObject { ["profile"] = "velorent", ["project_title"] = "Velo Rent" });
        Assert.Equal("Velo Rent", Call.Load(dir)!.Project);
        Assert.Equal("Velo", Call.Load(dir, new Dictionary<string, string> { ["velorent"] = "Velo" })!.Project);
        var gone = MakeCall("2026-11-04 16-00", new JsonObject { ["profile"] = "gone" });
        Assert.Equal("gone", Call.Load(gone)!.Title);
    }

    [Fact]
    public void LegacyFolderNameFallback()
    {
        var dir = Path.Combine(Calls, "2026-11-03 10-00 · Acme · запуск · Анна, Иван");
        WriteText(Path.Combine(dir, "meta.json"), """{"mic_seconds": 30, "system_seconds": 45}""");
        var c = Call.Load(dir)!;
        Assert.True(c.IsLegacy);
        Assert.Equal("Acme", c.Project);
        Assert.Equal("запуск", c.Topic);
        Assert.Equal("Анна, Иван", c.People);
        Assert.Equal(45, c.Duration);
    }

    [Fact]
    public void CallJsonWithoutDateOrTopicFallsBackToTheFolderName()
    {
        var dir = Path.Combine(Calls, "2026-11-07 22-14 · Acme · запуск · Анна, Иван");
        WriteText(CallFile.PathIn(dir), """{"profile": "acme", "names": ["Анна", "Иван"], "terms": ""}""");
        var c = Call.Load(dir)!;
        Assert.Equal(new DateTimeOffset(new DateTime(2026, 11, 7, 22, 14, 0, DateTimeKind.Local)), c.Date);
        Assert.Equal("запуск", c.Title);
        Assert.Equal("Acme", c.Project);
        // A project this computer has keeps its own title.
        Assert.Equal("Acme Inc", Call.Load(dir, new Dictionary<string, string> { ["acme"] = "Acme Inc" })!.Project);
    }

    [Fact]
    public void FolderNamePartsSkipThePeople()
    {
        Assert.Equal(("Acme", ""), Call.FolderNameParts("2026-11-07 22-14 · Acme · Анна, Иван", true, ["Анна", "Иван"]));
        Assert.Equal(("", "запуск"), Call.FolderNameParts("2026-11-07 22-14 · запуск · Анна", false, ["Анна"]));
        Assert.Equal(("", ""), Call.FolderNameParts("2026-11-07 22-14-2", false, []));
    }

    [Fact]
    public void ForeignFoldersSkippedAndNewestFirst()
    {
        Directory.CreateDirectory(Path.Combine(Calls, "Разное"));
        Directory.CreateDirectory(Path.Combine(Calls, "2026-11-01 09-00"));
        Directory.CreateDirectory(Path.Combine(Calls, "2026-11-02 09-00"));
        Assert.Equal(["2026-11-02 09-00", "2026-11-01 09-00"], Call.All(Calls).Select(c => c.CallId));
    }

    [Fact]
    public void Clock()
    {
        Assert.Equal("", Call.Clock(0));
        Assert.Equal("0:00", Call.Clock(0, "0:00"));
        Assert.Equal("12:34", Call.Clock(754));
        Assert.Equal("1:02:03", Call.Clock(3723));
    }

    [Fact]
    public void WorkIsNotPartOfTheCallSize()
    {
        var dir = MakeCall("2026-11-04 15-01");
        var before = Call.FolderSize(dir);
        WriteText(Path.Combine(dir, WorkFiles.Folder, "mic.wav"), new string('x', 5000));
        Assert.Equal(before, Call.FolderSize(dir));
    }
}

public class QueueFileTests : TempFolders
{
    private static ProcessingJob Job(string dir, ProcessingKind kind = ProcessingKind.Transcribe) => new(dir, kind);

    [Fact]
    public void InterruptedRunIsRequeuedOnce()
    {
        var a = MakeCall("2026-11-04 15-01", new JsonObject { ["status"] = "processing" });
        var done = MakeCall("2026-11-04 16-01", new JsonObject { ["status"] = "done" });
        Assert.Equal([Job(a)], CallFile.RecoverQueue(Calls));
        Assert.Equal(1, Json(a).Int("retries"));
        Assert.Equal("recorded", Json(a).Text("status"));
        Assert.NotNull(Json(a)["queued_at"]);
        Assert.Null(Json(done)["queued_at"]);
    }

    [Fact]
    public void InterruptedAgainIsFailedSoACrashCannotLoop()
    {
        var a = MakeCall("2026-11-04 15-01", new JsonObject { ["status"] = "processing", ["retries"] = 1 });
        Assert.Empty(CallFile.RecoverQueue(Calls));
        Assert.Equal("failed", Json(a).Text("status"));
        Assert.Null(Json(a)["queued_at"]);
    }

    [Fact]
    public void WaitingCallsComeBackInTheirOrder()
    {
        var late = MakeCall("2026-11-04 15-01", new JsonObject { ["status"] = "recorded", ["queued_at"] = "2026-11-05T10:00:03Z" });
        var first = MakeCall("2026-11-04 16-01", new JsonObject { ["status"] = "done", ["queued_at"] = "2026-11-05T10:00:01.250Z" });
        var second = MakeCall("2026-11-04 17-01", new JsonObject { ["status"] = "failed", ["queued_at"] = "2026-11-05T10:00:01.750Z", ["queued_summary_only"] = true });
        Assert.Equal([Job(first), Job(second, ProcessingKind.SummaryOnly), Job(late)], CallFile.RecoverQueue(Calls));
        Assert.Equal("done", Json(first).Text("status"));
        Assert.Null(Json(first)["retries"]);
    }

    [Fact]
    public void InterruptedRunGoesBeforeTheWaitingOnes()
    {
        var waiting = MakeCall("2026-11-04 15-01", new JsonObject { ["status"] = "recorded", ["queued_at"] = "2026-11-05T10:00:00Z" });
        var interrupted = MakeCall("2026-11-04 16-01", new JsonObject { ["status"] = "processing" });
        Assert.Equal([Job(interrupted), Job(waiting)], CallFile.RecoverQueue(Calls));
    }

    [Fact]
    public void BrokenQueuedAtIsIgnored()
    {
        MakeCall("2026-11-04 15-01", new JsonObject { ["status"] = "recorded", ["queued_at"] = "вчера" });
        MakeCall("2026-11-04 16-01", new JsonObject { ["status"] = "recorded", ["queued_at"] = 5 });
        Assert.Empty(CallFile.RecoverQueue(Calls));
    }

    [Fact]
    public void QueuedFieldsAreWrittenAndRemoved()
    {
        var a = MakeCall("2026-11-04 15-01", new JsonObject { ["status"] = "done", ["retries"] = 1 });
        var at = DateTimeOffset.FromUnixTimeMilliseconds(1_800_000_000_500);
        Assert.True(CallFile.SetQueued(a, at, summaryOnly: true));
        Assert.Equal(at, CallFile.QueuedAt(Json(a)));
        Assert.True(Json(a).Flag("queued_summary_only"));
        Assert.True(CallFile.SetQueued(a, null));
        Assert.Null(Json(a)["queued_at"]);
        Assert.Null(Json(a)["queued_summary_only"]);
        Assert.True(CallFile.ClearRetries(a));
        Assert.Null(Json(a)["retries"]);
        Assert.Equal("done", Json(a).Text("status"));
    }

    [Fact]
    public void WorkSweepRespectsQueueAndRunningCalls()
    {
        string WithWork(string name, string status)
        {
            var dir = MakeCall(name, new JsonObject { ["status"] = status });
            WriteText(Path.Combine(dir, WorkFiles.Folder, "mic.wav"), "w");
            return dir;
        }
        var swept = WithWork("2026-11-04 15-01", "done");
        var kept = WithWork("2026-11-04 15-02", "done");
        var running = WithWork("2026-11-04 15-03", "processing");
        WorkFiles.Sweep(Calls, [kept]);
        Assert.False(Directory.Exists(Path.Combine(swept, WorkFiles.Folder)));
        Assert.True(Directory.Exists(Path.Combine(kept, WorkFiles.Folder)));
        Assert.True(Directory.Exists(Path.Combine(running, WorkFiles.Folder)));
        Assert.True(File.Exists(CallFile.PathIn(swept)));
    }
}

public class ParticipantsTests : TempFolders
{
    private static readonly JsonObject Fixture = Repo.Fixture("participants.json");

    private static IEnumerable<string> Strings(JsonNode? node) => ((JsonArray)node!).Select(n => n!.GetValue<string>());

    [Fact]
    public void DerivedMatchesTheEngineRule()
    {
        var cases = Fixture["participants"]!.AsArray();
        Assert.True(cases.Count > 5);
        foreach (var c in cases)
        {
            var got = CallParticipants.Derived(Strings(c!["typed"]), Strings(c["speakers"]).ToList(), c["me"]!.GetValue<string>());
            Assert.Equal(Strings(c["participants"]), got);
        }
    }

    [Fact]
    public void GenericLabelsMatchTheEngineRule()
    {
        var g = Fixture["generic"]!.AsObject();
        var me = g["me"]!.GetValue<string>();
        Assert.Empty(Strings(g["yes"]).Where(s => !Voices.IsGenericLabel(s, me)));
        Assert.Empty(Strings(g["no"]).Where(s => Voices.IsGenericLabel(s, me)));
    }

    [Fact]
    public void SameNameMatchesTheEngineRule()
    {
        var pairs = Fixture["same_name"]!.AsObject();
        foreach (var pair in pairs["same"]!.AsArray()) Assert.True(Voices.SameName(pair![0]!.GetValue<string>(), pair[1]!.GetValue<string>()));
        foreach (var pair in pairs["different"]!.AsArray()) Assert.False(Voices.SameName(pair![0]!.GetValue<string>(), pair[1]!.GetValue<string>()));
    }

    [Fact]
    public void UpdateWritesParticipantsAndNeverNames()
    {
        var dir = MakeCall("2026-11-06 23-13", new JsonObject { ["names"] = new JsonArray(), ["status"] = "done" });
        WriteText(Path.Combine(dir, "transcript.txt"), "[00:00] Boris: Привет.\n[00:02] Влад: Здорово.\n[00:05] Speaker: Угу.\n");
        Assert.True(CallParticipants.Update(dir, "Boris"));
        Assert.Equal(["Влад"], Json(dir).Texts("participants"));
        Assert.Empty(Json(dir).Texts("names")!);
        Assert.False(CallParticipants.Update(dir, "Boris"));
    }

    [Fact]
    public void ListPrefersParticipantsOverTypedNames()
    {
        Assert.Equal(["Анна Петрова"], CallParticipants.List(new JsonObject { ["names"] = new JsonArray("Анна"), ["participants"] = new JsonArray("Анна Петрова") }));
        Assert.Equal(["Анна"], CallParticipants.List(new JsonObject { ["names"] = new JsonArray("Анна") }));
        Assert.Equal(["Анна", "Олег"], CallParticipants.List(new JsonObject { ["names"] = "Анна, Олег" }));
    }
}

public class NotesAndPendingTests : TempFolders
{
    [Fact]
    public void NotesRoundTrip()
    {
        const string engineId = "0b7e0c4e-1111-4c3a-9d41-5d2f7f1a0a01";
        var dir = MakeCall("2026-11-04 15-01", new JsonObject
        {
            ["topic"] = "запуск",
            ["notes"] = new JsonArray(
                new JsonObject { ["id"] = engineId, ["at"] = "2026-11-04T12:00:00Z", ["text"] = "Перезвонить Анне", ["source"] = "claude-code" },
                new JsonObject { ["id"] = "bad id", ["at"] = "x", ["text"] = "y", ["source"] = "z" },
                "junk"),
        });
        Assert.Equal(["Перезвонить Анне"], CallNotes.Read(dir).Select(n => n.Text));
        var note = CallNotes.Add("  из приложения \n", dir, now: DateTimeOffset.FromUnixTimeSeconds(1_800_000_000));
        Assert.Equal("из приложения", note.Text);
        Assert.Equal("2027-01-15T08:00:00Z", note.At);
        Assert.Equal(2, Json(dir)["notes"]!.AsArray().Count);
        Assert.Equal("запуск", Json(dir).Text("topic"));
        Assert.True(CallNotes.Delete(engineId, dir));
        Assert.False(CallNotes.Delete("nope", dir));
        Assert.Equal([engineId], Json(dir).Texts(CallNotes.DeletedKey));
    }

    [Fact]
    public void NoteLimitsAndBrokenFile()
    {
        var dir = MakeCall("2026-11-04 15-01");
        Assert.Equal(CallNoteFailure.Empty, Assert.Throws<CallNoteException>(() => CallNotes.Add("   ", dir)).Failure);
        Assert.Equal(CallNoteFailure.TooLong, Assert.Throws<CallNoteException>(() => CallNotes.Add(new string('я', 4001), dir)).Failure);
        CallNotes.Add(new string('я', 4000), dir);
        File.WriteAllText(CallFile.PathIn(dir), "{broken");
        Assert.Equal(CallNoteFailure.Corrupt, Assert.Throws<CallNoteException>(() => CallNotes.Add("x", dir)).Failure);
        Assert.Equal("{broken", File.ReadAllText(CallFile.PathIn(dir)));
    }

    [Fact]
    public void WarningsSummary()
    {
        var c = new JsonObject { ["warnings"] = new JsonArray(new JsonObject { ["step"] = "summary", ["error"] = "claude:  rate\nlimit" }, new JsonObject { ["step"] = "echo" }, "junk") };
        Assert.Equal("claude: rate limit", CallWarnings.Summary(c));
        Assert.Null(CallWarnings.Summary([]));
    }

    [Fact]
    public void PendingRoundTrip()
    {
        var dir = MakeCall("2026-11-04 15-04", new JsonObject { ["status"] = "recorded", ["topic"] = "x" });
        Assert.False(Call.Load(dir)!.InfoPending);
        Assert.True(CallFile.SetInfoPending(dir, true));
        Assert.True(Json(dir).Flag("info_pending"));
        Assert.True(Call.Load(dir)!.InfoPending);
        CallFile.WriteInfo(dir, new CallInfo { Topic = "y" });
        Assert.True(PendingInfo.IsPending(Json(dir)));
        Assert.True(CallFile.SetInfoPending(dir, false));
        Assert.Null(Json(dir)["info_pending"]);
    }

    [Fact]
    public void PendingListOldestFirstAndOnlyRecorded()
    {
        JsonObject Pending(string status = "recorded") => new() { ["status"] = status, ["info_pending"] = true };
        MakeCall("2026-11-04 16-00", Pending());
        MakeCall("2026-11-04 15-04", Pending());
        MakeCall("2026-11-04 15-04-2", Pending());
        MakeCall("2026-11-04 14-00", new JsonObject { ["status"] = "recorded" });
        MakeCall("2026-11-04 13-00", Pending("done"));
        Assert.Equal(["2026-11-04 15-04", "2026-11-04 15-04-2", "2026-11-04 16-00"], PendingInfo.All(Calls).Select(p => p.Id));
    }
}

public class ProjectAndVoiceTests : TempFolders
{
    [Fact]
    public void SaveKeepsOtherFields()
    {
        var profiles = Path.Combine(Data, "profiles");
        WriteText(Path.Combine(profiles, "acme.json"), """{"schema": 1, "title": "old", "replacements": [["a", "b"]], "extra": 1}""");
        new Project("acme", "Acme / Holding", "ctx", ["Анна"], ["HPA"]).Save(profiles);
        var o = JsonFile.Read(Path.Combine(profiles, "acme.json"))!;
        Assert.Equal("Acme / Holding", o.Text("title"));
        Assert.Equal(1, o.Int("extra"));
        Assert.Single(o["replacements"]!.AsArray());
        var loaded = Project.All(profiles).Single();
        Assert.Equal("Acme", loaded.ShortTitle);
        Assert.Equal(["Анна"], loaded.People);
    }

    [Fact]
    public void SlugRules()
    {
        Assert.True(Project.IsValidSlug("acme_1-x"));
        Assert.False(Project.IsValidSlug("Acme"));
        Assert.False(Project.IsValidSlug(""));
        Assert.Equal("schuka-i-rak", Project.Slugify("Щука и рак!"));
        Assert.Equal("project", Project.Slugify("  !!"));
        Assert.Equal(ProjectTitleProblem.Empty, Project.TitleProblem(" ", "", []));
        Assert.Equal(ProjectTitleProblem.Duplicate, Project.TitleProblem(" acme ", "new", [new Project("a", "Acme")]));
        Assert.Null(Project.TitleProblem("Acme", "a", [new Project("a", "Acme")]));
    }

    [Fact]
    public void ReplacementsFollowTheEngineRule()
    {
        var vocab = Path.Combine(Data, "vocab.json");
        ReplacementStore.Add("Wrong", "right", vocab, create: true);
        ReplacementStore.Add("wrong ", "better", vocab, create: true);
        var list = JsonFile.Read(vocab)!["replacements"]!.AsArray();
        Assert.Single(list);
        Assert.Equal("better", list[0]![1]!.GetValue<string>());
        Assert.Equal(ReplacementFailure.NoProject, Assert.Throws<ReplacementException>(() => ReplacementStore.Add("a", "b", "missing", Data)).Failure);
    }

    [Fact]
    public void VoicesRecordsAndArguments()
    {
        var voices = Path.Combine(Data, "voices");
        WriteText(Path.Combine(voices, "a.json"), """{"id": "a", "name": "Борис", "me": true, "seconds": 10, "updated_at": "2026-01-01T00:00:00Z"}""");
        WriteText(Path.Combine(voices, "b.json"), """{"id": "b", "name": "Анна", "profile": "acme"}""");
        WriteText(Path.Combine(voices, "c.json"), """{"broken""");
        var all = Voices.All(voices);
        Assert.Equal(["Анна", "Борис"], all.Select(v => v.Name));
        Assert.Equal("a", Voices.Me(all)!.Id);
        Assert.Equal(["Иван"], Voices.Unsaved(["Анна", "Иван", "boris", "Собеседник 2"], "acme", all, ""));
        Assert.Equal(["enroll", "--name", "Я", "--me", "--file", "x.wav"], Voices.EnrollFile("Я", "", true, false, "x.wav"));
        Assert.Equal(["enroll", "--name", "А", "--profile", "acme", "--call", "d", "--speaker", "S"], Voices.EnrollCall("А", "acme", "d", "S"));
    }
}
