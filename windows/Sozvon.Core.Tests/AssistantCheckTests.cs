using System.Diagnostics;
using Sozvon.Core.Assistants;
using Sozvon.Core.Engine;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

/// <summary>The last line of <c>bin\check_assistant.py</c>: whether the chosen assistant answered, and what it said.</summary>
public sealed class AssistantCheckParseTests
{
    [Fact]
    public void AnAnswerIsOk()
    {
        Assert.Equal(AssistantCheck.Ok, AssistantCheck.Parse(["something", "RESULT: ok OK"], 0));
        Assert.Equal(AssistantCheck.Ok, AssistantCheck.Parse(["RESULT: ok"], 0));
    }

    [Fact]
    public void AnErrorKeepsTheAssistantsOwnWordsAndTheHint()
    {
        const string line = "RESULT: error OAuth token has expired. Войди заново: запусти claude в Терминале и набери /login";
        Assert.Equal(AssistantCheck.Failed("OAuth token has expired. Войди заново: запусти claude в Терминале и набери /login"),
                     AssistantCheck.Parse([line], 1));
    }

    [Fact]
    public void TheLastResultLineWins()
    {
        Assert.Equal(AssistantCheck.Failed("не найден claude CLI"),
                     AssistantCheck.Parse(["RESULT: ok old", "RESULT: error не найден claude CLI"], 1));
    }

    [Fact]
    public void NoResultLineIsAFailureWithTheLastLine()
    {
        Assert.Equal(AssistantCheck.Failed("ModuleNotFoundError: x"), AssistantCheck.Parse(["Traceback", "ModuleNotFoundError: x", "  "], 3));
        Assert.Equal(AssistantCheck.Failed(""), AssistantCheck.Parse([], 1));
    }

    [Fact]
    public void TheScriptGetsTheEnginesNames()
    {
        Assert.Equal("claude", AssistantCheckScript.Argument(Assistant.Claude));
        Assert.Equal("codex", AssistantCheckScript.Argument(Assistant.Codex));
        Assert.Equal("cursor", AssistantCheckScript.Argument(Assistant.Cursor));
        Assert.Throws<ArgumentOutOfRangeException>(() => AssistantCheckScript.Argument(Assistant.None));
    }
}

/// <summary>The real launcher with a stub check_assistant.py in a temporary data folder.</summary>
public sealed class AssistantCheckRunTests : TempFolders
{
    private EngineLayout Stub(string script)
    {
        RealEngine.RequirePython();
        RealEngine.Junction(Path.Combine(Data, ".venv"), Path.Combine(RealEngine.Install, ".venv"));
        MarkInstalled();
        WriteText(Path.Combine(Data, "bin", AssistantCheckScript.Script), script);
        return new EngineLayout(Data, Calls);
    }

    [Fact]
    public async Task AnAnsweringAssistantIsOk()
    {
        var layout = Stub("""
            import os, sys
            print("checking", sys.argv[1], os.environ["SOZVON_UI_LANG"], flush=True)
            print("RESULT: ok OK" if sys.argv[1] == "codex" and os.environ["SOZVON_UI_LANG"] == "en" else "RESULT: error wrong call", flush=True)
            """);
        Assert.Equal(AssistantCheck.Ok, await AssistantCheckScript.RunAsync(layout, new EngineOptions("en"), Assistant.Codex));
    }

    [Fact]
    public async Task AFailureCarriesItsMessage()
    {
        var layout = Stub("""
            import sys
            print("RESULT: error Not logged in. Войди заново: cursor-agent login", flush=True)
            sys.exit(1)
            """);
        Assert.Equal(AssistantCheck.Failed("Not logged in. Войди заново: cursor-agent login"),
                     await AssistantCheckScript.RunAsync(layout, new EngineOptions(), Assistant.Cursor));
    }

    [Fact]
    public async Task AHangingCheckIsEndedAfterTheTimeout()
    {
        var layout = Stub("""
            import time
            print("waiting", flush=True)
            time.sleep(600)
            """);
        var watch = Stopwatch.StartNew();
        var result = await AssistantCheckScript.RunAsync(layout, new EngineOptions(), Assistant.Claude, TimeSpan.FromSeconds(3));
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(20), $"took {watch.Elapsed}");
        Assert.Equal(new AssistantCheck(AssistantCheckState.Failed, "", TimedOut: true), result);
    }

    [Fact]
    public async Task NoEngineIsAFailureNotACrash()
    {
        var result = await AssistantCheckScript.RunAsync(new EngineLayout(Data, Calls), new EngineOptions(), Assistant.Claude);
        Assert.Equal(AssistantCheckState.Failed, result.State);
        Assert.Contains("not installed", result.Message);
    }
}
