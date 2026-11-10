using CommunityToolkit.Mvvm.ComponentModel;
using Sozvon.Core.Settings;

namespace Sozvon.App.Settings;

public enum AppTheme { System, Light, Dark }

public enum AppLanguage { System, Russian, English }

/// <summary>
/// Everything in Settings, one property per row. A *Choice property is null until the user changes that row, and then
/// overrides the wizard's .env (<see cref="EngineSettings"/>). Rows marked "not connected" in the page are only stored.
/// </summary>
public sealed partial class AppSettings : ObservableObject
{
    [ObservableProperty] public partial AppTheme Theme { get; set; }
    [ObservableProperty] public partial AppLanguage Language { get; set; }
    [ObservableProperty] public partial string DisplayName { get; set; } = "";

    [ObservableProperty] public partial bool FloatingPanel { get; set; } = true;
    [ObservableProperty] public partial int? CapsuleX { get; set; }
    [ObservableProperty] public partial int? CapsuleY { get; set; }
    [ObservableProperty] public partial bool PanelWhenIdle { get; set; }
    [ObservableProperty] public partial int CallStartAction { get; set; }
    [ObservableProperty] public partial bool StopAfterCall { get; set; }
    [ObservableProperty] public partial bool RemindToSay { get; set; }
    [ObservableProperty] public partial bool WarnOnSilence { get; set; } = true;
    [ObservableProperty] public partial bool PlaySounds { get; set; } = true;
    [ObservableProperty] public partial bool OpenAtSignIn { get; set; }
    [ObservableProperty] public partial bool TranscribeWhenClear { get; set; } = true;
    [ObservableProperty] public partial int AudioRetention { get; set; }

    /// <summary>The folder the phone's recordings arrive in; empty: none is watched.</summary>
    [ObservableProperty] public partial string PhoneFolder { get; set; } = "";

    [ObservableProperty] public partial WhisperModel? SpeechModelChoice { get; set; }
    [ObservableProperty] public partial string? CallLanguagesChoice { get; set; }
    [ObservableProperty] public partial bool? LanguageSwitchingChoice { get; set; }
    [ObservableProperty] public partial bool LowPriority { get; set; } = true;

    [ObservableProperty] public partial Assistant? SummaryAssistantChoice { get; set; }
    [ObservableProperty] public partial bool AutoUpdate { get; set; } = true;

    /// <summary>The project of the last transcribed call: the form starts with it.</summary>
    [ObservableProperty] public partial string LastProject { get; set; } = "";
}
