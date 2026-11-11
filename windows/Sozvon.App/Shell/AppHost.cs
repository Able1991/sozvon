using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Sozvon.App.Calls;
using Sozvon.App.Capsule;
using Sozvon.App.Recording;
using Sozvon.App.Projects;
using Sozvon.App.Settings;
using Sozvon.App.Strings;
using Sozvon.App.Tray;
using Sozvon.App.VoicePrints;
using Sozvon.Core.Assistants;
using Sozvon.Core.Engine;
using Sozvon.Core.Server;
using Sozvon.Core.Settings;

namespace Sozvon.App.Shell;

/// <summary>Owns the app's lifetime: one process, its settings, the tray icon and the main window.</summary>
public sealed class AppHost
{
    private const string InstanceKey = "sozvon-main";
    private static AppHost? _current;

    private readonly SettingsStore _store = new(AppPaths.SettingsFile);
    private readonly EngineSettings _engineSettings;
    private readonly CallRepository _repository = new(() => AppPaths.CallsDir, AppPaths.DataDir);
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();
    private readonly AppLanguage _startupLanguage;
    private readonly TrayViewModel _trayState;
    private readonly TrayController _tray;
    private readonly EngineLayout _layout = AppPaths.Layout;
    private readonly McpServer _mcp;
    private readonly ServerSync _server;
    private MainWindow? _window;
    private CallsViewModel? _calls;
    private CapsuleWindow? _capsule;
    private RecordingController? _recording;
    private AudioCleanup? _cleanup;
    private PhoneInboxWatcher? _phone;
    private int _retention;

    /// <summary>The running host; null only before <see cref="Start"/> and in the setup process.</summary>
    public static AppHost? Current => _current;

    public RecordingController? Recording => _recording;

    public AppSettings Settings => _store.Settings;

    public EngineSettings EngineSettings => _engineSettings;

    /// <summary>Open at sign-in: the Settings row and the tray menu share it.</summary>
    public SignInSetting SignIn { get; } = new(Environment.ProcessPath!);

    /// <summary>"Relaunch Sozvon" after a change of language: at once when idle, otherwise once the recording and the queue are done.</summary>
    public Relauncher Relaunch { get; }

    /// <summary>The calls folder row of Settings: refused while recording or transcribing, applied at once, as on the Mac.</summary>
    public CallsFolderChanger CallsFolder { get; }

    private AppHost()
    {
        Relaunch = new Relauncher(() => _recording?.IsBusy ?? false, RestartNow);
        _engineSettings = new EngineSettings(_store.Settings, AppPaths.EnvFile);
        _startupLanguage = _store.Settings.Language;
        Loc.Initialize(ResolvesToRussian(_startupLanguage));
        _store.Settings.PropertyChanged += OnSettingChanged;
        _trayState = new TrayViewModel(_repository, _store.Settings, _layout);
        _tray = new TrayController(this, _trayState);
        _tray.Start();
        _mcp = new McpServer(_layout, _engineSettings.Options, McpEndpoint());
        CallsFolder = new CallsFolderChanger(AppPaths.SettingsFile, AppPaths.DataDir, AppPaths.DefaultCallsDir, () => AppPaths.CallsDir,
            () => _recording?.IsBusy ?? false, AppPaths.ChangeCallsDir, Loc.L);
        AppPaths.CallsDirChanged += OnCallsDirChanged;
        _server = new ServerSync(SavedServer, url => OwnServer.CheckHealthAsync(url), (url, password) => OwnServer.AcceptsAsync(url, password),
            onLine => ServerSyncScript.RunAsync(_layout, _engineSettings.Options(), onLine));
    }

