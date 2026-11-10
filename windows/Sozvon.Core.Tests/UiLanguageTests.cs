using Sozvon.Core.Settings;

namespace Sozvon.Core.Tests;

/// <summary>The setup wizard runs as its own process and picks its language the way the app does: from settings.json.</summary>
public sealed class UiLanguageTests
{
    [Theory]
    [InlineData("""{"Language":"English"}""", true, false)]  // the setting wins over a Russian Windows
    [InlineData("""{"Language":"Russian"}""", false, true)]  // ...and over an English one
    [InlineData("""{"Language":"System"}""", true, true)]    // "System" follows Windows
    [InlineData("""{"Language":"System"}""", false, false)]
    [InlineData("""{"Theme":"Dark"}""", true, true)]         // no language saved yet: Windows
    [InlineData("""{"Theme":"Dark"}""", false, false)]
    [InlineData(null, true, true)]                           // first run, no settings.json: Windows
    [InlineData(null, false, false)]
    [InlineData("""{"Language":2}""", true, false)]          // the enum's number, as System.Text.Json also accepts it
    [InlineData("""{"Language":1}""", false, true)]
    [InlineData("""{"Language":"english"}""", true, false)]  // case does not matter, as for the app's reader
    [InlineData("""{"Language":"Klingon"}""", true, true)]   // an unknown value: Windows
    [InlineData("{not json", false, false)]                  // a broken file: Windows, as the app itself falls back
    [InlineData("", true, true)]
    public void FollowsTheAppsSetting(string? settingsJson, bool systemIsRussian, bool russian) =>
        Assert.Equal(russian, UiLanguage.IsRussian(settingsJson, systemIsRussian));
}
