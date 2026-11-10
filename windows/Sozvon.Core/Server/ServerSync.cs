using Sozvon.Core.Engine;

namespace Sozvon.Core.Server;

/// <summary>The address and password of the own server, as saved.</summary>
public sealed record ServerConfig(string Url, string Password)
{
    public bool IsConfigured => OwnServer.IsConfigured(Url, Password);
}

/// <summary>What the Cloud tab says about the own server; the app puts it into words.</summary>
public abstract record SyncStatus
{
    public sealed record None : SyncStatus;

    public sealed record BadAddress : SyncStatus;

    public sealed record NoPassword : SyncStatus;

    public sealed record Checking : SyncStatus;

    public sealed record WrongPassword : SyncStatus;

    public sealed record Unhealthy(ServerHealth Health) : SyncStatus;

    public sealed record Online(string Version) : SyncStatus;

    /// <summary>A <c>STATUS:</c> line of the running sync, in the engine's words.</summary>
    public sealed record Progress(string Text) : SyncStatus;

    public sealed record Done(SyncResult.Ok Result, DateTimeOffset At) : SyncStatus;

    public sealed record Failed(string Message) : SyncStatus;

    /// <summary>The sync ended without a RESULT line: its exit code, or its last line.</summary>
    public sealed record Crashed(int ExitCode, string LastLine) : SyncStatus;
}

