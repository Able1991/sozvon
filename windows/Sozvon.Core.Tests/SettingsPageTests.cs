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

    /// <summary>
    /// A box or a switch carries no text of its own: without a name a screen reader says only "combo box, Light". The
    /// Mac labels each of them (accessibilityLabel); here each has the row's header as its name.
    /// </summary>
    [Fact]
    public void EveryBoxAndSwitchHasAName()
    {
        var nameless = Page().Descendants()
            .Where(e => e.Name == Ui + "TextBox" || e.Name == Ui + "ComboBox" || e.Name == Ui + "ToggleSwitch" || e.Name == Ui + "PasswordBox")
            .Where(e => e.Attribute("AutomationProperties.Name") is null)
            .Select(e => e.ToString().Split('\n')[0])
            .ToList();
        Assert.Empty(nameless);
    }

    /// <summary>A link as a row's control ends on the same right edge as the boxes and switches: its padding is pulled back.</summary>
    [Fact]
    public void RowLinksEndOnTheRowsRightEdge()
    {
        var links = Page().Descendants(Ui + "HyperlinkButton").Where(e => e.Parent?.Name.LocalName == "SettingsRow").ToList();
        Assert.NotEmpty(links);
        foreach (var link in links)
        {
            Assert.Equal("0,0,-11,0", (string?)link.Attribute("Margin"));
        }
    }
}
