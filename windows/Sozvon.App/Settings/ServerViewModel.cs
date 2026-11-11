using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Dispatching;
using Sozvon.App.Strings;
using Sozvon.Core.Server;
using Sozvon.Core.Settings;
using Windows.ApplicationModel.DataTransfer;

namespace Sozvon.App.Settings;

/// <summary>
/// The Cloud tab: the user's own server with copies of finished calls, as on the Mac. The address and password are typed
/// in "Own address" and reach .env only on Enter or Save, never per keystroke; saving checks the server once, then syncs.
/// The one-click Cloudflare setup is the Mac's for now.
/// </summary>
public sealed partial class ServerViewModel : ObservableObject
{
    private readonly ServerSync _sync;
    private readonly string _envFile;
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private SettingsValues _saved;

    public ServerViewModel(ServerSync sync, string envFile)
    {
        _sync = sync;
        _envFile = envFile;
        _saved = Load();
        UrlDraft = _saved.ServerUrl;
        PasswordDraft = _saved.ServerPassword;
        _sync.Changed += () => _ui.TryEnqueue(Refresh);
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanSave))]
    public partial string UrlDraft { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanSave))]
    public partial string PasswordDraft { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PasswordShown))]
    public partial bool ShowPassword { get; set; }

    public bool CanSave => UrlDraft != _saved.ServerUrl || PasswordDraft != _saved.ServerPassword;

    public bool HasServer => OwnServer.IsConfigured(_saved.ServerUrl, _saved.ServerPassword);

    /// <summary>What is sent can be chosen once a server is set up.</summary>
    public bool NotReady => !HasServer;

    public bool IsRunning => _sync.IsRunning;

    public bool CanSync => HasServer && !_sync.IsRunning;

    public bool Failed => _sync.Failed;

    public bool Fine => !_sync.Failed;

    public string Status => Describe(_sync.Status);

    /// <summary>Under the Sync row; a failure shows in its own warning instead.</summary>
    public string StatusWhenFine => _sync.Failed ? "" : Status;

    public bool HasConnector => _sync.ConnectorUrl is not null;

    public string ConnectorUrl => _sync.ConnectorUrl ?? "";

    public string PasswordShown => ShowPassword ? _saved.ServerPassword : new string('•', 12);

    public bool SyncAudio
    {
        get => _saved.SyncAudio;
        set => SaveToggles(value, _saved.SyncVoices);
    }

    public bool SyncVoices
    {
        get => _saved.SyncVoices;
        set => SaveToggles(_saved.SyncAudio, value);
    }

    /// <summary>A failure to write .env, shown at the top of the tab; empty otherwise.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSaveError))]
    public partial string SaveError { get; private set; } = "";

    public bool HasSaveError => SaveError.Length > 0;

    public Uri DocsUrl => OwnServer.Docs(Loc.IsRussian);

    /// <summary>Enter or Save: spaces and line breaks around a pasted address or password are dropped, then one check.</summary>
    public void Save()
    {
        UrlDraft = UrlDraft.Trim();
        PasswordDraft = PasswordDraft.Trim();
        if (!CanSave)
        {
            return;
        }
        if (!Write(UrlDraft, PasswordDraft, _saved.SyncAudio, _saved.SyncVoices))
        {
            return;
        }
        Refresh();
        _ = _sync.SettingsChangedAsync();
    }

    public void SyncNow() => _ = _sync.CheckAndSyncAsync();

    /// <summary>The tab opened: the saved server is checked once, for the connector address.</summary>
    public void Appeared() => _ = _sync.RefreshAsync();

    public static void Copy(string text)
    {
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
    }

    public void CopyPassword() => Copy(_saved.ServerPassword);

    private void SaveToggles(bool audio, bool voices)
    {
        var turnedOn = (audio && !_saved.SyncAudio) || (voices && !_saved.SyncVoices);
        if (Write(_saved.ServerUrl, _saved.ServerPassword, audio, voices) && turnedOn)
        {
            _ = _sync.SyncAsync();
        }
        Refresh();
    }

    private bool Write(string url, string password, bool audio, bool voices)
    {
        try
        {
            SettingsValues.SaveServer(_envFile, url, password, audio, voices);
            SaveError = "";
            _saved = Load();
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            SaveError = e.Message;
            return false;
        }
    }

    private SettingsValues Load() => SettingsValues.Load(_envFile, detect: () => Assistant.None);

    private void Refresh()
    {
        foreach (var name in new[] { nameof(CanSave), nameof(HasServer), nameof(NotReady), nameof(IsRunning), nameof(CanSync), nameof(Failed), nameof(Fine),
                     nameof(Status), nameof(StatusWhenFine), nameof(HasConnector), nameof(ConnectorUrl), nameof(PasswordShown), nameof(SyncAudio), nameof(SyncVoices) })
        {
            OnPropertyChanged(name);
        }
    }

    private string Describe(SyncStatus status) => status switch
    {
        SyncStatus.BadAddress => Loc.L("Адрес должен начинаться с https://"),
        SyncStatus.NoPassword => Loc.L("Укажи пароль сервера"),
        SyncStatus.Checking => Loc.L("Проверяю сервер…"),
        SyncStatus.WrongPassword => Loc.L("Сервер не принял пароль"),
        SyncStatus.Unhealthy { Health: var health } => health switch
        {
            ServerHealth.Status { Code: var code } => Loc.L("Сервер ответил кодом %@", code),
            ServerHealth.Incompatible => Loc.L("Несовместимая версия сервера, обнови его"),
            ServerHealth.Unreachable { Message: var message } => Loc.L("Сервер недоступен: %@", message),
            _ => Loc.L("Это не сервер Sozvon: проверь адрес"),
        },
        SyncStatus.Online { Version: var version } => version.Length == 0 ? Loc.L("Сервер на связи") : Loc.L("Сервер на связи, версия %@", version),
        SyncStatus.Progress { Text: var text } => text,
        SyncStatus.Done { Result: var r, At: var at } => Summary(r, at),
        SyncStatus.Failed { Message: var message } => message,
        SyncStatus.Crashed { ExitCode: var code, LastLine: var last } => last.Length > 0 ? last : Loc.L("Код завершения %@", code),
        _ => HasServer ? Loc.L("Настроен") : Loc.L("Не настроена"),
    };

    /// <summary>"Синхронизировано 10:42: скачано 12 звонков, отправлено 3", as on the Mac.</summary>
    private static string Summary(SyncResult.Ok r, DateTimeOffset at)
    {
        var parts = new List<string>();
        if (r.Downloaded > 0)
        {
            parts.Add(Loc.L("скачано %@", CallsCount(r.Downloaded)));
        }
        parts.Add(Loc.L("отправлено %@", r.Sent));
        if (r.Deleted > 0)
        {
            parts.Add(Loc.L("удалено %@", r.Deleted));
        }
        if (r.Trashed > 0)
        {
            parts.Add(Loc.L("убрано в Корзину %@", CallsCount(r.Trashed)));
        }
        var text = Loc.L("Синхронизировано %@", at.ToLocalTime().ToString("t", Loc.Culture)) + ": " + string.Join(", ", parts);
        return r.Failed > 0 ? text + ". " + Loc.L("Не отправились: %@", CallsCount(r.Failed)) : text;
    }

    /// <summary>"1 звонок", "3 звонка", "12 звонков"; "1 call", "12 calls". The plural forms are chosen here, not by a key.</summary>
    internal static string CallsCount(int n)
    {
        if (!Loc.IsRussian)
        {
            return n == 1 ? "1 call" : $"{n} calls";
        }
        var (tens, ones) = (n % 100, n % 10);
        var word = tens is >= 11 and <= 14 ? "звонков" : ones == 1 ? "звонок" : ones is >= 2 and <= 4 ? "звонка" : "звонков";
        return $"{n} {word}";
    }
}
