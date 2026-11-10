using System.ComponentModel;
using System.IO;
using System.Reflection;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Sozvon.App.Shell;
using Sozvon.App.Strings;
using Sozvon.Core.Automation;
using Sozvon.Core.Calls;
using Sozvon.Core.Settings;

namespace Sozvon.App.Settings;

/// <summary>The Settings page: the persisted values, and what the app can really report about itself.</summary>
public sealed partial class SettingsViewModel : ObservableObject
{
    private readonly SettingsStore _store;
    private readonly EngineSettings _engine;
    private readonly AppLanguage _startupLanguage;
    private readonly MarkShortcut _markShortcut;
    private readonly Relauncher _relaunch;

    public SettingsViewModel(SettingsStore store, EngineSettings engine, AppLanguage startupLanguage, Relauncher relaunch, IntegrationsViewModel integrations, SignInSetting signIn,
        ServerViewModel server, MarkShortcut markShortcut)
    {
        Server = server;
        Integrations = integrations;
        SignIn = signIn;
        _store = store;
        _engine = engine;
        _startupLanguage = startupLanguage;
        _markShortcut = markShortcut;
        _relaunch = relaunch;
        RelaunchCommand = new RelayCommand(relaunch.Request, () => !relaunch.Waiting);
        _store.PropertyChanged += OnStoreChanged;
        Settings.PropertyChanged += OnSettingsChanged;
        markShortcut.Changed += () => OnPropertyChanged(nameof(MarkShortcutTaken));
        relaunch.WaitingChanged += (_, _) =>
        {
            RelaunchCommand.NotifyCanExecuteChanged();
            OnPropertyChanged(nameof(RelaunchButtonText));
        };
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

    /// <summary>The dropdown's index is the assistant (Claude, Codex, Cursor, none), as on the Mac.</summary>
    public int SummaryAssistantIndex
    {
        get => (int)_engine.Assistant;
        set
        {
            if (value >= 0 && value != (int)_engine.Assistant)
            {
                Settings.SummaryAssistantChoice = (Assistant)value;
                OnPropertyChanged(nameof(SummaryFooter));
                OnPropertyChanged(nameof(SummaryWarning));
                OnPropertyChanged(nameof(HasSummaryWarning));
            }
        }
    }

    /// <summary>
    /// Where the text goes, under the dropdown: the Mac's words without project discovery, which is off on Windows,
    /// and "this computer" for "this Mac".
    /// </summary>
    public string SummaryFooter => _engine.Assistant switch
    {
        Assistant.Claude => Loc.L("Саммари. Текст уходит в Anthropic."),
        Assistant.Codex => Loc.L("Саммари. Текст уходит в OpenAI."),
        Assistant.Cursor => Loc.L("Саммари. Текст уходит в Cursor и к выбранной там модели."),
        _ => Loc.L("Без саммари. Ничего не покидает компьютер."),
    };

    /// <summary>
    /// Codex and Cursor run on Windows only when chosen here (the engine picks only Claude by itself) and were not tried
    /// with the real programs; Cursor may also have no file sandbox there (docs/windows-port-checklist.md).
    /// </summary>
    public string SummaryWarning => _engine.Assistant switch
    {
        Assistant.Codex => Loc.L("%@ на Windows ещё не проверен с настоящей программой: песочница, которую обещает производитель, может работать не так, как на Mac. Текст звонка уходит этому ассистенту.", "Codex"),
        Assistant.Cursor => Loc.L("%@ на Windows ещё не проверен с настоящей программой: песочница, которую обещает производитель, может работать не так, как на Mac. Текст звонка уходит этому ассистенту.", "Cursor")
            + "\n" + Loc.L("У Cursor на Windows может не быть файловой песочницы: тогда он сможет читать файлы и за пределами папки звонка."),
        _ => "",
    };

    public bool HasSummaryWarning => SummaryWarning.Length > 0;

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

    /// <summary>The button says what pressing it did: pressed during work, the restart comes when the work ends.</summary>
    public string RelaunchButtonText => _relaunch.Waiting
        ? Loc.L("Перезапустится, когда закончатся запись и расшифровка")
        : Loc.L("Перезапустить Sozvon");

    /// <summary>Another program holds Ctrl+Alt+I: the press marks nothing, and this says why rather than let it fail quietly.</summary>
    public bool MarkShortcutTaken => _markShortcut.Taken;

    public string MarkShortcutWarning =>
        Loc.L("Сочетание %@ занято другой программой. Отметить важное можно кнопкой на панели или в меню значка в трее.", MarkShortcut.Keys);

    public string SaveError => _store.SaveError;

    public bool HasSaveError => _store.SaveError.Length > 0;

    public bool EngineInstalled => File.Exists(AppPaths.EnginePython);

    public string CallsFolder => AppPaths.CallsDir;

    public string PhoneFolderText => Settings.PhoneFolder.Length > 0 ? Settings.PhoneFolder : Loc.L("Не выбрана");

    public bool HasPhoneFolder => Settings.PhoneFolder.Length > 0;

    /// <summary>The docs on recording in one tap with the iPhone shortcut, in the interface language.</summary>
    public Uri PhoneShortcutDocs => new($"https://able1991.github.io/sozvon/docs.html#{(Loc.IsRussian ? "" : "en-")}phone-shortcut");

    public string DataFolder => AppPaths.DataDir;

    /// <summary>
    /// "0.1.4 · сборка Windows, предварительная · de35056": the Mac's version (the latest tag, as build.sh takes it) and the
    /// commit, both written at build time. Windows has no releases yet, so this never reads like one.
    /// </summary>
    public string Version
    {
        get
        {
            var metadata = Assembly.GetExecutingAssembly().GetCustomAttributes<AssemblyMetadataAttribute>().ToDictionary(a => a.Key, a => a.Value ?? "");
            var parts = new[] { metadata.GetValueOrDefault("SozvonVersion", ""), Loc.L("сборка Windows, предварительная"), metadata.GetValueOrDefault("SozvonCommit", "") };
            return string.Join(" · ", parts.Where(p => p.Length > 0));
        }
    }

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
