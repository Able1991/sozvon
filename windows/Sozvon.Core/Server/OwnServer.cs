using System.Net;
using System.Net.Http.Headers;
using System.Text.Json.Nodes;
using Sozvon.Core.Engine;

namespace Sozvon.Core.Server;

/// <summary>What <c>GET /api/health</c> said.</summary>
public abstract record ServerHealth
{
    public sealed record Ok(string Version) : ServerHealth;

    /// <summary>It answered with another HTTP status.</summary>
    public sealed record Status(int Code) : ServerHealth;

    /// <summary>It answered, but not like a Sozvon server.</summary>
    public sealed record NotOurs : ServerHealth;

    /// <summary>A Sozvon server of another protocol version.</summary>
    public sealed record Incompatible : ServerHealth;

    /// <summary>No answer: the message of the network error.</summary>
    public sealed record Unreachable(string Message) : ServerHealth;
}

/// <summary>The last line of <c>bin/sync_server.py</c>.</summary>
public abstract record SyncResult
{
    public sealed record Ok(int Sent, int Deleted, int Downloaded, int Trashed, int Failed) : SyncResult;

    public sealed record Error(int? Code, string Message) : SyncResult;
}

/// <summary>
/// The user's own optional server (docs/SERVER.md), as on the Mac: the address rules, the health and password checks, and
/// the result line of the engine's sync. The sync itself is the engine's <c>bin/sync_server.py</c>.
/// </summary>
public static class OwnServer
{
    public const int ProtocolSchema = 1;
    public const string SyncScript = "sync_server.py";
    public const string SyncLog = "server-sync.log";

    public static readonly Uri DocsUrl = new("https://able1991.github.io/sozvon/docs.html#server");

    /// <summary>Opens the "Add custom connector" dialog directly. No other query parameters: they break it.</summary>
    public static readonly Uri ClaudeConnectorsUrl = new("https://claude.ai/customize/connectors?modal=add-custom-connector");

    public static readonly Uri ChatGptConnectorsUrl = new("https://chatgpt.com/#settings/Connectors");

    /// <summary>
    /// https://host[/path] without a trailing slash; http only for localhost and 127.0.0.1 (testing). No credentials, query
    /// or fragment in the address. Anything else: null.
    /// </summary>
    public static string? Normalize(string raw)
    {
        var text = raw.Trim();
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri) || uri.Host.Length == 0) return null;
        if (uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0 || text.Contains('?') || text.Contains('#')) return null;
        var host = uri.Host.ToLowerInvariant();
        var secure = uri.Scheme == Uri.UriSchemeHttps;
        if (!secure && !(uri.Scheme == Uri.UriSchemeHttp && host is "localhost" or "127.0.0.1")) return null;
        var path = uri.AbsolutePath.TrimEnd('/');
        var port = uri.IsDefaultPort ? "" : $":{uri.Port}";
        return $"{uri.Scheme}://{host}{port}{path}";
    }

    /// <summary>Both the address and the password are set and the address is valid.</summary>
    public static bool IsConfigured(string url, string password) => Normalize(url) is not null && password.Trim().Length > 0;

    /// <summary>The MCP address of the server, for a Claude or ChatGPT connector.</summary>
    public static string ConnectorUrl(string server) => server + "/mcp";

    /// <summary>The reply of <c>GET /api/health</c>: <c>{"ok": true, "version": "...", "schema": 1}</c>.</summary>
    public static ServerHealth Health(int status, string body)
    {
        if (status != 200) return new ServerHealth.Status(status);
        JsonObject? json;
        try
        {
            json = JsonNode.Parse(body) as JsonObject;
        }
        catch (System.Text.Json.JsonException)
        {
            json = null;
        }
        if (json?["ok"] is not JsonValue ok || !ok.TryGetValue<bool>(out var yes) || !yes) return new ServerHealth.NotOurs();
        if (json["schema"] is not JsonValue schema || !schema.TryGetValue<int>(out var number) || number != ProtocolSchema) return new ServerHealth.Incompatible();
        return new ServerHealth.Ok(json["version"] is JsonValue v && v.TryGetValue<string>(out var version) ? version : "");
    }

    /// <summary>GET /api/health with a 10 s limit.</summary>
    public static async Task<ServerHealth> CheckHealthAsync(string server, HttpMessageHandler? handler = null, CancellationToken cancellationToken = default)
    {
        using var client = Client(handler);
        try
        {
            using var response = await client.GetAsync(Endpoint(server, "api/health"), cancellationToken);
            return Health((int)response.StatusCode, await response.Content.ReadAsStringAsync(cancellationToken));
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException && !cancellationToken.IsCancellationRequested)
        {
            return new ServerHealth.Unreachable(e is TaskCanceledException ? "timeout" : e.Message);
        }
    }

    /// <summary>The password is right: <c>GET /api/calls</c> answers 200 (a wrong one waits a second on the server).</summary>
    public static async Task<bool> AcceptsAsync(string server, string password, HttpMessageHandler? handler = null, CancellationToken cancellationToken = default)
    {
        using var client = Client(handler);
        using var request = new HttpRequestMessage(HttpMethod.Get, Endpoint(server, "api/calls"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", password);
        try
        {
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            return response.StatusCode == HttpStatusCode.OK;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException && !cancellationToken.IsCancellationRequested)
        {
            return false;
        }
    }

    /// <summary>
    /// <c>RESULT: ok &lt;sent&gt; &lt;deleted&gt; &lt;downloaded&gt; &lt;trashed&gt; &lt;failed&gt;</c> (older engines printed fewer numbers) or
    /// <c>RESULT: error &lt;code&gt; &lt;message&gt;</c>; null for any other line.
    /// </summary>
    public static SyncResult? ParseSyncResult(string line)
    {
        var parts = line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts is ["RESULT:", "ok", ..] && parts.Length is >= 4 and <= 8)
        {
            var numbers = parts.Skip(2).Select(p => int.TryParse(p, out var n) ? n : (int?)null).ToList();
            if (numbers.Any(n => n is null)) return null;
            int At(int i) => i < numbers.Count ? numbers[i]!.Value : 0;
            return new SyncResult.Ok(At(0), At(1), At(2), At(3), At(4));
        }
        return RunOutcome.ParseLine(line) is { Ok: false } error ? new SyncResult.Error(error.Code, error.Message) : null;
    }

    private static HttpClient Client(HttpMessageHandler? handler) =>
        handler is null ? new HttpClient { Timeout = TimeSpan.FromSeconds(10) } : new HttpClient(handler, disposeHandler: false) { Timeout = TimeSpan.FromSeconds(10) };

    private static Uri Endpoint(string server, string path) => new(server + "/" + path);
}
