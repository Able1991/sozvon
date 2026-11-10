using System.Text.RegularExpressions;

namespace Sozvon.Core.Tests;

/// <summary>
/// Sozvon's icon sits in the notification area next to the clock, not on the taskbar: the wizard's texts, Russian keys
/// and English values alike, use Windows' own term for it.
/// </summary>
public sealed partial class SetupWordingTests
{
    [Fact]
    public void TheIconIsInTheNotificationArea()
    {
        var setup = Path.Combine(Repo.Root(), "windows", "Sozvon.App", "Setup");
        Assert.True(Directory.Exists(setup), setup);
        var offenders = Directory.EnumerateFiles(setup, "*.cs", SearchOption.AllDirectories)
            .SelectMany(file => File.ReadLines(file).Select((line, i) => (file, line: i + 1, text: line)))
            .Where(l => Taskbar().IsMatch(l.text))
            .Select(l => $"{Path.GetRelativePath(setup, l.file)}:{l.line}: {l.text.Trim()}")
            .ToList();
        Assert.Empty(offenders);
    }

    [GeneratedRegex(@"панел[иьея]\s+задач|taskbar", RegexOptions.IgnoreCase)]
    private static partial Regex Taskbar();
}
