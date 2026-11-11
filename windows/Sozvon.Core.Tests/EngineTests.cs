using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;
using Sozvon.Core.Foundation;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

public class EngineEnvironmentTests : TempFolders
{
    private EngineLayout Layout => new(Data, Calls);

    [Fact]
    public void FollowsTheContract()
    {
        var env = EngineEnvironment.Build(Layout, new EngineOptions("en", null, 47816, "t"),
            new Dictionary<string, string> { ["Path"] = @"C:\win", ["SOZVON_THREADS"] = "8", ["=C:"] = @"C:\x", ["HOME"] = "h" });
        Assert.Equal(Data, env["SOZVON_DATA_DIR"]);
        Assert.Equal(Calls, env["SOZVON_CALLS_DIR"]);
        Assert.Equal("en", env["SOZVON_UI_LANG"]);
        Assert.Equal("1", env["PYTHONUTF8"]);
        Assert.Equal("utf-8", env["PYTHONIOENCODING"]);
        Assert.Equal("1", env["PYTHONUNBUFFERED"]);
        Assert.False(env.ContainsKey("SOZVON_THREADS"));
        Assert.Equal("47816", env["SOZVON_MCP_PORT"]);
        Assert.Equal("t", env["SOZVON_MCP_TOKEN"]);
        Assert.Equal("h", env["HOME"]);
        Assert.False(env.ContainsKey("=C:"));
        Assert.StartsWith(Layout.ScriptsFolder + ";", env["PATH"]);
        Assert.Equal("2", EngineEnvironment.Build(Layout, new EngineOptions("ru", 2), []).GetValueOrDefault("SOZVON_THREADS"));
    }

    [Fact]
    public void ChoicesOverrideTheEnvFile()
    {
        var options = new EngineOptions(Me: "Анна", Llm: Assistant.None, Languages: [SpeechLanguage.Ru, SpeechLanguage.En], LanguageSwitch: true, Model: WhisperModel.Large);
        var env = EngineEnvironment.Build(Layout, options, []);
        Assert.Equal("Анна", env["SOZVON_ME"]);
        Assert.Equal("none", env["SOZVON_LLM"]);
        Assert.Equal("ru,en", env["SOZVON_LANGUAGE"]);
        Assert.Equal("1", env["SOZVON_LANG_SWITCH"]);
        Assert.Equal("large-v3", env["SOZVON_MODEL"]);
        Assert.Equal("auto", EngineEnvironment.Build(Layout, new EngineOptions(Languages: []), [])["SOZVON_LANGUAGE"]);
    }

    /// <summary>
    /// A run with its own SOZVON_DATA_DIR (a test, a second profile) keeps every part of the app in that folder: the
    /// setup wizard it opens included, which used to fall back to the user's real folder when no --data-dir was given.
    /// </summary>
    [Fact]
    public void TheFoldersComeFromTheEnginesVariables()
    {
        var variables = new Dictionary<string, string?> { ["SOZVON_DATA_DIR"] = Data, ["SOZVON_CALLS_DIR"] = Calls };
        var layout = EngineLayout.FromEnvironment(name => variables.GetValueOrDefault(name));
        Assert.Equal(Data, layout.Data);
        Assert.Equal(Calls, layout.Calls);

        var defaults = EngineLayout.Default();
        Assert.Equal(defaults, EngineLayout.FromEnvironment(_ => null));
        Assert.Equal(defaults, EngineLayout.FromEnvironment(_ => " "));
        Assert.Equal(new EngineLayout(Data, defaults.Calls), EngineLayout.FromEnvironment(name => name == "SOZVON_DATA_DIR" ? Data : ""));
    }

    [Fact]
    public void WithoutAChoiceTheEnvFileDecides()
    {
        var env = EngineEnvironment.Build(Layout, new EngineOptions(), new Dictionary<string, string> { ["SOZVON_MODEL"] = "small", ["SOZVON_LLM"] = "claude" });
        Assert.False(env.ContainsKey("SOZVON_MODEL"));
        Assert.False(env.ContainsKey("SOZVON_LLM"));
    }

