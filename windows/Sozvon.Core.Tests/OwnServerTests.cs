using System.Text.Json.Nodes;
using Sozvon.Core.Engine;
using Sozvon.Core.Server;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

/// <summary>The own server's client: address rules, answers, and the sync run, all against a local stub; no real server.</summary>
public sealed class OwnServerTests : TempFolders
{
    private const string Health = """{"ok": true, "version": "0.4.1", "schema": 1}""";

    [Theory]
    [InlineData("https://Sozvon.Example.com/", "https://sozvon.example.com")]
    [InlineData("  https://example.com/sozvon//  ", "https://example.com/sozvon")]
    [InlineData("https://example.com:8443", "https://example.com:8443")]
    [InlineData("http://127.0.0.1:8787", "http://127.0.0.1:8787")]
    [InlineData("http://localhost:8787/", "http://localhost:8787")]
    [InlineData("http://example.com", null)]
    [InlineData("https://user:pass@example.com", null)]
    [InlineData("https://example.com/?a=1", null)]
    [InlineData("https://example.com/#x", null)]
    [InlineData("example.com", null)]
    [InlineData("", null)]
    public void AddressesAreNormalized(string raw, string? normalized) => Assert.Equal(normalized, OwnServer.Normalize(raw));

    [Fact]
    public void BothAddressAndPasswordMakeAServer()
    {
        Assert.True(OwnServer.IsConfigured("https://x.example", "p"));
        Assert.False(OwnServer.IsConfigured("https://x.example", "  "));
        Assert.False(OwnServer.IsConfigured("http://x.example", "p"));
        Assert.Equal("https://x.example/mcp", OwnServer.ConnectorUrl("https://x.example"));
    }

    [Fact]
    public void HealthAnswersAreRead()
    {
        Assert.Equal(new ServerHealth.Ok("0.4.1"), OwnServer.Health(200, Health));
        Assert.Equal(new ServerHealth.Ok(""), OwnServer.Health(200, """{"ok": true, "schema": 1}"""));
        Assert.Equal(new ServerHealth.Status(502), OwnServer.Health(502, Health));
        Assert.IsType<ServerHealth.NotOurs>(OwnServer.Health(200, "<html>"));
        Assert.IsType<ServerHealth.NotOurs>(OwnServer.Health(200, """{"ok": "yes"}"""));
        Assert.IsType<ServerHealth.Incompatible>(OwnServer.Health(200, """{"ok": true, "schema": 2}"""));
    }

    [Fact]
    public void SyncResultLinesAreRead()
    {
        Assert.Equal(new SyncResult.Ok(3, 1, 12, 2, 1), OwnServer.ParseSyncResult("RESULT: ok 3 1 12 2 1"));
        Assert.Equal(new SyncResult.Ok(3, 1, 0, 0, 0), OwnServer.ParseSyncResult("RESULT: ok 3 1"));
        Assert.Equal(new SyncResult.Error(2, "неверный пароль"), OwnServer.ParseSyncResult("RESULT: error 2 неверный пароль"));
        Assert.Null(OwnServer.ParseSyncResult("STATUS: отправляю 1 из 3"));
        Assert.Null(OwnServer.ParseSyncResult("RESULT: ok three 1"));
    }

    [Fact]
    public async Task HealthAndPasswordAreCheckedAgainstTheStub()
    {
        using var stub = new StubHttpServer(r => r.Path switch
        {
            "/api/health" => (200, Health),
            "/api/calls" => r.Authorization == "Bearer right" ? (200, """{"calls": []}""") : (401, "{}"),
            _ => (404, "{}"),
        });
        var token = TestContext.Current.CancellationToken;
        Assert.Equal(new ServerHealth.Ok("0.4.1"), await OwnServer.CheckHealthAsync(stub.Url, cancellationToken: token));
        Assert.True(await OwnServer.AcceptsAsync(stub.Url, "right", cancellationToken: token));
        Assert.False(await OwnServer.AcceptsAsync(stub.Url, "wrong", cancellationToken: token));
        Assert.Equal(new ServerHealth.Status(404), await OwnServer.CheckHealthAsync(stub.Url + "/nothing", cancellationToken: token));
        Assert.DoesNotContain(stub.Requests, r => r.Path == "/api/health" && r.Authorization.Length > 0);
    }

