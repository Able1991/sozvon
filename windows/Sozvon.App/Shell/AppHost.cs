using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Sozvon.App.Calls;
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
    private readonly CallRepository _repository = new(AppPaths.CallsDir, AppPaths.DataDir);
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();
    private readonly AppLanguage _startupLanguage;
    private readonly TrayViewModel _trayState;
    private readonly TrayController _tray;
    private MainWindow? _window;
    private CallsViewModel? _calls;

    private AppHost()
    {
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

    public void Exit()
    {
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

    private static void Log(Exception error)
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
        var settings = new SettingsViewModel(_store, _startupLanguage, Relaunch);
        return new MainWindow(_calls, settings);
    }

    private void OnSettingChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppSettings.Theme))
        {
            _window?.ApplyTheme(_store.Settings.Theme);
        }
    }

    private static bool ResolvesToRussian(AppLanguage language) => language switch
    {
        AppLanguage.Russian => true,
        AppLanguage.English => false,
        _ => CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru",
    };
}
