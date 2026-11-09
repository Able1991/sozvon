using System.Text;

namespace Sozvon.Core.Settings;

/// <summary>
/// A <c>KEY=value</c> file, line by line. Foreign keys and comments are kept. Values are written in double quotes:
/// python-dotenv reads <c>SOZVON_ME=Ivan #2</c> without quotes as "Ivan".
/// </summary>
public static class EnvFile
{
    public static List<(string Key, string Value)> Parse(string text)
    {
        var pairs = new List<(string, string)>();
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            var equals = line.IndexOf('=');
            if (line.StartsWith('#') || equals < 0) continue;
            pairs.Add((line[..equals].Trim(), Value(line[(equals + 1)..])));
        }
        return pairs;
    }

    public static Dictionary<string, string> ToDictionary(string text)
    {
        var values = new Dictionary<string, string>();
        foreach (var (key, value) in Parse(text)) values[key] = value;
        return values;
    }

    /// <summary>Removes the lines of the keys being set or removed, then appends the new values, quoted.</summary>
    public static string Merge(string text, IReadOnlyList<(string Key, string Value)> set, IEnumerable<string>? remove = null)
    {
        var drop = new HashSet<string>(set.Select(p => p.Key));
        if (remove is not null) drop.UnionWith(remove);
        var lines = text.Split('\n').Select(l => l.TrimEnd('\r')).ToList();
        while (lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);
        lines.RemoveAll(line => KeyOf(line) is { } key && drop.Contains(key));
        lines.AddRange(set.Select(p => $"{p.Key}={Quote(p.Value)}"));
        return string.Join('\n', lines) + "\n";
    }

    public static string Quote(string value)
    {
        var quoted = new StringBuilder("\"");
        foreach (var ch in value)
        {
            quoted.Append(ch switch
            {
                '\\' => "\\\\",
                '"' => "\\\"",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                _ => ch.ToString(),
            });
        }
        return quoted.Append('"').ToString();
    }

    internal static string Value(string raw)
    {
        var v = raw.Trim();
        if (v.StartsWith('"')) return DoubleQuoted(v);
        if (v.StartsWith('\''))
        {
            var end = v.IndexOf('\'', 1);
            if (end > 0) return v[1..end];
        }
        var comment = v.IndexOf(" #", StringComparison.Ordinal);
        return comment >= 0 ? v[..comment].Trim() : v;
    }

    private static string DoubleQuoted(string v)
    {
        var value = new StringBuilder();
        var escaped = false;
        foreach (var ch in v.AsSpan(1))
        {
            if (escaped)
            {
                value.Append(ch switch
                {
                    'n' => "\n",
                    't' => "\t",
                    'r' => "\r",
                    '\\' or '"' or '\'' => ch.ToString(),
                    _ => "\\" + ch,
                });
                escaped = false;
            }
            else if (ch == '\\') escaped = true;
            else if (ch == '"') return value.ToString();
            else value.Append(ch);
        }
        return value.ToString();
    }

    private static string? KeyOf(string line)
    {
        var trimmed = line.Trim();
        var equals = trimmed.IndexOf('=');
        return trimmed.StartsWith('#') || equals < 0 ? null : trimmed[..equals].Trim();
    }
}
