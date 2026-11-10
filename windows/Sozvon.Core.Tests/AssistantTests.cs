using System.Net;
using System.Text;
using Sozvon.Core.Assistants;
using Sozvon.Core.Engine;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

public sealed class McpTextTests
{
    private const string Url = "http://127.0.0.1:47816/mcp";

    // What claude 2.x prints for `claude mcp get sozvon` on Windows (taken in a scratch profile), with CRLF.
    private const string ClaudeGet = "sozvon:\r\n  Scope: User config (available in all your projects)\r\n  Status: ✘ Failed to connect\r\n"
        + "  Type: http\r\n  URL: http://127.0.0.1:47816/mcp\r\n  Headers:\r\n    Authorization: Bearer abc\r\n";

    [Fact]
    public void ClaudeWithThePasswordIsConnected() => Assert.Equal(McpConnection.Connected, Mcp.Connection(0, ClaudeGet, Url));

    [Fact]
    public void ClaudeWithoutAPasswordOrOnAnotherPortIsOutdated()
    {
        Assert.Equal(McpConnection.Outdated, Mcp.Connection(0, ClaudeGet.Replace("    Authorization: Bearer abc\r\n", ""), Url));
        Assert.Equal(McpConnection.Outdated, Mcp.Connection(0, ClaudeGet, "http://127.0.0.1:47817/mcp"));
        Assert.Equal(McpConnection.Outdated, Mcp.Connection(0, "sozvon:\n  Type: stdio\n  Command: python server.py\n", Url));
    }

    [Fact]
    public void AnErrorMeansNotConnected() => Assert.Equal(McpConnection.None, Mcp.Connection(1, "No MCP server named \"sozvon\".", Url));

    [Fact]
    public void CodexHeadersDecide()
    {
        Assert.Equal(McpConnection.Connected, Mcp.Connection(0, $"sozvon\n  url: {Url}\n  http_headers: Authorization=*****\n", Url));
        Assert.Equal(McpConnection.Outdated, Mcp.Connection(0, $"sozvon\n  url: {Url}\n  http_headers: -\n", Url));
    }

    [Fact]
    public void CodexConfigGetsTheHeaderInItsSection()
    {
        const string text = "model = \"o3\"\n\n[mcp_servers.sozvon]\nurl = \"http://127.0.0.1:47816/mcp\"\nhttp_headers = { \"Authorization\" = \"Bearer old\" }\n\n[mcp_servers.other]\nurl = \"x\"\n";
        var edited = Mcp.CodexConfig(text, "new")!;
        Assert.Equal("model = \"o3\"\n\n[mcp_servers.sozvon]\nhttp_headers = { \"Authorization\" = \"Bearer new\" }\nurl = \"http://127.0.0.1:47816/mcp\"\n\n[mcp_servers.other]\nurl = \"x\"\n", edited);
        Assert.Null(Mcp.CodexConfig("[mcp_servers.other]\nurl = \"x\"\n", "t"));
    }

    [Fact]
    public void CodexConfigKeepsWindowsLineEnds()
    {
        var edited = Mcp.CodexConfig("[mcp_servers.sozvon]\r\nurl = \"u\"\r\n", "t")!;
        Assert.Equal("[mcp_servers.sozvon]\r\nhttp_headers = { \"Authorization\" = \"Bearer t\" }\r\nurl = \"u\"\r\n", edited);
    }

    [Fact]
    public void PortComesFromTheEnvironmentWhenValid()
    {
        Assert.Equal(47917, Mcp.Port("47917"));
        Assert.Equal(Mcp.DefaultPort, Mcp.Port(null));
        Assert.Equal(Mcp.DefaultPort, Mcp.Port("0"));
        Assert.Equal(Mcp.DefaultPort, Mcp.Port("http"));
    }

    [Fact]
    public void HttpStatusesAreClassified()
    {
        Assert.Equal(McpHealthState.Listening, McpHealth.Classify(HttpStatusCode.OK).State);
        Assert.Equal(McpHealthState.Unauthorized, McpHealth.Classify(HttpStatusCode.Unauthorized).State);
        Assert.Equal(McpHealthState.Unexpected, McpHealth.Classify(HttpStatusCode.NotFound).State);
    }
}

public sealed class CursorMcpConfigTests
{
    private const string Url = "http://127.0.0.1:47816/mcp";

