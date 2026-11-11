using System.Text;
using Sozvon.Core.Diagnostics;

namespace Sozvon.Core.Tests;

/// <summary>
/// "Show Logs": which files go in, what is scrubbed, and that no private data ever does. The Mac's DiagnosticsTests with
/// Windows paths: backslashes, a drive letter, the profile folder in any case and spelling.
/// </summary>
public sealed class DiagnosticsTests : TempFolders
{
    private const string Home = @"C:\Users\anna";
    private string Logs => Path.Combine(Root, "logs");

    /// <summary>A call folder with the private files a real call has, and a process.log.</summary>
    private string MakeCallFolder(string name, string log = "[10:00:00] done\n", DateTime? logTime = null)
    {
        var dir = Path.Combine(Calls, name);
        WriteText(Path.Combine(dir, "call.json"), "{\"schema\":1,\"id\":\"x\"}");
        WriteText(Path.Combine(dir, "transcript.md"), "Anna: SECRET TRANSCRIPT");
        WriteText(Path.Combine(dir, "summary.md"), "SECRET SUMMARY");
        WriteText(Path.Combine(dir, "system.m4a"), "audio");
        WriteText(Path.Combine(dir, "process.log"), log);
        if (logTime is { } time) File.SetLastWriteTimeUtc(Path.Combine(dir, "process.log"), time);
        return dir;
    }

    private static DiagnosticScrub Scrub(params string[] folders) => new(Home, folders);

    // Selection

    [Fact]
    public void SelectionTakesTheNamedLogsAndTheLastFiveProcessLogsOnly()
    {
        WriteText(Path.Combine(Logs, "recorder.log"), "r");
        WriteText(Path.Combine(Logs, "cloudflare.log"), "c");
        WriteText(Path.Combine(Data, "setup.log"), "s");
        WriteText(Path.Combine(Data, "mcp.log"), "m");
        WriteText(Path.Combine(Data, ".env"), "TOKEN=abc");
        WriteText(Path.Combine(Data, "voice.log"), "x");
        WriteText(Path.Combine(Data, "app-errors.log"), "x");
        WriteText(Path.Combine(Data, "voices", "anna.json"), "x");
        for (var i = 1; i <= 7; i++)
        {
            MakeCallFolder($"2026-11-0{i} 10-00 · Topic {i}", logTime: new DateTime(2026, 11, 10, 10, i, 0, DateTimeKind.Utc));
        }
        var names = DiagnosticArchive.Selection(Logs, Data, Calls).Select(i => i.Name).ToList();
        Assert.Equal(new HashSet<string> { "recorder.log", "cloudflare.log", "setup.log", "mcp.log" },
                     names.Where(n => !n.StartsWith("process-", StringComparison.Ordinal)).ToHashSet());
        // The five newest by log time: 3 to 7, named by the date id, never by the folder title.
        Assert.Equal(Enumerable.Range(3, 5).Select(i => $"process-2026-11-0{i} 10-00.log").ToHashSet(),
                     names.Where(n => n.StartsWith("process-", StringComparison.Ordinal)).ToHashSet());
        Assert.DoesNotContain(names, n => n.Contains("Topic") || n.Contains(".env") || n.Contains("voice") || n.Contains("call.json") || n.Contains("errors"));
    }

    [Fact]
    public void SelectionSkipsMissingLogsAndEmptyFolders()
    {
        Assert.Empty(DiagnosticArchive.Selection(Logs, Data, Calls));
        Directory.CreateDirectory(Path.Combine(Calls, "2026-11-01 10-00"));
        Assert.Empty(DiagnosticArchive.Selection(Logs, Data, Calls));
        Assert.Empty(DiagnosticArchive.Selection(Logs, Data, Path.Combine(Root, "no calls folder")));
    }

    [Fact]
    public void TwoFoldersWithOneIdKeepDistinctNames()
    {
        MakeCallFolder("2026-11-01 10-00 · A");
        MakeCallFolder("2026-11-01 10-00 · B");
        var names = DiagnosticArchive.Selection(Logs, Data, Calls).Select(i => i.Name).ToList();
        Assert.Equal(2, names.Distinct().Count());
        Assert.Contains("process-2026-11-01 10-00.log", names);
        Assert.Contains("process-2026-11-01 10-00 (2).log", names);
    }