    /// <summary>
    /// install.py writes .installed last, once everything is in place: python.exe alone is an install that stopped halfway,
    /// and the marker alone is a venv that was removed.
    /// </summary>
    [Fact]
    public void LayoutFindsTheEngineOnlyWhenTheInstallFinished()
    {
        Assert.False(Layout.IsInstalled);
        WriteText(Path.Combine(Data, ".venv", "Scripts", "python.exe"), "x");
        Assert.False(Layout.IsInstalled);
        WriteText(Path.Combine(Data, ".installed"), "1762780000\n");
        Assert.True(Layout.IsInstalled);
        Assert.Equal(Path.Combine(Data, ".installed"), Layout.InstalledMarker);
        File.Delete(Layout.Python);
        Assert.False(Layout.IsInstalled);
        Assert.Equal(Path.Combine(Data, "bin", "process_call.py"), Layout.Script("process_call.py"));
    }

    [Fact]
    public void EngineStateFollowsInstallMarkers()
    {
        Assert.Equal(EngineStateKind.NotInstalled, EngineState.Evaluate(Layout, WhisperModel.Turbo));
        WriteText(Layout.Python, "x");
        Assert.Equal(EngineStateKind.NotInstalled, EngineState.Evaluate(Layout, WhisperModel.Turbo));
        MarkInstalled();
        Assert.Equal(EngineStateKind.ModelMissing, EngineState.Evaluate(Layout, WhisperModel.Turbo));
        WriteText(Path.Combine(Data, "models", "whisper-large-v3-turbo", ".complete"), "");
        Assert.Equal(EngineStateKind.Ready, EngineState.Evaluate(Layout, WhisperModel.Turbo));
        WriteText(Path.Combine(Data, "uv.lock"), "lock v2");
        WriteText(Path.Combine(Data, ".venv-lock"), "0000000000000000\n");
        Assert.Equal(EngineStateKind.NeedsUpdate, EngineState.Evaluate(Layout, WhisperModel.Turbo));
        Assert.Equal(EngineStateKind.Ready, EngineState.Evaluate(Layout, WhisperModel.Turbo, isDevEngine: true));
        WriteText(Path.Combine(Data, ".venv-lock"), EngineState.LockHash(Encoding.UTF8.GetBytes("lock v2")) + "\n");
        Assert.Equal(EngineStateKind.Ready, EngineState.Evaluate(Layout, WhisperModel.Turbo));
    }

    [Fact]
    public void AGpuInstallHashIsAccepted()
    {
        WriteText(Layout.Python, "x");
        MarkInstalled();
        WriteText(Path.Combine(Data, "models", "whisper-large-v3-turbo", ".complete"), "");
        WriteText(Path.Combine(Data, "uv.lock"), "lock");
        WriteText(Path.Combine(Data, "gpu", "cu130.txt"), "torch");
        WriteText(Path.Combine(Data, ".venv-lock"), EngineState.GpuLockHash(Encoding.UTF8.GetBytes("lock"), Encoding.UTF8.GetBytes("torch")));
        Assert.Equal(EngineStateKind.Ready, EngineState.Evaluate(Layout, WhisperModel.Turbo));
    }

    [Fact]
    public void OnnxModelNeedsVad()
    {
        WriteText(Layout.Python, "x");
        MarkInstalled();
        WriteText(Path.Combine(Data, "models", "parakeet-tdt-0.6b-v3-onnx", ".complete"), "");
        Assert.Equal(EngineStateKind.ModelMissing, EngineState.Evaluate(Layout, WhisperModel.Parakeet));
        WriteText(Path.Combine(Data, "models", "silero-vad-onnx", ".complete"), "");
        Assert.Equal(EngineStateKind.Ready, EngineState.Evaluate(Layout, WhisperModel.Parakeet));
    }

