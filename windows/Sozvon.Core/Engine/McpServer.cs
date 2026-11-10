using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using Sozvon.Core.Assistants;

namespace Sozvon.Core.Engine;

/// <summary>
/// The shared MCP server, as on the Mac: one <c>server.py --http</c> on 127.0.0.1, a child of Sozvon in its own Job, so it
/// ends with the app however the app ends. A crash or a taken port: a few quick restarts, then one a minute, since the
/// assistants need it for as long as the app runs.
/// </summary>
public sealed class McpServer(EngineLayout layout, Func<EngineOptions> options, McpEndpoint endpoint)
{
    public const string Script = "server.py";
    public const int QuickRestarts = 5;

    private readonly object _gate = new();
    private EngineProcess? _process;
    private int _restarts;
    private int _generation;
    private bool _stopped = true;

    /// <summary>Delays between restarts; tests make them short.</summary>
    public TimeSpan QuickDelay { get; init; } = TimeSpan.FromSeconds(5);
    public TimeSpan SlowDelay { get; init; } = TimeSpan.FromSeconds(60);

    public McpEndpoint Endpoint => endpoint;

    /// <summary>Started, ended or failed: Settings shows it. Raised on a background thread.</summary>
    public event Action? Changed;

    /// <summary>Why the server is not running, in the words of the log: an exit code or a start failure; null when fine.</summary>
    public (int? ExitCode, string Message)? LastFailure { get; private set; }

    public int? ProcessId
    {
        get
        {
            lock (_gate) return _process?.ProcessId;
        }
    }

    public string LogPath => Path.Combine(layout.Data, Mcp.LogFile);

    public void Start()
    {
        lock (_gate) _stopped = false;
        Launch();
    }

    /// <summary>After an engine update: the new server.py.</summary>
    public async Task RestartAsync()
    {
        Stop();
        await Task.Delay(TimeSpan.FromSeconds(1));
        lock (_gate) _restarts = 0;
        LastFailure = null;
        Start();
    }

    public void Stop()
    {
        EngineProcess? process;
        lock (_gate)
        {
            _stopped = true;
            _generation++;
            process = _process;
            _process = null;
        }
        process?.Terminate();
        Changed?.Invoke();
    }

    private void Launch()
    {
        int generation;
        lock (_gate)
        {
            if (_process is not null || _stopped) return;
            if (!layout.IsInstalled || !File.Exists(Path.Combine(layout.Data, Script))) return;
            generation = ++_generation;
        }
        var environment = EngineEnvironment.Build(layout, options() with { McpPort = endpoint.Port, McpToken = endpoint.Token });
        var request = new EngineRunRequest(layout.Python, [Path.Combine(layout.Data, Script), "--http"], environment, layout.Data, LogPath, AppendLog: true);
        try
        {
            File.AppendAllText(LogPath, $"\n=== {DateTimeOffset.Now:O} {Script} --http\n", new UTF8Encoding(false));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // The server can run without its log header.
        }
        try
        {
            var process = EngineProcess.Start(request);
            lock (_gate)
            {
                if (generation != _generation)
                {
                    process.Terminate();
                    return;
                }
                _process = process;
            }
            _ = WatchAsync(process, generation);
        }
        catch (EngineStartException e)
        {
            LastFailure = (null, e.Message);
            Retry(generation);
        }
        Changed?.Invoke();
    }

    private async Task WatchAsync(EngineProcess process, int generation)
    {
        var code = await process.Completion;
        lock (_gate)
        {
            if (generation != _generation) return;
            _process = null;
            if (_stopped) return;
        }
        LastFailure = (code, "");
        Changed?.Invoke();
        Retry(generation);
    }

    private async void Retry(int generation)
    {
        TimeSpan delay;
        lock (_gate)
        {
            _restarts++;
            delay = _restarts <= QuickRestarts ? QuickDelay : SlowDelay;
        }
        await Task.Delay(delay);
        lock (_gate)
        {
            if (generation != _generation) return;
        }
        Launch();
    }
}

public enum McpHealthState { Listening, NotListening, Unauthorized, Unexpected, Error }

/// <summary>What an authenticated request to the shared server got.</summary>
public sealed record McpHealth(McpHealthState State, int? StatusCode = null, string Message = "")
{
    private const string Initialize =
        """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"sozvon-health","version":"1"}}}""";

    public static McpHealth Classify(HttpStatusCode status) => (int)status switch
    {
        >= 200 and < 300 => new McpHealth(McpHealthState.Listening, (int)status),
        401 or 403 => new McpHealth(McpHealthState.Unauthorized, (int)status),
        _ => new McpHealth(McpHealthState.Unexpected, (int)status),
    };

    /// <summary>An MCP initialize POST to 127.0.0.1, with the password, no proxy and a 3 s limit.</summary>
    public static async Task<McpHealth> ProbeAsync(McpEndpoint endpoint, CancellationToken cancellationToken = default)
    {
        using var handler = new SocketsHttpHandler { UseProxy = false, ConnectTimeout = TimeSpan.FromSeconds(3) };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(3) };
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint.Url) { Content = new StringContent(Initialize, Encoding.UTF8, "application/json") };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", endpoint.Token);
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.Accept.ParseAdd("text/event-stream");
        try
        {
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            return Classify(response.StatusCode);
        }
        catch (HttpRequestException e) when (e.InnerException is SocketException or null)
        {
            return new McpHealth(McpHealthState.NotListening);
        }
        catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new McpHealth(McpHealthState.NotListening);
        }
        catch (HttpRequestException e)
        {
            return new McpHealth(McpHealthState.Error, Message: e.Message);
        }
    }
}