    [Fact]
    public async Task NobodyListeningIsUnreachable()
    {
        int port;
        using (var stub = new StubHttpServer(_ => (200, "")))
            port = stub.Port;
        Assert.IsType<ServerHealth.Unreachable>(await OwnServer.CheckHealthAsync($"http://127.0.0.1:{port}", cancellationToken: TestContext.Current.CancellationToken));
    }

    [Fact]
    public void DeletedCallsAreListedOnceAndRemoved()
    {
        var file = Path.Combine(Data, ServerLists.DeletedFile);
        var at = new DateTimeOffset(2026, 11, 5, 10, 0, 0, TimeSpan.Zero);
        ServerLists.Add(file, "2026-11-04 15-01", at);
        ServerLists.Add(file, "2026-11-04 15-01", at);
        ServerLists.Add(file, "2026-11-04 16-00", at);
        Assert.Equal(["2026-11-04 15-01", "2026-11-04 16-00"], ServerLists.Ids(file));
        var json = JsonNode.Parse(File.ReadAllText(file))!;
        Assert.Equal(1, json["schema"]!.GetValue<int>());
        Assert.Equal("2026-11-05T10:00:00Z", json["calls"]![0]!["at"]!.GetValue<string>());
        ServerLists.Remove(file, "2026-11-04 15-01");
        Assert.Equal(["2026-11-04 16-00"], ServerLists.Ids(file));
        Assert.True(File.Exists(file + ".lock"));
    }

    [Fact]
    public void SavingTheServerKeepsTheWizardsAnswers()
    {
        var env = Path.Combine(Data, ".env");
        WriteText(env, "SOZVON_LLM=\"none\"\nSOZVON_SERVER_URL=\"https://old\"\nOTHER=1\n");
        SettingsValues.SaveServer(env, " https://new.example ", "secret", syncAudio: false, syncVoices: true);
        var values = SettingsValues.Load(env);
        Assert.Equal(Assistant.None, values.Assistant);
        Assert.Equal(("https://new.example", "secret", false, true), (values.ServerUrl, values.ServerPassword, values.SyncAudio, values.SyncVoices));
        Assert.Contains("OTHER=1", File.ReadAllText(env));
        SettingsValues.SaveServer(env, "", "", syncAudio: true, syncVoices: true);
        Assert.DoesNotContain("SOZVON_SERVER", File.ReadAllText(env));
    }

    [Fact]
    public async Task AWrongPasswordNeverStartsASync()
    {
        var runs = 0;
        var sync = new ServerSync(() => new ServerConfig("https://x.example", "bad"), _ => Task.FromResult<ServerHealth>(new ServerHealth.Ok("1")),
            (_, _) => Task.FromResult(false), _ => { runs++; return Task.FromResult((0, (SyncResult?)new SyncResult.Ok(0, 0, 0, 0, 0), "")); });
        await sync.SettingsChangedAsync();
        Assert.IsType<SyncStatus.WrongPassword>(sync.Status);
        Assert.True(sync.Failed);
        Assert.Null(sync.ConnectorUrl);
        Assert.Equal(0, runs);
    }

    [Fact]
    public async Task ARightPasswordSyncsAndShowsTheConnector()
    {
        var sync = new ServerSync(() => new ServerConfig("https://x.example/", "good"), _ => Task.FromResult<ServerHealth>(new ServerHealth.Ok("0.4.1")),
            (_, password) => Task.FromResult(password == "good"), onLine =>
            {
                onLine("STATUS: проверяю");
                return Task.FromResult((0, (SyncResult?)new SyncResult.Ok(2, 0, 1, 0, 0), "RESULT: ok 2 0 1 0 0"));
            });
        await sync.SettingsChangedAsync();
        Assert.Equal("https://x.example/mcp", sync.ConnectorUrl);
        Assert.Equal("0.4.1", sync.ServerVersion);
        var done = Assert.IsType<SyncStatus.Done>(sync.Status);
        Assert.Equal(new SyncResult.Ok(2, 0, 1, 0, 0), done.Result);
        Assert.False(sync.Failed);
    }