    [Theory]
    [InlineData("plain", "plain")]
    [InlineData("two words", "\"two words\"")]
    [InlineData("", "\"\"")]
    [InlineData("say \"hi\"", "\"say \\\"hi\\\"\"")]
    [InlineData(@"C:\folder with space\", "\"C:\\folder with space\\\\\"")]
    public void CommandLineQuoting(string argument, string expected) => Assert.Equal(expected, CommandLine.Quote(argument));

    [Fact]
    public void LineSplitterKeepsCharactersSplitAcrossReads()
    {
        var lines = new List<string>();
        var splitter = new LineSplitter(lines.Add);
        var bytes = Encoding.UTF8.GetBytes("Привет\r\nмир");
        foreach (var b in bytes) splitter.Feed([b]);
        splitter.Finish();
        Assert.Equal(["Привет", "мир"], lines);
    }
}

public class EngineProcessTests : TempFolders
{
    private static readonly string Cmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");

    private EngineRunRequest Request(string command, string? log = null) =>
        new(Cmd, ["/c", command], EngineEnvironment.Build(new EngineLayout(Data, Calls), new EngineOptions()), Data, log);

    [Fact]
    public async Task OutputIsReadInUtf8AndWrittenToTheLog()
    {
        var log = Path.Combine(Calls, "process.log");
        var lines = new ConcurrentQueue<string>();
        var source = Path.Combine(Data, "output.txt"); // "type" hands the bytes through unchanged
        WriteText(source, "Привет мир\r\nRESULT: error 4 нет модели\r\n");
        var process = EngineProcess.Start(Request($"type {source}& exit 4", log), lines.Enqueue);
        var exit = await process.Completion;
        Assert.Equal(4, exit);
        Assert.Equal(["Привет мир", "RESULT: error 4 нет модели"], lines);
        Assert.Equal(new RunOutcome.ModelMissing("нет модели"), RunOutcome.Parse(exit, lines.ToList()));
        Assert.Contains("Привет мир", File.ReadAllText(log, Encoding.UTF8));
        File.Delete(log); // closed: the folder can be renamed
    }

    [Fact]
    public async Task AChildIsInTheJobAndStopEndsAllOfIt()
    {
        var process = EngineProcess.Start(Request("ping -n 120 127.0.0.1 >nul"));
        Assert.True(SpinWait.SpinUntil(() => process.ActiveProcesses >= 2, TimeSpan.FromSeconds(10)), "the child never showed up in the Job");
        Assert.Equal(ProcessPriorityClass.BelowNormal, Process.GetProcessById(process.ProcessId).PriorityClass);
        process.Terminate();
        Assert.Equal(EngineProcess.StoppedExitCode, await process.Completion.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(0, process.ActiveProcesses);
    }

    [Fact]
    public void ClosingTheJobKillsItsProcesses()
    {
        using var ping = Process.Start(new ProcessStartInfo("ping", "-n 120 127.0.0.1") { CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true })!;
        var job = new JobObject();
        job.Assign(ping.Handle);
        job.Dispose();
        Assert.True(ping.WaitForExit(5000), "the app's death must take the engine with it");
    }

    [Fact]
    public void AMissingProgramIsReportedNotFakedAsSuccess()
    {
        var request = new EngineRunRequest(Path.Combine(Data, "missing.exe"), [], new Dictionary<string, string>(), Data);
        Assert.Throws<EngineStartException>(() => EngineProcess.Start(request));
    }

    [Fact]
    public async Task ANotInstalledEngineCompletesAsAFailedRun()
    {
        var dir = MakeCall("2026-11-04 15-01");
        var run = new EngineSupervisor(new EngineLayout(Data, Calls), new EngineOptions()).Start(new ProcessingJob(dir, ProcessingKind.Transcribe));
        var result = await run.Completion;
        Assert.Equal(-1, result.ExitCode);
        Assert.Contains("not installed", result.Outcome.Message);
        Assert.Contains("not installed", File.ReadAllText(Path.Combine(dir, EngineSupervisor.LogName)));
    }
}

/// <summary>The real launcher in a temporary data folder, with a stub script instead of the engine.</summary>
public class SupervisorStubTests : TempFolders
{
    private const string Waits = """
        import ctypes, os, sys
        from ctypes import wintypes
        k = ctypes.WinDLL("kernel32", use_last_error=True)
        k.OpenEventW.restype = wintypes.HANDLE
        k.OpenEventW.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR]
        k.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        handle = k.OpenEventW(0x100000, False, os.environ["SOZVON_STOP_EVENT"])
        print("стартовал", os.environ["SOZVON_CALLS_DIR"], flush=True)
        k.WaitForSingleObject(handle, 0xFFFFFFFF)
        print("RESULT: error 143 остановлен", flush=True)
        sys.exit(143)
        """;

