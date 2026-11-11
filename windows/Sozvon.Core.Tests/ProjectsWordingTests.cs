using System.Text.RegularExpressions;

namespace Sozvon.Core.Tests;

/// <summary>Windows words in the English Projects page: the deleted project's file goes to the Recycle Bin.</summary>
public sealed partial class ProjectsWordingTests
{
    private const string DeleteText =
        "Звонки сохранят свои расшифровки. Уйдут только люди, термины и замены этого проекта. Файл попадёт в Корзину, его можно вернуть.";

    /// <summary>The Windows English table, which wins over the Mac's.</summary>
    internal static Dictionary<string, string> WindowsEnglish()
    {
        var path = Path.Combine(Repo.Root(), "windows", "Sozvon.App", "Strings", "windows-en.strings");
        return File.ReadLines(path).Select(line => Pair().Match(line)).Where(m => m.Success)
            .ToDictionary(m => m.Groups[1].Value, m => m.Groups[2].Value);
    }

    /// <summary>The Mac's text said "The file goes to the Trash": Windows has no Trash.</summary>
    [Fact]
    public void ProjectDeleteQuestionNamesTheRecycleBin()
    {
        var english = WindowsEnglish();
        Assert.True(english.TryGetValue(DeleteText, out var text), "no Windows English for the project delete question");
        Assert.Contains("Recycle Bin", text);
        Assert.DoesNotContain("Trash", text);
    }

    [GeneratedRegex("^\"(.*)\" = \"(.*)\";$")]
    private static partial Regex Pair();
}