    /// <summary>Starts the shell, or hands over to the running Sozvon and ends this process.</summary>
    public static void Start()
    {
        var instance = AppInstance.FindOrRegisterForKey(AppPaths.InstanceKey(InstanceKey));
        if (!instance.IsCurrent)
        {
            Task.Run(async () => await instance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs())).Wait();
            Environment.Exit(0);
        }
        Application.Current.UnhandledException += OnUnhandledException;
        Application.Current.DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        _current = new AppHost();
        instance.Activated += (_, _) => _current._dispatcher.TryEnqueue(() => _current.OpenWindow(AppPage.Calls));
    }

    /// <summary>Connects the capsule and the recorder to the tray and to the settings that concern them.</summary>
    public void Attach(CapsuleWindow capsule, RecordingController recording)
    {
        _capsule = capsule;
        _recording = recording;
        _trayState.Recording = recording;
        capsule.HideRequested += (_, _) => _store.Settings.FloatingPanel = false;
        capsule.Rendered += (_, _) => ApplyFloatingPanel();
        recording.StateChanged += (_, _) =>
        {
            _tray.Refresh();
            Relaunch.Poll();
        };
        recording.CallsChanged += (_, _) =>
        {
            _ = _calls?.RefreshAsync();
            Relaunch.Poll();
        };
        // A finished transcription goes to the own server, if one is set up.
        recording.Processor.RunFinished += run => _dispatcher.TryEnqueue(() =>
        {
            if (run.Outcome.IsOk)
            {
                _ = _server.SyncAsync();
            }
        });
        recording.RemindToSay = () => _store.Settings.RemindToSay;
        recording.PanelVisible = () => _store.Settings.FloatingPanel;
        recording.SetupNeeded += (_, _) => OpenSetup();
        // CapsuleX is the capsule's centre: its width changes with what it shows.
        capsule.Moved += (_, position) =>
        {
            _store.Settings.CapsuleX = position.X;
            _store.Settings.CapsuleY = position.Y;
        };
        if (_store.Settings is { CapsuleX: { } x, CapsuleY: { } y })
        {
            capsule.MoveToIfOnScreen(x, y);
        }
        recording.Problem += (_, text) => _tray.Notify(text);
        _cleanup = new AudioCleanup(() => AppPaths.CallsDir, _store.Settings,
            dir => recording.Processor.Contains(dir) || (recording.RecordingDirectory is { } live && CallActions.SameFolder(live, dir)));
        _cleanup.Removed += (_, _) => _ = _calls?.RefreshAsync();
        _retention = _store.Settings.AudioRetention;
        _cleanup.Start();
        _phone = new PhoneInboxWatcher(_store.Settings, _layout, _engineSettings, recording);
        _phone.Problem += (_, text) => _tray.Notify(text);
        _phone.Imported += (_, _) => _ = _calls?.RefreshAsync();
        _phone.Start();
        _mcp.Start();
        ApplyCapsuleTheme();
        ApplyFloatingPanel();
        _tray.Refresh();
    }

    /// <summary>The capsule alone, for the demo states: it follows the theme but drives nothing.</summary>
    public void AttachDemo(CapsuleWindow capsule)
    {
        _capsule = capsule;
        capsule.Rendered += (_, _) => ApplyFloatingPanel();
        ApplyCapsuleTheme();
    }

    public void SetFloatingPanel(bool visible) => _store.Settings.FloatingPanel = visible;

    /// <summary>The wizard runs as its own process, so the tray and the capsule stay as they are meanwhile.</summary>
    public void OpenSetup()
    {
        try
        {
            var setup = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Environment.ProcessPath!, "--setup") { UseShellExecute = false });
            if (setup is not null)
            {
                // A finished install brings the shared MCP server up; an engine update brings the new server.py.
                setup.EnableRaisingEvents = true;
                // The wizard may have chosen another calls folder: the app follows it, which restarts the server too.
                setup.Exited += (_, _) => _dispatcher.TryEnqueue(() =>
                {
                    var chosen = Sozvon.Core.Calls.CallsFolder.Current(AppPaths.SettingsFile, AppPaths.DefaultCallsDir,
                        Environment.GetEnvironmentVariable("SOZVON_CALLS_DIR"));
                    if (Sozvon.Core.Calls.CallsFolder.SamePath(chosen, AppPaths.CallsDir))
                    {
                        _ = _mcp.RestartAsync();
                    }
                    else
                    {
                        AppPaths.ChangeCallsDir(chosen);
                    }
                });
            }
        }
        catch (System.ComponentModel.Win32Exception error)
        {
            Log(error);
        }
    }

    public void OpenWindow(AppPage page)
    {
        try
        {
            _window ??= CreateWindow();
            _window.Show(page);
            _ = _calls!.RefreshAsync();
        }
        catch (Exception error)
        {
            // Dispatcher callbacks do not reach Application.UnhandledException; the tray must survive a window failure.
            Log(error);
        }
    }

    public void OpenCall(string id)
    {
        OpenWindow(AppPage.Calls);
        _calls!.SelectCall(id);
    }

    public async void Exit()
    {
        try
        {
            if (_recording is { } recording)
            {
                await recording.ShutdownAsync();
            }
        }
        catch (Exception error)
        {
            Log(error);
        }
        _mcp.Stop();
        _tray.Dispose();
        _window?.CloseForExit();
        Application.Current.Exit();
    }

    private void RestartNow()
    {
        _tray.Dispose();
        var failure = AppInstance.Restart("");
        Marshal.ThrowExceptionForHR((int)failure);
    }

    private static void OnUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs e) => Log(e.Exception);

    internal static void Log(Exception error)
    {
        try
        {
            Directory.CreateDirectory(AppPaths.DataDir);
            File.AppendAllText(Path.Combine(AppPaths.DataDir, "app-errors.log"), $"{DateTime.Now:O} {error}{Environment.NewLine}");
        }
        catch (IOException)
        {
            // Nothing more can be done about a failing log.
        }
    }

    private MainWindow CreateWindow()
    {
        var voices = new VoiceStore(_layout, _engineSettings.Options);
        var actions = new CallActions(AppPaths.DataDir, _engineSettings, () => _recording, voices);
        // Edits, notes and deletions reach the own server too; a run asked for while one goes is folded into one more.
        actions.Changed += selected => _ = _server.SyncAsync();
        _calls = new CallsViewModel(_repository, _store.Settings, _engineSettings, actions);
        var integrations = new IntegrationsViewModel(_mcp, AssistantHome.FromEnvironment(), _mcp.Endpoint);
        // The demo runs no recorder: its Settings get a shortcut nobody has registered or taken.
        var settings = new SettingsViewModel(_store, _engineSettings, _layout, _startupLanguage, Relaunch, integrations, SignIn,
            new ServerViewModel(_server, AppPaths.EnvFile), _recording?.MarkShortcut ?? new Sozvon.Core.Calls.MarkShortcut())
        {
            CallsFolder = CallsFolder,
        };
        var profiles = Path.Combine(AppPaths.DataDir, "profiles");
        var myVoice = new MyVoice(voices, AppPaths.DataDir, _engineSettings);
        var projects = new ProjectsPage(profiles, _repository, voices, () => _ = _calls.RefreshAsync());
        return new MainWindow(_calls, settings, projects, new VoicesPage(myVoice, profiles), myVoice);
    }

    /// <summary>
    /// Another calls folder, from Settings or the wizard: the list reads it, the MCP server starts again with its
    /// SOZVON_CALLS_DIR, and the next recordings and runs go there (they read <see cref="AppPaths.CallsDir"/> each time).
    /// </summary>
    private void OnCallsDirChanged()
    {
        _ = _mcp.RestartAsync();
        CallsFolder.Refresh();
        _ = _calls?.RefreshAsync();
    }

    private static ServerConfig SavedServer()
    {
        var values = SettingsValues.Load(AppPaths.EnvFile, detect: () => Assistant.None);
        return new ServerConfig(values.ServerUrl, values.ServerPassword);
    }

    /// <summary>The port from SOZVON_MCP_PORT (a test run keeps off the real one) and the password of this data folder.</summary>
    private static McpEndpoint McpEndpoint()
    {
        var port = Mcp.Port(Environment.GetEnvironmentVariable(Mcp.PortVariable));
        try
        {
            return new McpEndpoint(port, Mcp.Token(AppPaths.DataDir));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // An unwritable data folder: a password for this run only; the assistants connect again after the fix.
            Log(error);
            return new McpEndpoint(port, Convert.ToHexStringLower(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32)));
        }
    }

    private void OnSettingChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppSettings.Theme))
        {
            _window?.ApplyTheme(_store.Settings.Theme);
            ApplyCapsuleTheme();
        }
        else if (e.PropertyName == nameof(AppSettings.AudioRetention))
        {
            OnRetentionChanged();
        }
        else if (e.PropertyName == nameof(AppSettings.PlaySounds) && _store.Settings.PlaySounds)
        {
            _ = Chimes.PlayAsync(Chime.Start); // as on the Mac: turning the sounds on lets them be heard
        }
        else if (e.PropertyName is nameof(AppSettings.FloatingPanel) or nameof(AppSettings.CapsuleWhenIdle))
        {
            ApplyFloatingPanel();
            _tray.Refresh();
        }
    }

    /// <summary>A shorter "Delete audio automatically" that removes audio right now asks first, as on the Mac.</summary>
    private async void OnRetentionChanged()
    {
        var choice = _store.Settings.AudioRetention;
        if (choice == _retention || _cleanup is null)
        {
            return;
        }
        try
        {
            var (calls, bytes) = _cleanup.Preview(choice);
            if (calls > 0 && _window is not null)
            {
                var sure = await _window.ConfirmAsync(
                    Loc.L("Удалить аудио %@ звонков?", calls),
                    Loc.L("У звонков старше %@ дн. удалится звук (%@). Расшифровки, итоги и заметки останутся, но плеер и «Расшифровать заново» для них пропадут. Вернуть звук будет нельзя.",
                          Sozvon.Core.Calls.AudioRetention.Days(choice), CallFormat.Size(bytes)),
                    Loc.L("Удалить аудио"));
                if (!sure)
                {
                    _store.Settings.AudioRetention = _retention;
                    return;
                }
            }
            _retention = choice;
            _cleanup.Run();
        }
        catch (Exception error)
        {
            Log(error);
        }
    }

    private void ApplyCapsuleTheme() => _capsule?.ApplyTheme(_store.Settings.Theme switch
    {
        AppTheme.Light => ElementTheme.Light,
        AppTheme.Dark => ElementTheme.Dark,
        _ => ElementTheme.Default,
    });

    /// <summary>The capsule on screen or not, by the Mac's rule, after every state it draws and every change of the settings.</summary>
    private void ApplyFloatingPanel()
    {
        if (_capsule is not { } capsule)
        {
            return;
        }
        var model = capsule.Model;
        var counting = model is { Phase: CapsulePhase.Prompt, AutoStartSeconds: not null } or { Phase: CapsulePhase.Recording, Hint: CapsuleHint.StopCountdown };
        capsule.SetOnScreen(Sozvon.Core.Settings.PanelVisibility.Shows(
            active: model.Phase != CapsulePhase.Idle, counting, _store.Settings.FloatingPanel, _store.Settings.CapsuleWhenIdle));
    }

    private static bool ResolvesToRussian(AppLanguage language) => language switch
    {
        AppLanguage.Russian => true,
        AppLanguage.English => false,
        _ => CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru",
    };
}
