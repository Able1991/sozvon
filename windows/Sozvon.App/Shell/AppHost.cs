using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Sozvon.App.Calls;
using Sozvon.App.Capsule;
using Sozvon.App.Recording;
using Sozvon.App.Settings;
using Sozvon.App.Strings;
using Sozvon.App.Tray;

namespace Sozvon.App.Shell;

/// <summary>Owns the app's lifetime: one process, its settings, the tray icon and the main window.</summary>
public sealed class AppHost
{
    private const string InstanceKey = "sozvon-main";
    private static AppHost? _current;

    private readonly SettingsStore _store = new(AppPaths.SettingsFile);
    private readonly EngineSettings _engineSettings;
    private readonly CallRepository _repository = new(AppPaths.CallsDir, AppPaths.DataDir);
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();
    private readonly AppLanguage _startupLanguage;
    private readonly TrayViewModel _trayState;
    private readonly TrayController _tray;
    private MainWindow? _window;
    private CallsViewModel? _calls;
    private CapsuleWindow? _capsule;
    private RecordingController? _recording;

    /// <summary>The running host; null only before <see cref="Start"/> and in the setup process.</summary>
    public static AppHost? Current => _current;

    public RecordingController? Recording => _recording;

    public AppSettings Settings => _store.Settings;

    public EngineSettings EngineSettings => _engineSettings;

    private AppHost()
    {
        _engineSettings = new EngineSettings(_store.Settings, AppPaths.EnvFile);
        _startupLanguage = _store.Settings.Language;
        Loc.Initialize(ResolvesToRussian(_startupLanguage));
        _store.Settings.PropertyChanged += OnSettingChanged;
        _trayState = new TrayViewModel(_repository, _store.Settings);
        _tray = new TrayController(this, _trayState);
        _tray.Start();
    }

    /// <summary>Starts the shell, or hands over to the running Sozvon and ends this process.</summary>
    public static void Start()
    {
        var instance = AppInstance.FindOrRegisterForKey(InstanceKey);
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
        recording.StateChanged += (_, _) => _tray.Refresh();
        recording.RemindToSay = () => _store.Settings.RemindToSay;
        recording.PanelVisible = () => _store.Settings.FloatingPanel;
        recording.SetupNeeded += (_, _) => OpenSetup();
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
        ApplyCapsuleTheme();
        ApplyFloatingPanel();
        _tray.Refresh();
    }

    /// <summary>The capsule alone, for the demo states: it follows the theme but drives nothing.</summary>
    public void AttachDemo(CapsuleWindow capsule)
    {
        _capsule = capsule;
        ApplyCapsuleTheme();
    }

    public void SetFloatingPanel(bool visible) => _store.Settings.FloatingPanel = visible;

    /// <summary>The wizard runs as its own process, so the tray and the capsule stay as they are meanwhile.</summary>
    public void OpenSetup()
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Environment.ProcessPath!, "--setup") { UseShellExecute = false });
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
        _tray.Dispose();
        _window?.CloseForExit();
        Application.Current.Exit();
    }

    public void Relaunch()
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
        _calls = new CallsViewModel(_repository, _store.Settings);
        var settings = new SettingsViewModel(_store, _engineSettings, _startupLanguage, Relaunch);
        return new MainWindow(_calls, settings);
    }

    private void OnSettingChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppSettings.Theme))
        {
            _window?.ApplyTheme(_store.Settings.Theme);
            ApplyCapsuleTheme();
        }
        else if (e.PropertyName == nameof(AppSettings.FloatingPanel))
        {
            ApplyFloatingPanel();
            _tray.Refresh();
        }
    }

    private void ApplyCapsuleTheme() => _capsule?.ApplyTheme(_store.Settings.Theme switch
    {
        AppTheme.Light => ElementTheme.Light,
        AppTheme.Dark => ElementTheme.Dark,
        _ => ElementTheme.Default,
    });

    private void ApplyFloatingPanel()
    {
        if (_store.Settings.FloatingPanel)
        {
            _capsule?.ShowWithoutFocus();
        }
        else
        {
            _capsule?.AppWindow.Hide();
        }
    }

    private static bool ResolvesToRussian(AppLanguage language) => language switch
    {
        AppLanguage.Russian => true,
        AppLanguage.English => false,
        _ => CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru",
    };
}
