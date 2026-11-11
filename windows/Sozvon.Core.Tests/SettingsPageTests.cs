using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace Sozvon.Core.Tests;

/// <summary>The Settings page's markup and texts, read from the app's sources.</summary>
public sealed class SettingsPageTests
{
    private static readonly XNamespace Ui = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";

    private static XDocument Page() =>
        XDocument.Load(Path.Combine(Repo.Root(), "windows", "Sozvon.App", "Settings", "SettingsPage.xaml"));

    /// <summary>"Тема" is the call's topic in the Mac's table ("Topic"); in Settings it is the window theme.</summary>
    [Fact]
    public void ThemeRowReadsThemeInEnglish()
    {
        var text = File.ReadAllText(Path.Combine(Repo.Root(), "windows", "Sozvon.App", "Strings", "windows-en.strings"));
        var entry = Regex.Match(text, "^\"Тема\"\\s*=\\s*\"([^\"]*)\";", RegexOptions.Multiline);
        Assert.True(entry.Success, "windows-en.strings has no entry for «Тема»");
        Assert.Equal("Theme", entry.Groups[1].Value);
    }
}