    // Scrubbing

    [Fact]
    public void HomeAndCallFolderNamesAreScrubbed()
    {
        var scrub = Scrub("2026-11-04 15-01 · Acme pricing · Oleg", "Рабочий разговор");
        var output = scrub.Text(@"open C:\Users\anna\Sozvon Calls\2026-11-04 15-01 · Acme pricing · Oleg\system.m4a failed; "
                                + @"C:\Users\anna\Sozvon Calls\Рабочий разговор\mic.m4a; home=C:\Users\anna");
        Assert.Equal(@"open ~\Sozvon Calls\2026-11-04 15-01\system.m4a failed; ~\Sozvon Calls\call\mic.m4a; home=~", output);
        Assert.DoesNotContain("Acme", output);
        Assert.DoesNotContain("anna", output);
    }

    [Fact]
    public void TheProfileFolderIsFoundInEverySpelling()
    {
        var scrub = Scrub();
        Assert.Equal(@"~\x and ~/x and ~\\x and ~\", scrub.Text(@"c:\users\ANNA\x and C:/Users/anna/x and C:\\Users\\anna\\x and C:\Users\anna\"));
        Assert.Equal(@"C:\Users\anna2\x and ~\x", scrub.Text(@"C:\Users\anna2\x and C:\Users\anna\x"));
        var both = new DiagnosticScrub([Home, @"D:\Profiles\anna.ivanova"], []);
        Assert.Equal(@"~\a ~\b", both.Text(@"C:\Users\anna\a D:\Profiles\anna.ivanova\b"));
    }

    [Fact]
    public void RenamedOrDeletedCallFolderIsScrubbedToo()
    {
        // Not in the list: the call was renamed or deleted after the line was logged.
        var scrub = Scrub("2026-11-04 15-01 · Other");
        Assert.Equal(@"cannot open ~\Sozvon Calls\2026-10-01 09-00\mic.m4a",
                     scrub.Text(@"cannot open C:\Users\anna\Sozvon Calls\2026-10-01 09-00 · Old renamed deal\mic.m4a"));
        Assert.Equal(@"gone: ~\Sozvon Calls\2026-10-01 09-00-3", scrub.Text(@"gone: C:\Users\anna\Sozvon Calls\2026-10-01 09-00-3 · Deal with Oleg"));
        Assert.Equal("2026-11-08 12:00:00 +0000 level -20 dB", scrub.Text("2026-11-08 12:00:00 +0000 level -20 dB"));
        // A Python repr doubles the backslashes; the title still ends at the next one.
        Assert.Equal(@"'~\\Sozvon Calls\\2026-10-01 09-00\\mic.m4a'", scrub.Text(@"'C:\\Users\\anna\\Sozvon Calls\\2026-10-01 09-00 · Deal\\mic.m4a'"));
    }

    [Fact]
    public void PercentEncodedCallFolderIsScrubbedLikeThePlainOne()
    {
        var scrub = Scrub("2026-11-04 15-01 · Acme Приём");
        var deleted = scrub.Text("Error file:///C:/Users/anna/Sozvon%20Calls/2026-10-01%2009-00%20%C2%B7%20Old%20deal%20with%20Oleg/mic.m4a UserInfo");
        Assert.Equal("Error file:///~/Sozvon%20Calls/2026-10-01 09-00/mic.m4a UserInfo", deleted);
        var second = scrub.Text("file:///C:/Users/anna/Calls/2026-10-01%2009-00-2%20%D0%A1%D0%B4%D0%B5%D0%BB%D0%BA%D0%B0/x");
        Assert.Equal("file:///~/Calls/2026-10-01 09-00-2/x", second);
        foreach (var output in new[] { deleted, second })
        {
            foreach (var leak in new[] { "Old", "Oleg", "%D0", "anna" }) Assert.DoesNotContain(leak, output);
        }
    }

    [Fact]
    public void EncodedTitleWithPunctuationIsScrubbedWhole()
    {
        var scrub = Scrub();
        const string start = "file:///C:/Users/anna/Calls/2026-10-01%2009-00";
        foreach (var (input, leak) in new[]
                 {
                     ($"{start}%20Deal,%20Oleg/mic.m4a", "Oleg"),
                     ($"{start}%20Anna's%20deal/mic.m4a", "deal"),
                     ($"{start}%20Plan%20(Oleg%20draft)/mic.m4a", "Oleg"),
                     ($"{start}%20Plan%20(Oleg%20draft)\" end", "Oleg"),
                     ($"({start}%20Deal%20Oleg)", "Oleg"),
                 })
        {
            var output = scrub.Text(input);
            Assert.DoesNotContain(leak, output);
            Assert.Contains("2026-10-01 09-00", output);
            Assert.DoesNotContain("%20", output);
        }
        Assert.Equal("file:///~/Calls/2026-10-01 09-00/mic.m4a UserInfo", scrub.Text($"{start}%20Deal,%20Oleg/mic.m4a UserInfo"));
    }

    /// <summary>What real folder names look like on Windows: any of these can be a title, whatever punctuation it holds.</summary>
    private static readonly (string Name, string Id)[] RealFolderNames =
    [
        ("2026-10-01 09-00 · Deal (Oleg) Ivanov", "2026-10-01 09-00"),
        ("2026-10-01 09-00-2 · Plan, Oleg, Ivanov", "2026-10-01 09-00-2"),
        ("2026-10-01 09-00 · Anna's (draft), Ivanov", "2026-10-01 09-00"),
        ("2026-11-04 15-01 · Globex.io · кабинет автора · Олег, Пётр", "2026-11-04 15-01"),
    ];

    [Fact]
    public void PlainTitleRunsToTheSeparatorWhateverItHolds()
    {
        foreach (var folders in new[] { Array.Empty<string>(), RealFolderNames.Select(f => f.Name).ToArray() })
        {
            var scrub = new DiagnosticScrub(Home, folders);
            foreach (var (name, id) in RealFolderNames)
            {
                Assert.Equal($@"cannot open D:\x\{id}\mic.m4a", scrub.Text($@"cannot open D:\x\{name}\mic.m4a"));
                Assert.Equal($"open D:/x/{id}/mic.m4a", scrub.Text($"open D:/x/{name}/mic.m4a"));
                Assert.Equal($@"gone: D:\x\{id}", scrub.Text($@"gone: D:\x\{name}"));
                Assert.Equal($@"open D:\x\{id}: no such file", scrub.Text($@"open D:\x\{name}: no such file"));
                Assert.Equal(folders.Length == 0 ? $@"(D:\x\{id}" : $@"(D:\x\{id})", scrub.Text($@"(D:\x\{name})"));
            }
        }
    }

    [Fact]
    public void PlainCallNameWithoutASlashLosesItsTitleToo()
    {
        var scrub = Scrub();
        foreach (var (name, id) in RealFolderNames)
        {
            Assert.Equal($"renaming {id}", scrub.Text($"renaming {name}"));
            Assert.Equal($"{id}: busy", scrub.Text($"{name}: busy"));
            Assert.Equal($"{id}\nnext", scrub.Text($"{name}\r\nnext"));
        }
    }

    [Fact]
    public void FolderIdKeepsTheSecondRecordingSuffix() =>
        Assert.Equal("in 2026-11-04 15-01-2 now", Scrub("2026-11-04 15-01-2 · Topic").Text("in 2026-11-04 15-01-2 · Topic now"));

    [Fact]
    public void SecretsAreRemoved()
    {
        var scrub = Scrub();
        foreach (var sample in new[]
                 {
                     "Authorization: Bearer abcdefghijklmnop12345",
                     "token=cfut_abcdefghijklmnopqrstuvwxyz0123456789ABCD",
                     "HF_TOKEN=hf_abcdefghijklmnopqrstuvwxyz",
                     "key sk-ant-api03-abcdefghijklmnopqrstuvwxyz",
                     "password: hunter2hunter2",
                     """{"api_token": "0123456789abcdef0123456789abcdef"}""",
                     "mcp 0123456789abcdef0123456789abcdef01234567",
                     "mail anna.petrova@example.com",
                 })
        {
            var output = scrub.Text(sample);
            Assert.Contains("[removed]", output);
            foreach (var secret in new[] { "abcdefghijklmnop12345", "cfut_abc", "hf_abc", "sk-ant", "hunter2", "0123456789abcdef", "anna.petrova", "example.com" })
            {
                Assert.DoesNotContain(secret, output);
            }
        }
        Assert.Equal("model turbo, 3 segments, 12.5 s", scrub.Text("model turbo, 3 segments, 12.5 s"));
    }

    [Fact]
    public void McpLogDropsWhatAnAssistantSent()
    {
        const string log = """
            === 2026-11-08T10:00:00.0000000+04:00 server.py --http
            INFO:     Started server process [4242]
            sozvon: search index unavailable, substring search: fts5: syntax error near "pay Oleg 5000"
            ERROR:    Exception in ASGI application
            Traceback (most recent call last):
              File "C:\Users\anna\x.py", line 3, in call
            pydantic_core._pydantic_core.ValidationError: 1 validation error for search
              Input should be a valid string [input_value='what did Maria promise', input_type=int]
            127.0.0.1:5000 - "POST /mcp?token=abc HTTP/1.1" 200
            ERROR:    [Errno 10048] error while attempting to bind on address ('127.0.0.1', 47816): [winerror 10048] only one usage of each socket address (protocol/network address/port) is normally permitted
            """;
        var output = Scrub().McpLog(log);
        foreach (var secret in new[] { "Oleg", "5000", "Maria", "promise", "token=abc", "anna" }) Assert.DoesNotContain(secret, output);
        foreach (var kept in new[] { "=== 2026-11-08T10:00:00.0000000+04:00 server.py --http", "Started server process", "search index unavailable",
                                     "Exception in ASGI application", "ValidationError", @"File ""~\x.py""", "winerror 10048" })
        {
            Assert.Contains(kept, output);
        }
    }

    // process.log

    /// <summary>What the engine really writes to process.log (see engine i18n): names, project, assistant errors.</summary>
    private const string SampleProcessLog = """
        [10:00:01] project: Acme pricing; participants: Oleg Petrov, Anna; prompt 120 tokens
        [10:00:01] added to project Acme pricing: Oleg Petrov
        [10:00:02] mic.wav: ~42 s of speech
        [10:00:03] transcribing mic …
        [10:00:09] mic: 31 segments
        [10:00:10] voice: Speaker 1 → Oleg Petrov (0.81)
        [10:00:11] diarization: 2 speakers
        [10:00:12] speaker names: Speaker 2 → Maria Ivanova
        [10:00:13] summary failed (claude): Error: could not summarize "we agreed to pay 5000 to Oleg on Friday" token=sk-ant-api03-abcdefghijklmnopqrstuvwxyz
        [10:00:14] speaker names: assistant error (timeout after the phrase we will sign the contract), names in order of appearance
        [10:00:15] echo: cancellation failed, the microphone is left as is: boom
        [10:00:16] done: C:\Users\anna\Sozvon Calls\2026-11-04 15-01 · Acme pricing\transcript.md (12 paragraphs)
        Traceback (most recent call last):
          File "C:\Users\anna\x.py", line 3, in run
            text = "Привет, это секретная реплика"
        ValueError: bad value: Привет, это секретная реплика
        Привет, это сырая строка без метки времени
        RESULT: error 5 ffmpeg could not read mic.wav: invalid data
        """;

    [Fact]
    public void ProcessLogKeepsOnlyLinesThatCannotCarryPrivateText()
    {
        var output = Scrub("2026-11-04 15-01 · Acme pricing").ProcessLog(SampleProcessLog.Replace("\n", "\r\n"));
        foreach (var secret in new[] { "Acme", "Oleg", "Maria", "Anna", "5000", "contract", "секретная", "Привет", "сырая", "sk-ant", "anna", "boom", "Friday" })
        {
            Assert.DoesNotContain(secret, output);
        }
        // Support still sees what happened and where it failed.
        foreach (var kept in new[] { "transcribing mic", "mic: 31 segments", "diarization: 2 speakers", "mic.wav: ~42 s of speech", "summary failed",
                                     "echo: cancellation failed", "voice:", "Traceback", "ValueError", @"~\Sozvon Calls\2026-11-04 15-01\transcript.md",
                                     "RESULT: error 5" })
        {
            Assert.Contains(kept, output);
        }
        Assert.DoesNotContain("\r", output);
    }

    [Fact]
    public void ListeningFileLinesKeepOnlyWhatIsSafe()
    {
        var ok = Scrub().ProcessLog("[10:00:00] listening file ready in 41 s\n[10:00:01] файл для прослушивания готов за 41 с\n");
        Assert.Contains("listening file ready in 41 s", ok);
        Assert.Contains("файл для прослушивания готов за 41 с", ok);
        var failed = Scrub().ProcessLog("[10:00:02] could not make the listening file: C:\\Users\\anna\\secret title\n[10:00:03] не получилось сделать файл для прослушивания: секрет\n");
        Assert.DoesNotContain("secret", failed);
        Assert.DoesNotContain("секрет", failed);
        Assert.Contains("could not make the listening file", failed);
        Assert.Contains("не получилось сделать файл для прослушивания", failed);
    }

    [Fact]
    public void ProcessLogMessagesWithAnExtraTailAreDropped()
    {
        const string ok = """
            [10:00:01] system audio was missing for 12 s, separating speakers on the microphone there
            [10:00:02] the prompt with terms confused the model, retrying with a short prompt
            [10:00:03] model large-v3: no Whisper prompt, project terms are not used, only replacements
            [10:00:04] GigaAM understands only Russian: other languages will be recognized poorly
            [10:00:05] another run is still processing this call, waiting for it to end
            [10:00:06] voices: 2 voice print(s) of another model skipped (they stay saved)
            """;
        Assert.DoesNotContain("omitted", Scrub().ProcessLog(ok));
        var leaky = string.Join("\n", ok.Split('\n').Select(l => l.TrimEnd('\r') + " SECRET"));
        var output = Scrub().ProcessLog(leaky);
        Assert.DoesNotContain("SECRET", output);
        Assert.Contains("6 lines omitted", output);
    }

    [Fact]
    public void ProcessLogSaysHowManyLinesWereLeftOut() =>
        Assert.Contains("2 lines omitted", Scrub().ProcessLog("[10:00:00] mic: 3 segments\nsome free text\nmore text\n"));

    [Fact]
    public void ProcessLogHandlesRussianEngineMessages()
    {
        const string ru = """
            [10:00:01] профиль: Рога и копыта; собеседники: Олег; подсказка 10 ток.
            [10:00:02] имена собеседников: Спикер 1 → Олег
            [10:00:03] саммари не получилось (claude): сказал заплатить Олегу
            [10:00:04] голос: Спикер 1 → Олег (0.80)
            [10:00:05] mic: 3 сегментов
            """;
        var output = Scrub().ProcessLog(ru);
        foreach (var secret in new[] { "Рога", "Олег", "заплатить" }) Assert.DoesNotContain(secret, output);
        Assert.Contains("саммари не получилось", output);
        Assert.Contains("3 сегментов", output);
    }

    // The folder

    /// <summary>"Show Logs": the scrubbed files in a folder to look at in Explorer; an older copy is replaced.</summary>
    [Fact]
    public void WriteFolderHoldsTheScrubbedFilesAndNothingPrivate()
    {
        MakeCallFolder("2026-11-04 15-01 · Acme pricing", SampleProcessLog);
        WriteText(Path.Combine(Logs, "recorder.log"), @"2026-11-04 C:\Users\anna\AppData\x failed" + "\r\nopen C:\\Users\\anna\\Sozvon Calls\\2026-01-01 08-00 · Gone title\\mic.m4a\r\n");
        WriteText(Path.Combine(Data, "setup.log"), "Bearer abcdefghijklmnop12345 C:\\Users\\anna\n");
        WriteText(Path.Combine(Data, "mcp.log"), "=== 2026-11-08T10:00:00Z server.py --http\nCOOKIE password=hunter2hunter2\nsozvon: search index unavailable, substring search: near \"Oleg\"\n");
        WriteText(Path.Combine(Data, ".env"), "TOKEN=abc");
        WriteText(Path.Combine(Data, "voices", "anna.json"), "{}");
        var folder = Path.Combine(Data, "Diagnostics");
        WriteText(Path.Combine(folder, "stale.log"), "stale");
        var checks = new[] { new DiagnosticCheck("disk", "Свободное место", DiagnosticState.Ok, @"C:\Users\anna: 50 ГБ") };

        var written = DiagnosticArchive.WriteFolder(checks, Logs, Data, Calls, [Home], folder);

        var names = Directory.GetFiles(folder).Select(p => Path.GetFileName(p)).Order(StringComparer.Ordinal).ToList();
        Assert.Equal(["checks.txt", "mcp.log", "process-2026-11-04 15-01.log", "recorder.log", "setup.log"], names);
        Assert.Equal(names.ToHashSet(), written.ToHashSet());
        var all = string.Concat(names.Select(n => File.ReadAllText(Path.Combine(folder, n!), Encoding.UTF8)));
        foreach (var secret in new[] { "SECRET", "Acme", "anna", "hunter2", "abcdefghijklmnop", "Oleg", "TOKEN=abc", "Gone title", "stale" })
        {
            Assert.DoesNotContain(secret, all);
        }
        Assert.Equal("[ok] Свободное место: ~: 50 ГБ\n", File.ReadAllText(Path.Combine(folder, "checks.txt"), Encoding.UTF8));
        Assert.NotEqual(0xEF, File.ReadAllBytes(Path.Combine(folder, "checks.txt"))[0]);
    }

    [Fact]
    public void WriteFolderNeverWalksIntoAFolderInside()
    {
        var folder = Path.Combine(Data, "Diagnostics");
        WriteText(Path.Combine(folder, "inner", "keep.txt"), "keep");
        DiagnosticArchive.WriteFolder([], Logs, Data, Calls, [Home], folder);
        Assert.True(File.Exists(Path.Combine(folder, "inner", "keep.txt")));
        Assert.True(File.Exists(Path.Combine(folder, "checks.txt")));
    }

    [Fact]
    public void BigLogsAreCutToTheirEnd()
    {
        WriteText(Path.Combine(Logs, "recorder.log"), string.Concat(Enumerable.Range(0, 60_000).Select(i => $"line {i}\n")));
        var folder = Path.Combine(Root, "out");
        DiagnosticArchive.WriteFolder([], Logs, Data, Calls, [Home], folder);
        var text = File.ReadAllText(Path.Combine(folder, "recorder.log"), Encoding.UTF8);
        Assert.True(Encoding.UTF8.GetByteCount(text) < DiagnosticArchive.MaxLogBytes + 200);
        Assert.Contains("line 59999", text);
        Assert.DoesNotContain("line 0\n", text);
        Assert.StartsWith("[earlier lines cut]", text);
    }

    [Fact]
    public void ALogBeingWrittenIsStillRead()
    {
        var path = Path.Combine(Data, "mcp.log");
        WriteText(path, "=== 2026-11-08T10:00:00Z server.py --http\n");
        using var writer = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
        Assert.Contains("server.py --http", DiagnosticArchive.Tail(path, DiagnosticArchive.MaxLogBytes));
    }

    // Checks

    [Fact]
    public void FreeSpaceStates()
    {
        Assert.Equal(DiagnosticState.Ok, DiagnosticChecks.DiskState(50_000_000_000));
        Assert.Equal(DiagnosticState.Warning, DiagnosticChecks.DiskState(3_000_000_000));
        Assert.Equal(DiagnosticState.Problem, DiagnosticChecks.DiskState(200_000_000));
        Assert.Equal(DiagnosticState.Warning, DiagnosticChecks.DiskState(null));
        Assert.NotNull(DiagnosticChecks.FreeBytes(Data));
    }

    [Fact]
    public void ReportText() =>
        Assert.Equal("[ok] Python: ready\n[problem] ffmpeg: missing\n[warning] Disk: low\n", DiagnosticChecks.Text(
        [
            new DiagnosticCheck("a", "Python", DiagnosticState.Ok, "ready"),
            new DiagnosticCheck("b", "ffmpeg", DiagnosticState.Problem, "missing"),
            new DiagnosticCheck("c", "Disk", DiagnosticState.Warning, "low"),
        ]));
}