    private const string Ignores = """
        import time
        print("стартовал", flush=True)
        time.sleep(600)
        """;

    private EngineLayout Stub(string script)
    {
        RealEngine.RequirePython();
        RealEngine.Junction(Path.Combine(Data, ".venv"), Path.Combine(RealEngine.Install, ".venv"));
        MarkInstalled();
        WriteText(Path.Combine(Data, "bin", EngineSupervisor.Script), script);
        return new EngineLayout(Data, Calls);
    }

    private string RunningCall(string id)
    {
        var dir = MakeCall(id, new JsonObject { ["status"] = "processing" }, folder: id + " · Тест");
        WriteText(Path.Combine(dir, WorkFiles.Folder, "mic.wav"), "w");
        return dir;
    }

    [Fact]
    public async Task StopSignalsTheEventAndTheEngineExitsItself()
    {
        var layout = Stub(Waits);
        var dir = RunningCall("2026-11-04 15-01");
        var started = new TaskCompletionSource();
        var run = new EngineSupervisor(layout, new EngineOptions("ru"), TimeSpan.FromSeconds(10))
            .Start(new ProcessingJob(dir, ProcessingKind.Transcribe), line => { if (line.StartsWith("стартовал")) started.TrySetResult(); });
        await started.Task.WaitAsync(TimeSpan.FromSeconds(20));
        var watch = Stopwatch.StartNew();
        await run.StopAsync().WaitAsync(TimeSpan.FromSeconds(20));
        var result = await run.Completion;
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(8), "the event should end it long before the grace period");
        Assert.True(result.Stopped);
        Assert.Equal(143, result.ExitCode);
        Assert.Equal("остановлен", result.Outcome.Message);
        Assert.False(Directory.Exists(Path.Combine(dir, WorkFiles.Folder)));
        Assert.Contains("стартовал", File.ReadAllText(Path.Combine(dir, EngineSupervisor.LogName), Encoding.UTF8));
    }

    [Fact]
    public async Task AnEngineThatIgnoresStopIsEndedAfterTheGrace()
    {
        var layout = Stub(Ignores);
        var dir = RunningCall("2026-11-04 15-02");
        var started = new TaskCompletionSource();
        var processor = new CallProcessor(Calls, new EngineSupervisor(layout, new EngineOptions(), TimeSpan.FromMilliseconds(500)), () => []);
        var finished = new TaskCompletionSource<CallRunFinished>();
        processor.RunFinished += r => finished.TrySetResult(r);
        processor.OutputLine += (_, line) => { if (line.StartsWith("стартовал")) started.TrySetResult(); };
        Assert.Equal(EnqueueResult.Accepted, processor.Enqueue(dir, ProcessingKind.Transcribe));
        await started.Task.WaitAsync(TimeSpan.FromSeconds(20));
        await processor.StopRunningAsync().WaitAsync(TimeSpan.FromSeconds(20));
        var done = await finished.Task.WaitAsync(TimeSpan.FromSeconds(20));
        Assert.True(done.Stopped);
        Assert.False(Directory.Exists(Path.Combine(dir, WorkFiles.Folder)));
        Assert.Equal("failed", Json(dir).Text("status"));
    }
}

/// <summary>call.json.lock between C# and the engine's own Python code.</summary>
public class LockInteropTests : TempFolders
{
    private sealed class Python : IDisposable
    {
        private readonly Process _process;
        internal BlockingCollection<string> Lines { get; } = [];