/// <summary>
/// Copies of finished calls on the own server, as on the Mac: <c>bin/sync_server.py</c> in the background, one run at a
/// time (asked again while running: one more run after it), and a one-line status. A typed address and password are
/// checked once (health, then the password) before the first sync, so a wrong password never starts one.
/// </summary>
public sealed class ServerSync(
    Func<ServerConfig> config,
    Func<string, Task<ServerHealth>> health,
    Func<string, string, Task<bool>> accepts,
    Func<Action<string>, Task<(int ExitCode, SyncResult? Result, string LastLine)>> run)
{
    private readonly object _gate = new();
    private bool _again;
    private ServerConfig? _checked;
    private int _generation;

    /// <summary>Any property changed. Raised on whatever thread the change happened on.</summary>
    public event Action? Changed;

    public bool IsRunning { get; private set; }

    public SyncStatus Status { get; private set; } = new SyncStatus.None();

    public bool Failed => Status is SyncStatus.BadAddress or SyncStatus.NoPassword or SyncStatus.WrongPassword or SyncStatus.Unhealthy
        or SyncStatus.Failed or SyncStatus.Crashed || Status is SyncStatus.Done { Result.Failed: > 0 };

    /// <summary>The MCP address for a Claude or ChatGPT connector: set once the server answered like ours.</summary>
    public string? ConnectorUrl { get; private set; }

    public string? ServerVersion { get; private set; }

    /// <summary>
    /// The address or password was saved by hand (never per keystroke: every wrong password counts towards the server's
    /// lockout). One health check, one password check, then a sync.
    /// </summary>
    public Task SettingsChangedAsync()
    {
        var saved = config();
        if (_checked == saved) return Task.CompletedTask;
        var generation = Interlocked.Increment(ref _generation);
        (ConnectorUrl, ServerVersion, _checked) = (null, null, null);
        if (OwnServer.Normalize(saved.Url) is not { } url)
        {
            Set(saved.Url.Trim().Length == 0 ? new SyncStatus.None() : new SyncStatus.BadAddress());
            return Task.CompletedTask;
        }
        if (saved.Password.Trim().Length == 0)
        {
            Set(new SyncStatus.NoPassword());
            return Task.CompletedTask;
        }
        return CheckAndSyncAsync(url, verifyPassword: true, generation);
    }

    /// <summary>"Sync": the server answers like ours, then a full sync.</summary>
    public Task CheckAndSyncAsync() =>
        OwnServer.Normalize(config().Url) is { } url ? CheckAndSyncAsync(url, verifyPassword: false, Interlocked.Increment(ref _generation)) : Task.CompletedTask;

    /// <summary>The Cloud tab opened: the saved server is checked once, to show the connector address; no sync.</summary>
    public async Task RefreshAsync()
    {
        var saved = config();
        if (_checked == saved || !saved.IsConfigured || OwnServer.Normalize(saved.Url) is not { } url) return;
        switch (await health(url))
        {
            case ServerHealth.Ok ok:
                (ConnectorUrl, ServerVersion, _checked) = (OwnServer.ConnectorUrl(url), ok.Version, saved);
                Changed?.Invoke();
                break;
            case var bad when Status is SyncStatus.None:
                Set(new SyncStatus.Unhealthy(bad));
                break;
        }
    }

    /// <summary>A full sync in the background, after a transcription, a deletion or a settings change.</summary>
    public async Task SyncAsync()
    {
        if (!config().IsConfigured) return;
        lock (_gate)
        {
            if (IsRunning)
            {
                _again = true;
                return;
            }
            IsRunning = true;
        }
        Changed?.Invoke();
        while (true)
        {
            var (code, result, last) = await run(line =>
            {
                if (line.StartsWith("STATUS: ", StringComparison.Ordinal)) Set(new SyncStatus.Progress(line["STATUS: ".Length..]));
            });
            Set(result switch
            {
                SyncResult.Ok ok => new SyncStatus.Done(ok, DateTimeOffset.Now),
                SyncResult.Error error => new SyncStatus.Failed(error.Message),
                _ => new SyncStatus.Crashed(code, last),
            });
            lock (_gate)
            {
                if (!_again)
                {
                    IsRunning = false;
                    break;
                }
                _again = false;
            }
        }
        Changed?.Invoke();
    }

    private async Task CheckAndSyncAsync(string url, bool verifyPassword, int generation)
    {
        Set(new SyncStatus.Checking());
        var answer = await health(url);
        if (generation != _generation) return;
        if (answer is not ServerHealth.Ok ok)
        {
            (ConnectorUrl, ServerVersion, _checked) = (null, null, null);
            Set(new SyncStatus.Unhealthy(answer));
            return;
        }
        var saved = config();
        if (verifyPassword && !await accepts(url, saved.Password.Trim()))
        {
            if (generation != _generation) return;
            (ConnectorUrl, ServerVersion, _checked) = (null, null, null);
            Set(new SyncStatus.WrongPassword());
            return;
        }
        if (generation != _generation) return;
        (ConnectorUrl, ServerVersion, _checked) = (OwnServer.ConnectorUrl(url), ok.Version, saved);
        Set(new SyncStatus.Online(ok.Version));
        await SyncAsync();
    }

    private void Set(SyncStatus status)
    {
        Status = status;
        Changed?.Invoke();
    }
}

/// <summary>Runs the engine's <c>bin/sync_server.py</c> with the contract's environment; its log is <c>server-sync.log</c>.</summary>
public static class ServerSyncScript
{
    public static async Task<(int ExitCode, SyncResult? Result, string LastLine)> RunAsync(EngineLayout layout, EngineOptions options, Action<string> onLine)
    {
        if (!layout.IsInstalled) return (-1, null, $"the engine is not installed: {layout.Python}");
        SyncResult? result = null;
        var last = "";
        var request = new EngineRunRequest(layout.Python, [layout.Script(OwnServer.SyncScript)], EngineEnvironment.Build(layout, options),
            layout.Data, Path.Combine(layout.Data, OwnServer.SyncLog));
        try
        {
            var process = EngineProcess.Start(request, line =>
            {
                if (OwnServer.ParseSyncResult(line) is { } parsed) result = parsed;
                if (line.Trim().Length > 0) last = line.Trim();
                onLine(line);
            });
            var code = await process.Completion;
            return (code, result, last);
        }
        catch (EngineStartException e)
        {
            return (-1, null, e.Message);
        }
    }
}