    [Fact]
    public void AnEmptyFileGetsANewDocument()
    {
        var text = CursorMcpConfig.Upsert("", "sozvon", Url, "t")!;
        Assert.Equal("{\n  \"mcpServers\": {\n    \"sozvon\": {\n      \"url\": \"http://127.0.0.1:47816/mcp\",\n      \"headers\": {\n        \"Authorization\": \"Bearer t\"\n      }\n    }\n  }\n}\n", text);
        Assert.True(CursorMcpConfig.HasServer(text, "sozvon", Url, "t"));
        Assert.False(CursorMcpConfig.HasServer(text, "sozvon", Url, "other"));
    }

    [Fact]
    public void CommentsAndOtherServersStay()
    {
        const string text = "// my servers\n{\n  \"mcpServers\": {\n    // the one I use\n    \"github\": {\"command\": \"gh\", \"args\": [\"mcp\"]}\n  },\n  \"x\": 1.5e3\n}\n";
        var edited = CursorMcpConfig.Upsert(text, "sozvon", Url, "t")!;
        Assert.StartsWith("// my servers\n{\n  \"mcpServers\": {\n    \"sozvon\": {\n", edited);
        Assert.Contains("    // the one I use\n    \"github\": {\"command\": \"gh\", \"args\": [\"mcp\"]}\n  },\n  \"x\": 1.5e3\n}\n", edited);
        Assert.True(CursorMcpConfig.HasServer(edited, "sozvon", Url, "t"));
        Assert.Equal(text, CursorMcpConfig.Remove(edited, "sozvon"));
    }

    [Fact]
    public void AnOldEntryIsReplacedInPlaceAndDuplicatesGo()
    {
        const string text = "{\n  \"mcpServers\": {\n    \"sozvon\": {\"command\": \"python\"},\n    \"a\": {},\n    \"sozvon\": {\"url\": \"old\"}\n  }\n}";
        Assert.True(CursorMcpConfig.HasEntry(text, "sozvon"));
        Assert.False(CursorMcpConfig.HasServer(text, "sozvon", Url));
        var edited = CursorMcpConfig.Upsert(text, "sozvon", Url, "t")!;
        Assert.Equal(1, Count(edited, "\"sozvon\""));
        Assert.Contains("\"a\": {}", edited);
        Assert.True(CursorMcpConfig.HasServer(edited, "sozvon", Url, "t"));
    }

    [Fact]
    public void ARootWithoutServersGetsThem()
    {
        var edited = CursorMcpConfig.Upsert("{\n  \"other\": true\n}\n", "sozvon", Url, "t")!;
        Assert.True(CursorMcpConfig.HasServer(edited, "sozvon", Url, "t"));
        Assert.Contains("\"other\": true", edited);
    }

    [Fact]
    public void WindowsLineEndsAreRemovedWithTheirLine()
    {
        const string text = "{\r\n  \"mcpServers\": {\r\n    \"a\": {},\r\n    \"sozvon\": {\"url\": \"u\"}\r\n  }\r\n}\r\n";
        Assert.Equal("{\r\n  \"mcpServers\": {\r\n    \"a\": {}\r\n  }\r\n}\r\n", CursorMcpConfig.Remove(text, "sozvon"));
    }

    [Theory]
    [InlineData("{ \"mcpServers\": [] }")]
    [InlineData("{ \"mcpServers\": {}, \"mcpServers\": {} }")]
    [InlineData("{ \"a\": 1 ")]
    [InlineData("[1, 2]")]
    [InlineData("{ /* open comment ")]
    public void WhatCannotBeEditedSafelyIsLeftAlone(string text) => Assert.Null(CursorMcpConfig.Upsert(text, "sozvon", Url, "t"));

    [Fact]
    public void RemovingWhatIsNotThereChangesNothing()
    {
        const string text = "{ \"mcpServers\": { \"a\": {} } }";
        Assert.Equal(text, CursorMcpConfig.Remove(text, "sozvon"));
        Assert.Equal("", CursorMcpConfig.Remove("", "sozvon"));
    }

    [Fact]
    public void EscapedStringsAreRead()
    {
        const string text = "{\"mcpServers\": {\"sozvon\": {\"url\": \"http:\\/\\/127.0.0.1:47816\\/mcp\", \"headers\": {\"Authorization\": \"Bearer \\u0074\"}}}}";
        Assert.True(CursorMcpConfig.HasServer(text, "sozvon", Url, "t"));
    }

    private static int Count(string text, string part) => (text.Length - text.Replace(part, "").Length) / part.Length;
}

