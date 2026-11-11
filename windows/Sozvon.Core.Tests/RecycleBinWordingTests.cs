using System.Text.RegularExpressions;

namespace Sozvon.Core.Tests;

/// <summary>English words the Mac table uses that Windows says differently.</summary>
public sealed partial class RecycleBinWordingTests
{
    private static Dictionary<string, string> MacEnglish()
    {
        var path = Path.Combine(Repo.Root(), "Sources", "Sozvon", "Resources", "en.lproj", "Localizable.strings");
        return File.ReadLines(path).Select(line => Pair().Match(line)).Where(m => m.Success)
            .GroupBy(m => m.Groups[1].Value).ToDictionary(g => g.Key, g => g.Last().Groups[2].Value);
    }

    /// <summary>Windows has a Recycle Bin, not a Trash: every Mac text that names the Trash has a Windows one.</summary>
    [Fact]
    public void NoEnglishTextNamesTheTrash()
    {
        var windows = ProjectsWordingTests.WindowsEnglish();
        var left = MacEnglish().Where(p => p.Value.Contains("Trash"))
            .Where(p => !windows.TryGetValue(p.Key, out var w) || w.Contains("Trash"))
            .Select(p => p.Key).ToList();
        Assert.Empty(left);
    }

    /// <summary>Menu items and buttons are sentence case on Windows.</summary>
    [Fact]
    public void UpdateSummaryIsSentenceCase()
    {
        Assert.Equal("Update summary", ProjectsWordingTests.WindowsEnglish().GetValueOrDefault("Обновить саммари"));
    }

    [GeneratedRegex("^\"(.*)\" = \"(.*)\";$")]
    private static partial Regex Pair();
}
