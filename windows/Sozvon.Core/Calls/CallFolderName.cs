using System.Text;
using System.Text.RegularExpressions;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Calls;

/// <summary>
/// "2026-11-04 15-01 · Acme · launch · Anna, Ivan". The start (the id) never changes, so a later rename takes only
/// the date from the old name. Characters Windows forbids are replaced; the name stays within MAX_PATH.
/// </summary>
public static partial class CallFolderName
{
    private const string Separator = " · ";
    private const int MaxLength = 120;
    private const int MaxPath = 260;

    /// <summary>The longest path inside a call folder, with room to spare (the engine's own limit).</summary>
    private const int LongestInside = 48;

    /// <param name="people">Who took part; null uses the typed names of <paramref name="info"/>.</param>
    /// <param name="callsRoot">The calls folder, to keep the name within MAX_PATH; null skips that limit.</param>
    public static string Build(string current, CallInfo info, string? projectTitle, IReadOnlyList<string>? people = null,
                               string? callsRoot = null)
    {
        var id = CallFolder.IdFromName(current);
        var parts = new List<string> { id };
        if (projectTitle?.Trim() is { Length: > 0 } title) parts.Add(title);
        if (info.Topic.Trim() is { Length: > 0 } topic) parts.Add(topic);
        var names = TextRules.ShortPeople((people ?? TextRules.SplitList(info.Names)).Where(n => n.Trim().Length > 0).ToList(), 3);
        if (names.Length > 0) parts.Add(names);

        var name = Trimmed(TextRules.Prefix(Clean(string.Join(Separator, parts)), Limit(callsRoot)));
        return ReservedName().IsMatch(name) ? id : name;
    }

    public static string Build(string current, CallInfo info, IEnumerable<Project> projects, IReadOnlyList<string>? people = null,
                               string? callsRoot = null) =>
        Build(current, info, projects.FirstOrDefault(p => p.Slug == info.Profile)?.ShortTitle, people, callsRoot);

    private static int Limit(string? callsRoot)
    {
        if (callsRoot is null) return MaxLength;
        var room = MaxPath - 1 - callsRoot.Length - 2 - LongestInside; // two separators: calls\name\inside
        return Math.Clamp(room, 0, MaxLength);
    }

    private static string Clean(string text)
    {
        var clean = new StringBuilder(text.Length);
        foreach (var ch in text)
        {
            if (ch is '/' or '\\' or ':' or '<' or '>' or '"' or '|' or '?' or '*') clean.Append('-');
            else if (ch is '\n' or '\r' or '\t' or (char)0x85 or (char)0x2028 or (char)0x2029) clean.Append(' ');
            else if (!char.IsControl(ch)) clean.Append(ch);
        }
        return clean.ToString();
    }

    private static string Trimmed(string name) => name.TrimEnd(' ', '·', '.');

    [GeneratedRegex(@"^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³]|CONIN\$|CONOUT\$)(\.|$)", RegexOptions.IgnoreCase)]
    private static partial Regex ReservedName();
}