        internal Python(string script, string argument, string dataFolder)
        {
            var info = new ProcessStartInfo(RealEngine.Python)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            info.ArgumentList.Add("-c");
            info.ArgumentList.Add(script);
            info.ArgumentList.Add(argument);
            info.Environment["PYTHONUTF8"] = "1";
            info.Environment["PYTHONPATH"] = Path.Combine(Repo.Root(), "engine");
            info.Environment["SOZVON_DATA_DIR"] = dataFolder;
            _process = Process.Start(info)!;
            _process.OutputDataReceived += (_, e) => { if (e.Data is not null) Lines.Add(e.Data); };
            _process.ErrorDataReceived += (_, e) => { if (e.Data is not null) Lines.Add("stderr: " + e.Data); };
            _process.BeginOutputReadLine();
            _process.BeginErrorReadLine();
        }

        internal string Next(int seconds = 20)
        {
            Assert.True(Lines.TryTake(out var line, TimeSpan.FromSeconds(seconds)), "no output from Python");
            return line!;
        }

        internal int Exit()
        {
            Assert.True(_process.WaitForExit(20_000));
            return _process.ExitCode;
        }

        public void Dispose()
        {
            if (!_process.HasExited) _process.Kill(entireProcessTree: true);
            _process.Dispose();
        }
    }

    private string CallJson()
    {
        var dir = MakeCall("2026-11-04 15-01", new JsonObject { ["counter"] = 0 });
        return CallFile.PathIn(dir);
    }

    [Fact]
    public void PythonWaitsWhileCSharpHoldsTheLock()
    {
        RealEngine.RequirePython();
        var file = CallJson();
        const string script = """
            import sys
            from pathlib import Path
            from sozvon_engine import jsonfile
            print("waiting", flush=True)
            with jsonfile.locked(Path(sys.argv[1])):
                print("acquired", flush=True)
            """;
        Python? python = null;
        try
        {
            FileLock.With(file, () =>
            {
                python = new Python(script, file, Data);
                Assert.Equal("waiting", python.Next());
                Assert.False(python.Lines.TryTake(out _, TimeSpan.FromSeconds(1.5)), "Python got the lock while C# held it");
                return true;
            });
            Assert.Equal("acquired", python!.Next());
            Assert.Equal(0, python.Exit());
        }
        finally
        {
            python?.Dispose();
        }
    }

    [Fact]
    public void CSharpWaitsWhilePythonHoldsTheLock()
    {
        RealEngine.RequirePython();
        var file = CallJson();
        const string script = """
            import sys, time
            from pathlib import Path
            from sozvon_engine import jsonfile
            with jsonfile.locked(Path(sys.argv[1])):
                print("held", flush=True)
                time.sleep(1.5)
            """;
        using var python = new Python(script, file, Data);
        Assert.Equal("held", python.Next());
        var waited = Stopwatch.StartNew();
        Assert.True(CallFile.Update(Path.GetDirectoryName(file)!, c => c["from_csharp"] = true));
        Assert.True(waited.Elapsed > TimeSpan.FromSeconds(0.7), "C# did not wait for the Python lock");
        Assert.True(JsonFile.Read(file)!.Flag("from_csharp"));
    }

    [Fact]
    public async Task BothSidesCountUnderTheLockWithoutLosingAWrite()
    {
        RealEngine.RequirePython();
        var file = CallJson();
        const int rounds = 15;
        var script = $$"""
            import sys
            from pathlib import Path
            from sozvon_engine import jsonfile
            path = Path(sys.argv[1])
            for _ in range({{rounds}}):
                with jsonfile.locked(path):
                    data = jsonfile.read(path, strict=True)
                    data["counter"] += 1
                    jsonfile.write_atomic(path, data)
            print("done", flush=True)
            """;
        using var python = new Python(script, file, Data);
        var dir = Path.GetDirectoryName(file)!;
        var ours = Task.Run(() =>
        {
            for (var i = 0; i < rounds; i++)
                Assert.True(CallFile.Edit(dir, c =>
                {
                    c["counter"] = c.Int("counter")!.Value + 1;
                    return true;
                }));
        });
        await ours;
        Assert.Equal("done", python.Next(40));
        Assert.Equal(0, python.Exit());
        Assert.Equal(rounds * 2, JsonFile.Read(file)!.Int("counter"));
    }
}

