using System.ComponentModel;
using System.IO;
using System.Reflection;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Sozvon.App.Shell;
using Sozvon.App.Strings;
using Sozvon.Core.Automation;
using Sozvon.Core.Settings;

namespace Sozvon.App.Settings;

/// <summary>The Settings page: the persisted values, and what the app can really report about itself.</summary>
public sealed partial class SettingsViewModel : ObservableObject
{
    private readonly SettingsStore _store;
    private readonly EngineSettings _engine;
    private readonly AppLanguage _startupLanguage;

    public SettingsViewModel(SettingsStore store, EngineSettings engine, AppLanguage startupLanguage, Action relaunch, IntegrationsViewModel integrations, SignInSetting signIn,
        ServerViewModel server)
    {
        Server = server;
        Integrations = integrations;
        SignIn = signIn;
        _store = store;
        _engine = engine;
        _startupLanguage = startupLanguage;
        RelaunchCommand = new RelayCommand(relaunch);
        _store.PropertyChanged += OnStoreChanged;
        Settings.PropertyChanged += OnSettingsChanged;
    }

    public AppSettings Settings => _store.Settings;

    public IRelayCommand RelaunchCommand { get; }

    /// <summary>Claude Code, Codex and Cursor connected to the shared MCP server.</summary>
    public IntegrationsViewModel Integrations { get; }

    /// <summary>Open at sign-in, read from Windows each time.</summary>
    public SignInSetting SignIn { get; }

    /// <summary>The own server and its sync (the Cloud tab).</summary>
    public ServerViewModel Server { get; }

    public int ThemeIndex
    {
        get => (int)Settings.Theme switch { 1 => 0, 2 => 1, _ => 2 };
        set => Settings.Theme = value switch { 0 => AppTheme.Light, 1 => AppTheme.Dark, _ => AppTheme.System };
    }

    public int LanguageIndex
    {
        get => (int)Settings.Language;
        set => Settings.Language = (AppLanguage)value;
    }

    public string DisplayName
    {
        get => _engine.Name;
        set
        {
            if (value != _engine.Name)
            {
                Settings.DisplayName = value;
            }
        }
    }

    public int SpeechModelIndex
    {
        get => (int)_engine.Model;
        set
        {
            if (value >= 0 && value != (int)_engine.Model)
            {
                Settings.SpeechModelChoice = (WhisperModel)value;
            }
        }
    }

    public bool LanguageSwitching
    {
        get => _engine.LanguageSwitch;
        set
        {
            if (value != _engine.LanguageSwitch)
            {
                Settings.LanguageSwitchingChoice = value;
            }
        }
    }

    /// <summary>
    /// Claude Code or no summaries: Codex and Cursor are not offered on Windows yet (not tried with the real programs). A
    /// wizard that chose one of them leaves neither button checked.
    /// </summary>
    public int SummaryAssistantIndex
    {
        get => _engine.Assistant switch { Assistant.Claude => 0, Assistant.None => 1, _ => -1 };
        set
        {
            var chosen = value switch { 0 => Assistant.Claude, 1 => Assistant.None, _ => (Assistant?)null };
            if (chosen is { } assistant && assistant != _engine.Assistant)
            {
                Settings.SummaryAssistantChoice = assistant;
            }
        }
    }

    public IReadOnlyList<SpeechLanguage> CallLanguages
    {
        get => _engine.Languages;
        set => Settings.CallLanguagesChoice = SpeechLanguages.Serialize(value);
    }

    public string CallStartDescription => RecordsByItself
        ? Loc.L("Через %@ секунд, на панели можно отменить или начать сразу", CallAutomation.StartCountdown)
        : "Zoom, Google Meet, Telegram";

    public string StopAfterCallDescription => Loc.L("Через %@ секунд после конца звонка, на панели можно продолжить", CallAutomation.StopGrace);

    public string RecordingFooter => RecordsByItself
        ? Loc.L("Запись начинается сама, когда приложение для звонков включает микрофон. Согласие собеседников на запись на тебе.")
        : Loc.L("Запись начинается только по кнопке «Записать». Согласие собеседников на запись на тебе.");

    public bool NeedsRelaunch => Settings.Language != _startupLanguage;

    public string SaveError => _store.SaveError;

    public bool HasSaveError => _store.SaveError.Length > 0;

    public bool EngineInstalled => File.Exists(AppPaths.EnginePython);

    public string CallsFolder => AppPaths.CallsDir;

    public string PhoneFolderText => Settings.PhoneFolder.Length > 0 ? Settings.PhoneFolder : Loc.L("Не выбрана");

    public bool HasPhoneFolder => Settings.PhoneFolder.Length > 0;

    /// <summary>The docs on recording in one tap with the iPhone shortcut, in the interface language.</summary>
    public Uri PhoneShortcutDocs => new($"https://able1991.github.io/sozvon/docs.html#{(Loc.IsRussian ? "" : "en-")}phone-shortcut");

    public string DataFolder => AppPaths.DataDir;

    public string Version => Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "";

    private bool RecordsByItself => CallAutomation.Mode(Settings.CallStartAction) == CallStartMode.Record;

    private void OnStoreChanged(object? sender, PropertyChangedEventArgs e)
    {
        OnPropertyChanged(nameof(SaveError));
        OnPropertyChanged(nameof(HasSaveError));
    }

    private void OnSettingsChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppSettings.Theme))
        {
            OnPropertyChanged(nameof(ThemeIndex));
        }
        else if (e.PropertyName == nameof(AppSettings.Language))
        {
            OnPropertyChanged(nameof(LanguageIndex));
            OnPropertyChanged(nameof(NeedsRelaunch));
        }
        else if (e.PropertyName == nameof(AppSettings.PhoneFolder))
        {
            OnPropertyChanged(nameof(PhoneFolderText));
            OnPropertyChanged(nameof(HasPhoneFolder));
        }
        else if (e.PropertyName == nameof(AppSettings.CallStartAction))
        {
            OnPropertyChanged(nameof(CallStartDescription));
            OnPropertyChanged(nameof(RecordingFooter));
        }
    }
}
