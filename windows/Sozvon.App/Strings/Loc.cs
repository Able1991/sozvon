using System.Globalization;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;

namespace Sozvon.App.Strings;

/// <summary>
/// The neutral string table: keys are the Russian source strings, as on the Mac. English comes from the Mac's
/// Localizable.strings, with the Windows-only strings on top. The language is chosen once, at startup.
/// </summary>
public static partial class Loc
{
    private static Dictionary<string, string> _english = [];

    public static bool IsRussian { get; private set; } = true;

    public static CultureInfo Culture => IsRussian ? new CultureInfo("ru-RU") : new CultureInfo("en-US");

    /// <summary>Applied at startup only; a change in Settings takes effect after a relaunch.</summary>
    public static void Initialize(bool russian)
    {
        IsRussian = russian;
        if (!russian)
        {
            _english = LoadEnglish();
        }
    }

    public static string L(string key) =>
        IsRussian || !_english.TryGetValue(key, out var english) ? key : english;

    /// <summary>Formats a Mac-style template: %@ and %d in order, or %1$@ by position.</summary>
    public static string L(string key, params object[] args)
    {
        var next = 0;
        return Placeholder().Replace(L(key), match =>
        {
            if (match.Value == "%%")
            {
                return "%";
            }
            var index = match.Groups[1].Success ? int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture) - 1 : next++;
            return index < args.Length ? Convert.ToString(args[index], Culture) ?? "" : match.Value;
        });
    }

    private static Dictionary<string, string> LoadEnglish()
    {
        var table = new Dictionary<string, string>();
        Read(table, "mac.en.strings");
        Read(table, "windows-en.strings");
        return table;
    }

    private static void Read(Dictionary<string, string> table, string resource)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource)
            ?? throw new InvalidOperationException($"Missing embedded resource {resource}");
        using var reader = new StreamReader(stream, Encoding.UTF8);
        while (reader.ReadLine() is { } line)
        {
            var match = Entry().Match(line);
            if (match.Success)
            {
                table[Unescape(match.Groups[1].Value)] = Unescape(match.Groups[2].Value);
            }
        }
    }

    private static string Unescape(string text) =>
        Escape().Replace(text, m => m.Value[1] == 'n' ? "\n" : m.Value[1].ToString());

    [GeneratedRegex("""^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";""")]
    private static partial Regex Entry();

    [GeneratedRegex(@"\\.")]
    private static partial Regex Escape();

    [GeneratedRegex(@"%%|%(?:(\d+)\$)?[@ds]")]
    private static partial Regex Placeholder();
}