/// <summary>The whole engine on a synthetic call. Heavy: only with SOZVON_HEAVY_TESTS=1.</summary>
public class RealEngineTests : TempFolders
{
    private static readonly string[] Linked = [".venv", "bin", "sozvon_engine", "models", "hf-cache", "gpu"];
    private static readonly string[] Copied = ["models.json", ".gpu.json", "uv.lock", "pyproject.toml", ".python-version", "vocab.default.json", ".installed"];

    private static void Run(string exe, params string[] args)
    {
        var info = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var a in args) info.ArgumentList.Add(a);
        using var process = Process.Start(info)!;
        var errors = process.StandardError.ReadToEndAsync();
        process.StandardOutput.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0) throw new IOException($"{exe} failed: {errors.Result}");
    }

    private static void Speak(string wav)
    {
        const string script = """
            param($out)
            Add-Type -AssemblyName System.Speech
            $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
            $v = $s.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -eq 'ru-RU' } | Select-Object -First 1
            if ($v) { $s.SelectVoice($v.VoiceInfo.Name) }
            $s.SetOutputToWaveFile($out)
            $s.Speak('Добрый день. Сегодня мы обсуждаем запуск нового проекта и планы на следующую неделю. Договорились созвониться в пятницу.')
            $s.Dispose()
            """;
        var ps1 = wav + ".ps1";
        File.WriteAllText(ps1, script, new UTF8Encoding(true));
        Run("powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1, wav);
    }

    private EngineLayout PrepareDataFolder()
    {
        foreach (var name in Linked)
            RealEngine.Junction(Path.Combine(Data, name), Path.Combine(RealEngine.Install, name));
        foreach (var name in Copied)
            File.Copy(Path.Combine(RealEngine.Install, name), Path.Combine(Data, name));
        new SettingsValues { Assistant = Assistant.None, Model = WhisperModel.GigaAm, Languages = [SpeechLanguage.Ru] }.Save(Path.Combine(Data, ".env"));
        return new EngineLayout(Data, Calls);
    }

    [Fact]
    public async Task TranscribesASyntheticCall()
    {
        if (Environment.GetEnvironmentVariable("SOZVON_HEAVY_TESTS") != "1") Assert.Skip("heavy: set SOZVON_HEAVY_TESTS=1");
        RealEngine.RequirePython();
        var layout = PrepareDataFolder();
        var dir = Path.Combine(Calls, "2026-11-04 15-01");
        Directory.CreateDirectory(dir);
        var wav = Path.Combine(Root, "speech.wav");
        Speak(wav);
        Run(Path.Combine(layout.ScriptsFolder, "ffmpeg.exe"), "-y", "-loglevel", "error", "-i", wav, "-ac", "1", "-c:a", "aac", "-b:a", "64k", Path.Combine(dir, "system.m4a"));
        CallFile.Update(dir, c =>
        {
            c["schema"] = 1;
            c["id"] = "2026-11-04 15-01";
            c["status"] = "recorded";
            c["languages"] = "ru";
            c["summary"] = false;
            c["audio"] = new AudioTimes(SystemStart: 0, SystemSeconds: 12).ToJson();
        });

        var lines = new ConcurrentQueue<string>();
        var process = EngineProcess.Start(new EngineRunRequest(
            layout.Python, [layout.Script(EngineSupervisor.Script), dir, "--no-summary"],
            EngineEnvironment.Build(layout, new EngineOptions("ru")), layout.Data, Path.Combine(dir, EngineSupervisor.LogName)), lines.Enqueue);
        var exit = await process.Completion.WaitAsync(TimeSpan.FromMinutes(8));
        TestContext.Current.SendDiagnosticMessage(string.Join("\n", lines.TakeLast(25)));

        Assert.Equal(new RunOutcome.Ok(), RunOutcome.Parse(exit, lines.ToList()));
        Assert.Equal("RESULT: ok", lines.Last());
        Assert.Equal(0, exit);
        var call = Call.Load(dir)!;
        Assert.Equal(CallStatus.Done, call.Status);
        Assert.True(call.HasTranscript);
        Assert.NotEmpty(Transcript.Lines(File.ReadAllText(Path.Combine(dir, "transcript.txt"))));
        Assert.False(Directory.Exists(Path.Combine(dir, WorkFiles.Folder)));
        Assert.True(new FileInfo(Path.Combine(dir, EngineSupervisor.LogName)).Length > 0);
    }
}

