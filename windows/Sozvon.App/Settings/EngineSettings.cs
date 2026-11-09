using Sozvon.App.Strings;
using Sozvon.Core.Calls;
using Sozvon.Core.Engine;
using Sozvon.Core.Settings;

namespace Sozvon.App.Settings;

/// <summary>
/// What the engine runs with. A value changed in Settings wins; until then the setup wizard's choice stands, in the
/// .env the engine reads by itself. Only real choices go through the environment, so a default in Settings can never
/// overrule the wizard (a user who chose no summaries keeps them off).
/// </summary>
public sealed class EngineSettings(AppSettings settings, string envFile)
{
    private SettingsValues Wizard => SettingsValues.Load(envFile);

    public string Name => settings.DisplayName.Trim() is { Length: > 0 } name ? name : Wizard.Name;

    public WhisperModel Model => settings.SpeechModelChoice ?? Wizard.Model;

    public IReadOnlyList<SpeechLanguage> Languages =>
        settings.CallLanguagesChoice is { } chosen ? SpeechLanguages.Parse(chosen) : Wizard.Languages;

    public bool LanguageSwitch => settings.LanguageSwitchingChoice ?? Wizard.LanguageSwitch;

    public Assistant Assistant => settings.SummaryAssistantChoice ?? Wizard.Assistant;

    /// <summary>Read for every run: a change in Settings applies to the next call.</summary>
    public EngineOptions Options() => new(
        Loc.IsRussian ? "ru" : "en",
        Me: settings.DisplayName.Trim() is { Length: > 0 } me ? me : null,
        Llm: settings.SummaryAssistantChoice,
        Languages: settings.CallLanguagesChoice is { } languages ? SpeechLanguages.Parse(languages) : null,
        LanguageSwitch: settings.LanguageSwitchingChoice,
        Model: settings.SpeechModelChoice);

    /// <summary>The answers a call starts with, before the form.</summary>
    public CallInfo NewCall() => new() { Languages = Languages, Summary = Assistant != Assistant.None };
}