/// <summary>Connecting against a temporary profile only: a fake tool that records its arguments, real files for Cursor and Codex.</summary>
public sealed class McpConnectionsTests : TempFolders
{
    private readonly FakeRunner _runner = new();
    private readonly McpEndpoint _endpoint = new(47917, "secret");

    private string Home => Path.Combine(Root, "home");

    private AssistantHome Profile => new(Home, Path.Combine(Home, "AppData", "Local"), Path.Combine(Home, "AppData", "Roaming"), "");

    private McpConnections Connections => new(_endpoint, Profile, _runner);

    private string Tool(string name)
    {
        var path = Path.Combine(Home, ".local", "bin", name + ".exe");
        WriteText(path, "");
        return path;
    }

    [Fact]
    public void NothingIsInstalledInAnEmptyProfile()
    {
        Assert.All(McpConnections.All, a => Assert.False(Connections.IsInstalled(a)));
        Assert.Equal(McpFailure.NotInstalled, Connections.Connect(Assistant.Claude).Failure);
        Assert.Equal(McpConnection.None, Connections.Connection(Assistant.Codex));
        Assert.Empty(_runner.Calls);
    }

    [Fact]
    public void ClaudeIsAddedForTheUserWithThePasswordLast()
    {
        var claude = Tool("claude");
        Assert.True(Connections.IsInstalled(Assistant.Claude));
        Assert.True(Connections.Connect(Assistant.Claude).Ok);
        Assert.Equal(
        [
            $"{claude} mcp remove sozvon --scope user",
            $"{claude} mcp add --scope user --transport http sozvon http://127.0.0.1:47917/mcp --header Authorization: Bearer secret",
        ], _runner.Calls);
    }

    [Fact]
    public void AFailingToolSaysWhy()
    {
        Tool("claude");
        _runner.Answer = (2, "boom");
        var result = Connections.Connect(Assistant.Claude);
        Assert.Equal(McpFailure.ToolFailed, result.Failure);
        Assert.Equal("boom", result.Output);
    }

    [Fact]
    public void CodexGetsItsHeaderInConfigToml()
    {
        Tool("codex");
        var config = Path.Combine(Home, ".codex", "config.toml");
        _runner.OnRun = args =>
        {
            if (args[1] == "add") WriteText(config, "[mcp_servers.sozvon]\nurl = \"http://127.0.0.1:47917/mcp\"\n");
        };
        Assert.True(Connections.Connect(Assistant.Codex).Ok);
        Assert.Contains("mcp add sozvon --url http://127.0.0.1:47917/mcp", _runner.Calls[1]);
        Assert.Equal("[mcp_servers.sozvon]\nhttp_headers = { \"Authorization\" = \"Bearer secret\" }\nurl = \"http://127.0.0.1:47917/mcp\"\n", File.ReadAllText(config));
    }

    [Fact]
    public void CursorIsFoundByItsFolderAndConnectedInItsFile()
    {
        Directory.CreateDirectory(Path.Combine(Home, ".cursor"));
        Assert.True(Connections.IsInstalled(Assistant.Cursor));
        Assert.Equal(McpConnection.None, Connections.Connection(Assistant.Cursor));
        Assert.True(Connections.Connect(Assistant.Cursor).Ok);
        Assert.Equal(McpConnection.Connected, Connections.Connection(Assistant.Cursor));
        Assert.Equal(McpConnection.Outdated, new McpConnections(_endpoint with { Token = "new" }, Profile, _runner).Connection(Assistant.Cursor));
        Assert.True(Connections.Disconnect(Assistant.Cursor).Ok);
        Assert.Equal(McpConnection.None, Connections.Connection(Assistant.Cursor));
        Assert.Empty(_runner.Calls);
    }