public class CallProcessorTests : TempFolders
{
    private sealed class FakeRun : IEngineRun
    {
        private readonly TaskCompletionSource<EngineRunResult> _result = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal bool StopAsked { get; private set; }
        public Task<EngineRunResult> Completion => _result.Task;

        internal void Finish(RunOutcome outcome, bool stopped = false) =>
            _result.TrySetResult(new EngineRunResult(outcome.IsOk ? 0 : 1, outcome, stopped));

        public Task StopAsync()
        {
            StopAsked = true;
            Finish(new RunOutcome.Failed(143, ""), stopped: true);
            return Task.CompletedTask;
        }
    }

    private sealed class FakeRunner : IEngineRunner
    {
        internal List<(ProcessingJob Job, FakeRun Run)> Started { get; } = [];

        public IEngineRun Start(ProcessingJob job, Action<string>? onLine = null)
        {
            var run = new FakeRun();
            lock (Started) Started.Add((job, run));
            return run;
        }
    }

    private readonly FakeRunner _runner = new();

    private CallProcessor Processor() => new(Calls, _runner, () => [new Project("acme", "Acme / X")]);

    private static async Task<CallRunFinished> NextFinished(CallProcessor processor, Action trigger)
    {
        var finished = new TaskCompletionSource<CallRunFinished>(TaskCreationOptions.RunContinuationsAsynchronously);
        void Handler(CallRunFinished r) => finished.TrySetResult(r);
        processor.RunFinished += Handler;
        trigger();
        var result = await finished.Task.WaitAsync(TimeSpan.FromSeconds(5));
        processor.RunFinished -= Handler;
        return result;
    }

    [Fact]
    public async Task OneRunAtATimeFirstInFirstOutAndPersisted()
    {
        var a = MakeCall("2026-11-04 15-01", new JsonObject { ["status"] = "recorded" });
        var b = MakeCall("2026-11-04 15-02", new JsonObject { ["status"] = "recorded", ["retries"] = 1 });
        var c = MakeCall("2026-11-04 15-03", new JsonObject { ["status"] = "recorded" });
        var processor = Processor();
        Assert.Equal(EnqueueResult.Accepted, processor.Enqueue(a, ProcessingKind.Transcribe));
        processor.Enqueue(b, ProcessingKind.Transcribe);
        processor.Enqueue(c, ProcessingKind.SummaryOnly);
        Assert.Equal(EnqueueResult.Duplicate, processor.Enqueue(a, ProcessingKind.Transcribe));

        Assert.Single(_runner.Started);
        Assert.Null(Json(a)["queued_at"]);
        Assert.NotNull(Json(b)["queued_at"]);
        Assert.Null(Json(b)["retries"]);
        Assert.True(Json(c).Flag("queued_summary_only"));

        await NextFinished(processor, () => _runner.Started[0].Run.Finish(new RunOutcome.Ok()));
        Assert.Equal(2, _runner.Started.Count);
        Assert.Equal(b, _runner.Started[1].Job.Dir);
        Assert.Null(Json(b)["queued_at"]);
    }