    [Fact]
    public async Task ASyncAskedForWhileRunningRunsOnceMore()
    {
        var gate = new TaskCompletionSource();
        var runs = 0;
        var sync = new ServerSync(() => new ServerConfig("https://x.example", "p"), _ => Task.FromResult<ServerHealth>(new ServerHealth.Ok("")),
            (_, _) => Task.FromResult(true), async _ =>
            {
                if (Interlocked.Increment(ref runs) == 1) await gate.Task;
                return (1, null, "Traceback");
            });
        var first = sync.SyncAsync();
        await sync.SyncAsync();
        await sync.SyncAsync();
        gate.SetResult();
        await first;
        Assert.Equal(2, runs);
        Assert.Equal(new SyncStatus.Crashed(1, "Traceback"), sync.Status);
        Assert.False(sync.IsRunning);
    }

    [Fact]
    public async Task NoServerNoSync()
    {
        var runs = 0;
        var sync = new ServerSync(() => new ServerConfig("", ""), _ => throw new InvalidOperationException(), (_, _) => throw new InvalidOperationException(),
            _ => { runs++; return Task.FromResult((0, (SyncResult?)null, "")); });
        await sync.SettingsChangedAsync();
        await sync.SyncAsync();
        Assert.IsType<SyncStatus.None>(sync.Status);
        Assert.Equal(0, runs);
    }

    /// <summary>The engine's real sync_server.py against the stub: a deleted call goes, a finished one is sent.</summary>
    [Fact]
    public async Task TheEnginesSyncTalksToTheStub()
    {
        RealEngine.RequirePython();
        foreach (var name in new[] { ".venv", "sozvon_engine", "bin" })
            RealEngine.Junction(Path.Combine(Data, name), Path.Combine(RealEngine.Install, name));
        using var stub = new StubHttpServer(r => (r.Method, r.Path) switch
        {
            ("GET", "/api/health") => (200, Health),
            _ when r.Authorization != "Bearer secret" => (401, "{}"),
            ("GET", "/api/calls") => (200, """{"calls": [{"id": "2026-11-01 09-00", "hash": "x", "notes": []}], "deleted": []}"""),
            ("GET", "/api/voices") => (200, """{"voices": []}"""),
            ("GET", _) => (404, "{}"),
            _ => (200, "{}"),
        });
        new SettingsValues { Assistant = Assistant.None }.Save(Path.Combine(Data, ".env"));
        SettingsValues.SaveServer(Path.Combine(Data, ".env"), stub.Url, "secret", syncAudio: false, syncVoices: false);
        ServerLists.Add(Path.Combine(Data, ServerLists.DeletedFile), "2026-11-01 09-00", DateTimeOffset.UtcNow);
        var dir = MakeCall("2026-11-04 15-01", new JsonObject { ["status"] = "done", ["created_at"] = "2026-11-04T12:01:00Z" });
        WriteText(Path.Combine(dir, "transcript.txt"), "[00:00] Я: Привет\n");
        WriteText(Path.Combine(dir, "transcript.md"), "# Звонок\n\n[00:00] Я: Привет\n");
        var lines = new List<string>();
        var (code, result, last) = await ServerSyncScript.RunAsync(new EngineLayout(Data, Calls), new EngineOptions("en"), lines.Add);
        Assert.True(result is SyncResult.Ok { Sent: 1, Deleted: 1 }, $"exit {code}, {last}\n{string.Join('\n', lines)}");
        Assert.Contains(stub.Requests, r => r.Method == "DELETE" && r.Path == "/api/calls/2026-11-01 09-00");
        Assert.Contains(stub.Requests, r => r.Method == "PUT" && r.Path == "/api/calls/2026-11-04 15-01" && r.Body.Contains("Привет"));
        Assert.Empty(ServerLists.Ids(Path.Combine(Data, ServerLists.DeletedFile)));
        Assert.True(File.Exists(Path.Combine(Data, OwnServer.SyncLog)));
    }
}
