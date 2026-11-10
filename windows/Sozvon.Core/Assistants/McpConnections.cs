using System.Text;
using Sozvon.Core.Foundation;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Assistants;

/// <summary>Why connecting or disconnecting did not happen; the output, when there is one, says more.</summary>
public enum McpFailure
{
    /// <summary>The assistant's command line tool is not installed.</summary>
    NotInstalled,

    /// <summary>The tool answered with an error.</summary>
    ToolFailed,

    /// <summary>Cursor's mcp.json is not JSON that can be edited safely: the Copy button is left.</summary>
    CannotParse,

    /// <summary>A config file could not be written.</summary>
    WriteFailed,
}

public sealed record McpResult(McpFailure? Failure = null, string Output = "")
{
    public bool Ok => Failure is null;
}

/// <summary>
/// Connects Sozvon to Claude Code, Codex and Cursor, as on the Mac: Claude and Codex through their own <c>mcp add</c>, Cursor
/// by editing its mcp.json. Codex and Cursor are only ever touched when the user presses their button. Every method runs
/// a tool or touches a file: not on the UI thread.
/// </summary>
public sealed class McpConnections(McpEndpoint endpoint, AssistantHome home, ICliRunner runner)
{
    public static readonly IReadOnlyList<Assistant> All = [Assistant.Claude, Assistant.Codex, Assistant.Cursor];

    public string CursorFolder => Path.Combine(home.Home, ".cursor");

    public string CursorConfig => Path.Combine(CursorFolder, "mcp.json");

    public string CodexConfigFile => Path.Combine(Environment.GetEnvironmentVariable("CODEX_HOME") is { Length: > 0 } codexHome ? codexHome : Path.Combine(home.Home, ".codex"), "config.toml");

    /// <summary>The Cursor app's own install, per user.</summary>
    private string CursorApp => Path.Combine(home.LocalAppData, "Programs", "cursor", "Cursor.exe");

    /// <summary>Whether there is something to connect: the tool, or for Cursor also the app or its .cursor folder.</summary>
    public bool IsInstalled(Assistant a) =>
        AssistantCli.Find(a, home) is not null
        || (a == Assistant.Cursor && (Directory.Exists(CursorFolder) || File.Exists(CursorApp)));

    public McpConnection Connection(Assistant a)
    {
        if (a == Assistant.Cursor) return CursorConnection();
        if (AssistantCli.Find(a, home) is not { } cli) return McpConnection.None;
        var (code, output) = runner.Run(cli, ["mcp", "get", Mcp.Name]);
        return Mcp.Connection(code, output, endpoint.Url);
    }

    /// <summary>The assistant talks to Sozvon's shared server instead of starting its own copy in every session.</summary>
    public McpResult Connect(Assistant a)
    {
        if (a == Assistant.Cursor) return CursorConnect();
        if (AssistantCli.Find(a, home) is not { } cli) return new McpResult(McpFailure.NotInstalled);
        IReadOnlyList<string> add = a == Assistant.Claude
            // --header goes last: the option is greedy and would otherwise swallow the name and the address
            ? ["mcp", "add", "--scope", "user", "--transport", "http", Mcp.Name, endpoint.Url, "--header", $"Authorization: Bearer {endpoint.Token}"]
            : ["mcp", "add", Mcp.Name, "--url", endpoint.Url];
        runner.Run(cli, RemoveArguments(a));
        var (code, output) = runner.Run(cli, add);
        if (code != 0) return new McpResult(McpFailure.ToolFailed, output);
        if (a == Assistant.Codex && SharedFile.ReadText(CodexConfigFile) is { } text && Mcp.CodexConfig(text, endpoint.Token) is { } edited)
        {
            return Write(CodexConfigFile, edited);
        }
        return new McpResult();
    }

    public McpResult Disconnect(Assistant a)
    {
        if (a == Assistant.Cursor) return CursorDisconnect();
        if (AssistantCli.Find(a, home) is not { } cli) return new McpResult(McpFailure.NotInstalled);
        var (code, output) = runner.Run(cli, RemoveArguments(a));
        return code == 0 ? new McpResult() : new McpResult(McpFailure.ToolFailed, output);
    }