    [Fact]
    public async Task SuccessRenamesTheFolderFromCallJson()
    {
        var a = MakeCall("2026-11-04 15-01", new JsonObject { ["status"] = "done", ["profile"] = "acme", ["topic"] = "запуск", ["participants"] = new JsonArray("Анна") });
        var processor = Processor();
        processor.Enqueue(a, ProcessingKind.Transcribe);
        var result = await NextFinished(processor, () => _runner.Started[0].Run.Finish(new RunOutcome.Ok()));
        Assert.Equal("2026-11-04 15-01 · Acme · запуск · Анна", Path.GetFileName(result.Dir));
        Assert.True(Directory.Exists(result.Dir));
        Assert.False(Directory.Exists(a));
    }

    [Fact]
    public async Task FailureMarksFailedUnlessDoneAndClearsRetries()
    {
        var a = MakeCall("2026-11-04 15-01", new JsonObject { ["status"] = "processing", ["retries"] = 1 });
        var processor = Processor();
        processor.Enqueue(a, ProcessingKind.Transcribe);
        var result = await NextFinished(processor, () => _runner.Started[0].Run.Finish(new RunOutcome.ModelMissing("x")));
        Assert.IsType<RunOutcome.ModelMissing>(result.Outcome);
        Assert.Equal("failed", Json(a).Text("status"));
        Assert.Null(Json(a)["retries"]);
    }

    [Fact]
    public async Task ASummaryRunLeavesTheStatusAlone()
    {
        var a = MakeCall("2026-11-04 15-01", new JsonObject { ["status"] = "done" });
        var processor = Processor();
        processor.Enqueue(a, ProcessingKind.SummaryOnly);
        await NextFinished(processor, () => _runner.Started[0].Run.Finish(new RunOutcome.Failed(1, "no")));
        Assert.Equal("done", Json(a).Text("status"));
        Assert.True(Directory.Exists(a));
    }

    [Fact]
    public async Task QuitStopsTheRunAndLeavesTheWaitingOnesQueued()
    {
        var a = MakeCall("2026-11-04 15-01", new JsonObject { ["status"] = "recorded" });
        var b = MakeCall("2026-11-04 15-02", new JsonObject { ["status"] = "recorded" });
        var processor = Processor();
        processor.Enqueue(a, ProcessingKind.Transcribe);
        processor.Enqueue(b, ProcessingKind.Transcribe);
        var result = await NextFinished(processor, () => processor.AbortAllAsync());
        Assert.True(result.Stopped);
        Assert.True(_runner.Started[0].Run.StopAsked);
        Assert.Equal("failed", Json(a).Text("status"));
        Assert.NotNull(Json(b)["queued_at"]);
        Assert.Single(_runner.Started);
    }

    [Fact]
    public void HeldQueueWaitsAndRestoreBringsCallsBack()
    {
        MakeCall("2026-11-04 15-01", new JsonObject { ["status"] = "recorded", ["queued_at"] = "2026-11-05T10:00:00Z" });
        var interrupted = MakeCall("2026-11-04 16-00", new JsonObject { ["status"] = "processing" });
        var processor = Processor();
        var held = true;
        processor.HoldsQueue = () => held;
        Assert.Equal(2, processor.RestoreQueue().Count);
        Assert.Empty(_runner.Started);
        held = false;
        processor.StartNext();
        Assert.Equal(interrupted, _runner.Started.Single().Job.Dir);
    }

    [Fact]
    public void RemoveFromQueueRestoresTheCall()
    {
        var a = MakeCall("2026-11-04 15-01");
        var b = MakeCall("2026-11-04 15-02", new JsonObject { ["status"] = "recorded", ["retries"] = 1 });
        var processor = Processor();
        processor.Enqueue(a, ProcessingKind.Transcribe);
        processor.Enqueue(b, ProcessingKind.Transcribe);
        CallFile.Update(b, c => c["retries"] = 1);
        Assert.True(processor.RemoveFromQueue(b));
        Assert.Null(Json(b)["queued_at"]);
        Assert.Equal("failed", Json(b).Text("status"));
        Assert.Null(Json(b)["retries"]);
    }
}
