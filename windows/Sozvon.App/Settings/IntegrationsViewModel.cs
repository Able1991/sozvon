using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Dispatching;
using Sozvon.App.Strings;
using Sozvon.Core.Assistants;
using Sozvon.Core.Engine;
using Sozvon.Core.Settings;
using Windows.ApplicationModel.DataTransfer;

namespace Sozvon.App.Settings;

/// <summary>One assistant in "Connections": whether it is installed, how Sozvon is registered in it, what its button does.</summary>
public sealed partial class AssistantRow(Assistant assistant, string shortCommand) : ObservableObject
{
    public Assistant Assistant { get; } = assistant;

    public string Title { get; } = AssistantCli.Title(assistant);

    /// <summary>The short form of the command, shown under the Copy button's row; the copy also carries the password.</summary>
    public string ShortCommand { get; } = shortCommand;

    [ObservableProperty] public partial bool Installed { get; set; }

    /// <summary>Null until the first check has finished.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Status), nameof(StatusVisible), nameof(Outdated), nameof(IsConnected), nameof(ActionText), nameof(ActionVisible), nameof(Checking))]
    public partial McpConnection? Connection { get; set; }

    [ObservableProperty] public partial string CopyText { get; set; } = Loc.L("Скопировать");

    /// <summary>No other action is running.</summary>
    [ObservableProperty] public partial bool Enabled { get; set; } = true;

    public bool IsConnected => Connection == McpConnection.Connected;

    public bool Checking => Installed && Connection is null;

    public string Status => !Installed ? Loc.L("Не установлен") : Connection switch
    {
        McpConnection.Connected => Loc.L("Подключён"),
        McpConnection.Outdated => Loc.L("Старая настройка"),
        _ => "",
    };

    public bool StatusVisible => Status.Length > 0;

    public bool Outdated => Connection == McpConnection.Outdated;

    public string ActionText => Connection switch
    {
        McpConnection.Connected => Loc.L("Отключить…"),
        McpConnection.Outdated => Loc.L("Подключить заново"),
        _ => Loc.L("Подключить"),
    };

    public bool ActionVisible => Installed && Connection is not null;

    partial void OnInstalledChanged(bool value)
    {
        OnPropertyChanged(nameof(Status));
        OnPropertyChanged(nameof(StatusVisible));
        OnPropertyChanged(nameof(ActionVisible));
        OnPropertyChanged(nameof(Checking));
    }
}

/// <summary>
/// Settings, "Assistants": Claude Code, Codex and Cursor get Sozvon's shared MCP server, as on the Mac. The tools run off the
/// UI thread; after every action all three are checked again. Codex and Cursor change only when their own button is pressed.
/// </summary>
public sealed partial class IntegrationsViewModel : ObservableObject
{
    private readonly McpConnections _connections;
    private readonly McpServer? _server;
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();

    public IntegrationsViewModel(McpServer? server, AssistantHome home, McpEndpoint endpoint)
    {
        _server = server;
        Endpoint = endpoint;
        _connections = new McpConnections(endpoint, home, new ProcessCliRunner(home));
        Rows = McpConnections.All.Select(a => new AssistantRow(a, McpConnections.ShortCommand(a, endpoint.Url))).ToList();
        if (server is not null)
        {
            server.Changed += () => _ui.TryEnqueue(() => _ = RefreshServerAsync());
        }
    }

    public McpEndpoint Endpoint { get; }

    public IReadOnlyList<AssistantRow> Rows { get; }

    public AssistantRow Claude => Rows[0];

    public AssistantRow Codex => Rows[1];

    public AssistantRow Cursor => Rows[2];

    [ObservableProperty] public partial bool Busy { get; private set; }

    /// <summary>What the last connect or disconnect said when it failed; empty otherwise.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasMessage))]
    public partial string Message { get; private set; } = "";

    public bool HasMessage => Message.Length > 0;

    /// <summary>"127.0.0.1:47816 · работает", for the engine section.</summary>
    [ObservableProperty] public partial string ServerStatus { get; private set; } = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasServerFailure))]
    public partial string ServerFailure { get; private set; } = "";

    public bool HasServerFailure => ServerFailure.Length > 0;

    /// <summary>Asked before disconnecting: title, text, the button that does it. Set by the page.</summary>
    public Func<string, string, string, Task<bool>>? Confirm { get; set; }

    /// <summary>The page opened: what is installed and how Sozvon is registered in each.</summary>
    public Task RefreshAsync() => PerformAsync(() => null);

    public async Task ActAsync(AssistantRow row)
    {
        if (Busy || row.Connection is not { } connection)
        {
            return;
        }
        if (connection == McpConnection.Connected)
        {
            if (Confirm is not null && !await Confirm(Loc.L("Отключить Sozvon от %@?", row.Title),
                    Loc.L("Ассистент перестанет видеть звонки. Подключить снова можно в любой момент."), Loc.L("Отключить")))
            {
                return;
            }
            await PerformAsync(() => _connections.Disconnect(row.Assistant));
        }
        else
        {
            await PerformAsync(() => _connections.Connect(row.Assistant));
        }
    }

    /// <summary>What Connect does, with the password, to paste into PowerShell or the file by hand.</summary>
    public async void Copy(AssistantRow row)
    {
        var package = new DataPackage();
        package.SetText(_connections.ManualSetup(row.Assistant));
        Clipboard.SetContent(package);
        row.CopyText = Loc.L("Скопировано");
        await Task.Delay(TimeSpan.FromSeconds(1.5));
        row.CopyText = Loc.L("Скопировать");
    }

    public async Task RefreshServerAsync()
    {
        var address = $"127.0.0.1:{Endpoint.Port}";
        if (_server is null)
        {
            ServerStatus = address;
            return;
        }
        var health = await McpHealth.ProbeAsync(Endpoint);
        ServerStatus = address + " · " + health.State switch
        {
            McpHealthState.Listening => Loc.L("работает"),
            McpHealthState.Unauthorized => Loc.L("не принял пароль"),
            McpHealthState.Unexpected => Loc.L("ответил кодом %@", health.StatusCode ?? 0),
            McpHealthState.Error => health.Message,
            _ => Loc.L("не отвечает"),
        };
        ServerFailure = health.State == McpHealthState.Listening ? "" : _server.LastFailure switch
        {
            { ExitCode: { } code } => Loc.L("MCP-сервер завершился с кодом %@, подробности в mcp.log", code),
            { } => Loc.L("MCP-сервер не запустился, подробности в mcp.log"),
            null => "",
        };
    }

    private async Task PerformAsync(Func<McpResult?> action)
    {
        Busy = true;
        foreach (var row in Rows)
        {
            row.Enabled = false;
            row.Installed = _connections.IsInstalled(row.Assistant);
        }
        var (result, state) = await Task.Run(() =>
        {
            var outcome = action();
            return (outcome, Rows.ToDictionary(r => r.Assistant, r => _connections.Connection(r.Assistant)));
        });
        Message = result is { Failure: { } failure } ? Describe(failure, result.Output) : "";
        foreach (var row in Rows)
        {
            row.Installed = _connections.IsInstalled(row.Assistant);
            row.Connection = state[row.Assistant];
            row.Enabled = true;
        }
        Busy = false;
    }

    private string Describe(McpFailure failure, string output) => failure switch
    {
        McpFailure.NotInstalled => Loc.L("Программа ассистента не найдена"),
        McpFailure.CannotParse => Loc.L("Не получилось разобрать %@. Добавь Sozvon вручную: кнопка «Скопировать» ниже.", _connections.CursorConfig),
        _ => output.Length > 0 ? output : Loc.L("Не получилось"),
    };
}
