using CommunityToolkit.Mvvm.ComponentModel;

namespace Sozvon.App.Settings;

public enum AppTheme { System, Light, Dark }

public enum AppLanguage { System, Russian, English }

/// <summary>Everything in Settings, one property per row. Theme and Language are applied; the rest are stored for now.</summary>
public sealed partial class AppSettings : ObservableObject
{
    [ObservableProperty] public partial AppTheme Theme { get; set; }
    [ObservableProperty] public partial AppLanguage Language { get; set; }
    [ObservableProperty] public partial string DisplayName { get; set; } = "";

    [ObservableProperty] public partial bool FloatingPanel { get; set; } = true;
    [ObservableProperty] public partial bool PanelWhenIdle { get; set; }
    [ObservableProperty] public partial int CallStartAction { get; set; }
    [ObservableProperty] public partial bool StopAfterCall { get; set; }
    [ObservableProperty] public partial bool RemindToSay { get; set; }
    [ObservableProperty] public partial bool WarnOnSilence { get; set; } = true;
    [ObservableProperty] public partial bool PlaySounds { get; set; } = true;
    [ObservableProperty] public partial bool OpenAtSignIn { get; set; }
    [ObservableProperty] public partial bool TranscribeWhenClear { get; set; } = true;
    [ObservableProperty] public partial int AudioRetention { get; set; }

    [ObservableProperty] public partial int SpeechModel { get; set; }
    [ObservableProperty] public partial int CallLanguages { get; set; }
    [ObservableProperty] public partial bool LanguageSwitching { get; set; }
    [ObservableProperty] public partial bool LowPriority { get; set; } = true;

    [ObservableProperty] public partial int SummaryAssistant { get; set; }
    [ObservableProperty] public partial bool AutoUpdate { get; set; } = true;
}
