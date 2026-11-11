using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

/// <summary>
/// The summary language: absent or "auto" is the conversation's; a chosen one goes to the engine as SOZVON_SUMMARY_LANGUAGE
/// (docs/CONTRACT.md), as the Mac's SummaryLanguageSettingTests.
/// </summary>
public sealed class SummaryLanguageTests : TempFolders
{
    private string Env => Path.Combine(Data, ".env");

    [Fact]
    public void ByDefaultTheSummaryFollowsTheConversation()
    {
        var v = SettingsValues.FromEnv(new Dictionary<string, string>(), () => Assistant.None);
        Assert.Equal(SpeechLanguage.Auto, v.SummaryLanguage);
        Assert.Contains(("SOZVON_SUMMARY_LANGUAGE", "auto"), v.Pairs());
    }

    [Theory]
    [InlineData("ru", SpeechLanguage.Ru)]
    [InlineData("en", SpeechLanguage.En)]
    [InlineData("uk", SpeechLanguage.Uk)]
    [InlineData("de", SpeechLanguage.De)]
    [InlineData("es", SpeechLanguage.Es)]
    [InlineData("auto", SpeechLanguage.Auto)]
    [InlineData("klingon", SpeechLanguage.Auto)]
    [InlineData("ru,en", SpeechLanguage.Auto)]
    public void TheEnvValueIsRead(string value, SpeechLanguage expected) =>
        Assert.Equal(expected, SettingsValues.FromEnv(new Dictionary<string, string> { ["SOZVON_SUMMARY_LANGUAGE"] = value }, () => Assistant.None).SummaryLanguage);

    [Fact]
    public void AChosenLanguageIsSavedWithTheWizardsAnswers()
    {
        new SettingsValues { Assistant = Assistant.Claude, SummaryLanguage = SpeechLanguage.De }.Save(Env);
        Assert.Contains("SOZVON_SUMMARY_LANGUAGE=\"de\"", File.ReadAllText(Env));
        Assert.Equal(SpeechLanguage.De, SettingsValues.Load(Env, () => Assistant.None).SummaryLanguage);
    }

    [Fact]
    public void SettingsChangeOnlyThisKey()
    {
        WriteText(Env, "HF_TOKEN=keep\nSOZVON_LLM=\"codex\"\nSOZVON_ME=\"Аня\"\nSOZVON_SUMMARY_LANGUAGE=\"ru\"\n# comment\n");
        SettingsValues.SaveSummaryLanguage(Env, SpeechLanguage.En);
        var text = File.ReadAllText(Env);
        Assert.Contains("SOZVON_SUMMARY_LANGUAGE=\"en\"", text);
        Assert.DoesNotContain("SOZVON_SUMMARY_LANGUAGE=\"ru\"", text);
        foreach (var kept in new[] { "HF_TOKEN=keep", "SOZVON_LLM=\"codex\"", "SOZVON_ME=\"Аня\"", "# comment" }) Assert.Contains(kept, text);
        Assert.DoesNotContain("SOZVON_MODEL", text); // the wizard's other answers are not written for it
        SettingsValues.SaveSummaryLanguage(Env, SpeechLanguage.Auto);
        Assert.Equal(SpeechLanguage.Auto, SettingsValues.Load(Env, () => Assistant.None).SummaryLanguage);
        Assert.Contains("SOZVON_SUMMARY_LANGUAGE=\"auto\"", File.ReadAllText(Env));
    }

    [Fact]
    public void ANewFileGetsJustTheKey()
    {
        SettingsValues.SaveSummaryLanguage(Env, SpeechLanguage.Uk);
        Assert.Equal("SOZVON_SUMMARY_LANGUAGE=\"uk\"\n", File.ReadAllText(Env));
    }
}