    [Fact]
    public void CursorKeepsTheByteOrderMark()
    {
        var file = Path.Combine(Home, ".cursor", "mcp.json");
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, "{ \"mcpServers\": {} }", new UTF8Encoding(true));
        Assert.True(Connections.Connect(Assistant.Cursor).Ok);
        Assert.True(File.ReadAllBytes(file).AsSpan().StartsWith(Encoding.UTF8.Preamble));
    }

    [Fact]
    public void ABrokenCursorFileIsNotTouched()
    {
        var file = Path.Combine(Home, ".cursor", "mcp.json");
        WriteText(file, "{ broken");
        Assert.Equal(McpFailure.CannotParse, Connections.Connect(Assistant.Cursor).Failure);
        Assert.Equal("{ broken", File.ReadAllText(file));
    }

    [Fact]
    public void ManualSetupCarriesThePassword()
    {
        Assert.Contains("--header 'Authorization: Bearer secret'", Connections.ManualSetup(Assistant.Claude));
        Assert.Contains("Bearer secret", Connections.ManualSetup(Assistant.Codex));
        Assert.Contains("\"Authorization\": \"Bearer secret\"", Connections.ManualSetup(Assistant.Cursor));
        Assert.DoesNotContain("secret", McpConnections.ShortCommand(Assistant.Claude, _endpoint.Url));
    }

    [Fact]
    public void TheTokenIsMadeOnceAndKept()
    {
        var token = Mcp.Token(Data);
        Assert.Equal(64, token.Length);
        Assert.Equal(token, Mcp.Token(Data));
        Assert.Equal(token, File.ReadAllText(Path.Combine(Data, Mcp.TokenFile)));
    }

    [Fact]
    public void AnNpmWrapperRunsItsScriptWithNode()
    {
        var bin = Path.Combine(Home, "AppData", "Roaming", "npm");
        WriteText(Path.Combine(bin, "codex.cmd"), "@ECHO off\r\n\"%_prog%\"  \"%dp0%\\node_modules\\@openai\\codex\\bin\\codex.js\" %*\r\n");
        WriteText(Path.Combine(bin, "node_modules", "@openai", "codex", "bin", "codex.js"), "");
        Assert.Null(AssistantCli.Find("codex", Profile)); // no node: it cannot be started safely
        WriteText(Path.Combine(bin, "node.exe"), "");
        var found = AssistantCli.Find("codex", Profile)!;
        Assert.Equal([Path.Combine(bin, "node.exe"), Path.Combine(bin, "node_modules", "@openai", "codex", "bin", "codex.js")], AssistantCli.Argv(found, Profile));
    }

    [Fact]
    public void AWrapperPointingOutsideItsFolderIsRefused()
    {
        var bin = Path.Combine(Home, "AppData", "Roaming", "npm");
        WriteText(Path.Combine(bin, "node.exe"), "");
        WriteText(Path.Combine(Root, "evil.js"), "");
        WriteText(Path.Combine(bin, "codex.cmd"), "\"%dp0%\\..\\..\\..\\..\\evil.js\" %*\r\n");
        Assert.Null(AssistantCli.Find("codex", Profile));
    }

    private sealed class FakeRunner : ICliRunner
    {
        public List<string> Calls { get; } = [];
        public (int, string) Answer { get; set; } = (0, "");
        public Action<IReadOnlyList<string>>? OnRun { get; set; }

        public (int ExitCode, string Output) Run(string cli, IReadOnlyList<string> arguments)
        {
            Calls.Add(cli + " " + string.Join(' ', arguments));
            OnRun?.Invoke(arguments);
            return Answer;
        }
    }
}

/// <summary>The real server.py of the test install, on a port of its own.</summary>
public sealed class McpServerTests : TempFolders
{
    [Fact]
    public async Task TheSharedServerAnswersWithThePasswordOnly()
    {
        RealEngine.RequirePython();
        foreach (var name in new[] { ".venv", "sozvon_engine" })
            RealEngine.Junction(Path.Combine(Data, name), Path.Combine(RealEngine.Install, name));
        File.Copy(Path.Combine(RealEngine.Install, McpServer.Script), Path.Combine(Data, McpServer.Script));
        var endpoint = new McpEndpoint(47931, Mcp.Token(Data));
        var server = new McpServer(new EngineLayout(Data, Calls), () => new EngineOptions("en"), endpoint);
        server.Start();
        try
        {
            var health = new McpHealth(McpHealthState.NotListening);
            for (var i = 0; i < 120 && health.State != McpHealthState.Listening; i++)
            {
                await Task.Delay(500, TestContext.Current.CancellationToken);
                health = await McpHealth.ProbeAsync(endpoint, TestContext.Current.CancellationToken);
            }
            Assert.Equal(McpHealthState.Listening, health.State);
            Assert.Equal(McpHealthState.Unauthorized, (await McpHealth.ProbeAsync(endpoint with { Token = "wrong" }, TestContext.Current.CancellationToken)).State);
        }
        finally
        {
            server.Stop();
        }
        await Task.Delay(1000, TestContext.Current.CancellationToken);
        Assert.Equal(McpHealthState.NotListening, (await McpHealth.ProbeAsync(endpoint, TestContext.Current.CancellationToken)).State);
        Assert.Contains("server.py --http", File.ReadAllText(server.LogPath));
    }
}
