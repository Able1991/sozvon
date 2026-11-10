using System.Security.Cryptography;
using System.Text;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Assistants;

/// <summary>How Sozvon is registered in an assistant.</summary>
public enum McpConnection
{
    None,

    /// <summary>Points at the shared server with the password header.</summary>
    Connected,

    /// <summary>Registered, but another way (its own server copy, another port, no password): Connect again fixes it.</summary>
    Outdated,
}

/// <summary>The shared MCP server the assistants connect to: its address and password.</summary>
public sealed record McpEndpoint(int Port, string Token)
{
    public string Url => Mcp.Url(Port);
}

/// <summary>
/// Sozvon as a tool for Claude Code, Codex and Cursor, as on the Mac: one shared engine server on 127.0.0.1 that the app
/// keeps running, and the assistants connect to it with a password.
/// </summary>
public static class Mcp
{
    public const string Name = "sozvon";
    public const int DefaultPort = 47816;
    public const string TokenFile = ".mcp-token";
    public const string LogFile = "mcp.log";

    /// <summary>The port variable of the contract; the app honours it too, so a test run never takes the real port.</summary>
    public const string PortVariable = "SOZVON_MCP_PORT";

    public static string Url(int port) => $"http://127.0.0.1:{port}/mcp";

    /// <summary>The port from <c>SOZVON_MCP_PORT</c> when it is a valid one, else the default.</summary>
    public static int Port(string? fromEnvironment) =>
        int.TryParse(fromEnvironment, out var port) && port is > 0 and < 65536 ? port : DefaultPort;

    /// <summary>
    /// The server password (bearer token): random, made once and kept in <c>.mcp-token</c> of the data folder. Without it
    /// neither a local web page nor another program can reach the server.
    /// </summary>
    public static string Token(string dataDir)
    {
        var file = Path.Combine(dataDir, TokenFile);
        if (SharedFile.ReadText(file)?.Trim() is { Length: >= 32 } saved) return saved;
        var token = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
        Directory.CreateDirectory(dataDir);
        AtomicFile.Write(file, Encoding.ASCII.GetBytes(token));
        return token;
    }

    /// <summary>
    /// Reads <c>&lt;cli&gt; mcp get sozvon</c>: Claude prints <c>URL: …</c> and <c>Headers:</c>, Codex prints <c>url: …</c>
    /// and <c>http_headers: …</c>, <c>-</c> when unset.
    /// </summary>
    public static McpConnection Connection(int exitCode, string output, string url)
    {
        if (exitCode != 0) return McpConnection.None;
        var lines = output.Split('\n').Select(l => l.Trim()).ToList();
        var pointsHere = lines.Any(l => l.StartsWith("url:", StringComparison.OrdinalIgnoreCase) && l.EndsWith(url, StringComparison.Ordinal));
        var codexHeaders = lines.FirstOrDefault(l => l.StartsWith("http_headers:", StringComparison.Ordinal));
        var hasPassword = codexHeaders is not null ? !codexHeaders.EndsWith('-') : output.Contains("Authorization", StringComparison.Ordinal);
        return pointsHere && hasPassword ? McpConnection.Connected : McpConnection.Outdated;
    }

    /// <summary>
    /// Codex cannot set a header in <c>mcp add</c> for HTTP, so it goes into the <c>[mcp_servers.sozvon]</c> section of
    /// config.toml (an old http_headers is replaced). No section: null.
    /// </summary>
    public static string? CodexConfig(string text, string token, string server = Name)
    {
        var header = $"[mcp_servers.{server}]";
        var at = text.IndexOf(header, StringComparison.Ordinal);
        if (at < 0) return null;
        var bodyStart = at + header.Length;
        var next = text.IndexOf("\n[", bodyStart, StringComparison.Ordinal);
        var bodyEnd = next < 0 ? text.Length : next;
        var newline = text.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
        var kept = text[bodyStart..bodyEnd].Split('\n').Where(l => !l.TrimStart().StartsWith("http_headers", StringComparison.Ordinal));
        var line = $"http_headers = {{ \"Authorization\" = \"Bearer {token}\" }}";
        return text[..bodyStart] + newline + line + string.Join('\n', kept) + text[bodyEnd..];
    }
}
