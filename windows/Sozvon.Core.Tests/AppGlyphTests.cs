using System.Text.RegularExpressions;

namespace Sozvon.Core.Tests;

/// <summary>
/// Icon glyphs are private-use characters, invisible in most editors and easy to lose in an edit: an empty glyph draws
/// nothing (the task checkboxes of the summary did). The app writes them as \u escapes, never as empty strings.
/// </summary>
public sealed partial class AppGlyphTests
{
    [Fact]
    public void NoGlyphIsAnEmptyString()
    {
        var app = Path.Combine(Repo.Root(), "windows", "Sozvon.App");
        Assert.True(Directory.Exists(app), app);
        var offenders = Directory.EnumerateFiles(app, "*.cs", SearchOption.AllDirectories)
            .Where(file => !file.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}"))
            .SelectMany(file => File.ReadLines(file).Select((line, i) => (file, line: i + 1, text: line)))
            .Where(l => EmptyGlyph().IsMatch(l.text))
            .Select(l => $"{Path.GetRelativePath(app, l.file)}:{l.line}: {l.text.Trim()}")
            .ToList();
        Assert.Empty(offenders);
    }

    [GeneratedRegex(@"(?i)glyph[^=\n]*(=>|=)[^;\n]*""""")]
    private static partial Regex EmptyGlyph();
}