    /// <summary>The short form shown in the row; the copied text also carries the transport and the password.</summary>
    public static string ShortCommand(Assistant a, string url) => a == Assistant.Cursor
        ? $"%USERPROFILE%\\.cursor\\mcp.json: \"{Mcp.Name}\": {url}"
        : $"{AssistantCli.Name(a)} mcp add {Mcp.Name} {url}";

    /// <summary>What Connect does, as text to paste into PowerShell. It holds the password: only for the clipboard on request.</summary>
    public string ManualSetup(Assistant a) => a switch
    {
        Assistant.Claude => $"claude mcp add --scope user --transport http {Mcp.Name} {endpoint.Url} --header 'Authorization: Bearer {endpoint.Token}'",
        Assistant.Codex => $"codex mcp add {Mcp.Name} --url {endpoint.Url}\n"
            + $"# then add this line to the [mcp_servers.{Mcp.Name}] section of %USERPROFILE%\\.codex\\config.toml:\n"
            + $"# http_headers = {{ \"Authorization\" = \"Bearer {endpoint.Token}\" }}",
        Assistant.Cursor => CursorMcpConfig.Snippet(Mcp.Name, endpoint.Url, endpoint.Token),
        _ => $"{endpoint.Url}\nAuthorization: Bearer {endpoint.Token}",
    };

    private static IReadOnlyList<string> RemoveArguments(Assistant a) =>
        a == Assistant.Claude ? ["mcp", "remove", Mcp.Name, "--scope", "user"] : ["mcp", "remove", Mcp.Name];

    private McpConnection CursorConnection()
    {
        if (SharedFile.ReadText(CursorConfig) is not { } text) return McpConnection.None;
        if (CursorMcpConfig.HasServer(text, Mcp.Name, endpoint.Url, endpoint.Token)) return McpConnection.Connected;
        return CursorMcpConfig.HasEntry(text, Mcp.Name) ? McpConnection.Outdated : McpConnection.None;
    }

    /// <summary>Adds or updates the Sozvon entry, keeping comments and other servers; creates the file and the folder if missing.</summary>
    private McpResult CursorConnect()
    {
        var target = ResolveLink(CursorConfig);
        var text = File.Exists(target) ? SharedFile.ReadText(target) : "";
        if (text is null || CursorMcpConfig.Upsert(text, Mcp.Name, endpoint.Url, endpoint.Token) is not { } edited)
            return new McpResult(McpFailure.CannotParse);
        return edited == text ? new McpResult() : Write(target, edited);
    }

    /// <summary>Removes the Sozvon entry. A missing file or no entry: nothing to do.</summary>
    private McpResult CursorDisconnect()
    {
        var target = ResolveLink(CursorConfig);
        if (SharedFile.ReadText(target) is not { } text) return new McpResult();
        if (CursorMcpConfig.Remove(text, Mcp.Name) is not { } edited) return new McpResult(McpFailure.CannotParse);
        return edited == text ? new McpResult() : Write(target, edited);
    }

    /// <summary>A file kept elsewhere through a symbolic link is edited where it really is, and the link stays.</summary>
    private static string ResolveLink(string path)
    {
        try
        {
            return File.ResolveLinkTarget(path, returnFinalTarget: true)?.FullName ?? path;
        }
        catch (IOException)
        {
            return path;
        }
    }

    /// <summary>An atomic write; a byte order mark the file had stays.</summary>
    private static McpResult Write(string path, string text)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var bom = SharedFile.ReadBytes(path)?.AsSpan().StartsWith(Encoding.UTF8.Preamble) == true;
            AtomicFile.Write(path, new UTF8Encoding(bom).GetPreamble().Concat(new UTF8Encoding(false).GetBytes(text)).ToArray());
            return new McpResult();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return new McpResult(McpFailure.WriteFailed, e.Message);
        }
    }
}
