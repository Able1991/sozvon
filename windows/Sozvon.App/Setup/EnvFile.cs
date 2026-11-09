using System.Text;

namespace Sozvon.App.Setup;

/// <summary>The engine's .env file: KEY=value lines, foreign keys and comments are kept (docs/CONTRACT.md, section 2).</summary>
internal static class EnvFile
{
    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    public static Dictionary<string, string> Read(string path)
    {
        var values = new Dictionary<string, string>();
        foreach (var line in ReadText(path).Split('\n'))
        {
            var text = line.Trim();
            var equals = text.IndexOf('=');
            if (!text.StartsWith('#') && equals > 0)
            {
                values[text[..equals].Trim()] = Unquote(text[(equals + 1)..].Trim());
            }
        }
        return values;
    }

    /// <summary>Replaces the given keys and keeps every other line. The file is swapped in whole, so a crash cannot truncate it.</summary>
    public static void Write(string path, IReadOnlyDictionary<string, string> values)
    {
        var lines = ReadText(path).Split('\n').Select(line => line.TrimEnd('\r')).Where(line => !IsSetBy(line, values)).ToList();
        while (lines.Count > 0 && lines[^1].Length == 0)
        {
            lines.RemoveAt(lines.Count - 1);
        }
        lines.AddRange(values.Select(pair => $"{pair.Key}={Quote(pair.Value)}"));

        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, string.Join('\n', lines) + "\n", Utf8);
        File.Move(temporary, path, overwrite: true);
    }

    private static string ReadText(string path)
    {
        if (!File.Exists(path))
        {
            return "";
        }
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream, Utf8);
        return reader.ReadToEnd();
    }

    private static bool IsSetBy(string line, IReadOnlyDictionary<string, string> values)
    {
        var text = line.Trim();
        var equals = text.IndexOf('=');
        return !text.StartsWith('#') && equals > 0 && values.ContainsKey(text[..equals].Trim());
    }

    // Always double quoted: python-dotenv reads an unquoted "Ivan #2" as "Ivan".
    private static string Quote(string value)
    {
        var escaped = value.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "\\r").Replace("\t", "\\t");
        return $"\"{escaped}\"";
    }

    private static string Unquote(string raw)
    {
        if (raw.StartsWith('\''))
        {
            var end = raw.IndexOf('\'', 1);
            return end > 0 ? raw[1..end] : raw;
        }
        if (!raw.StartsWith('"'))
        {
            var comment = raw.IndexOf(" #", StringComparison.Ordinal);
            return comment >= 0 ? raw[..comment].TrimEnd() : raw;
        }
        var result = new StringBuilder();
        for (var i = 1; i < raw.Length && raw[i] != '"'; i++)
        {
            if (raw[i] == '\\' && i + 1 < raw.Length)
            {
                i++;
                result.Append(raw[i] switch { 'n' => '\n', 'r' => '\r', 't' => '\t', var other => other });
            }
            else
            {
                result.Append(raw[i]);
            }
        }
        return result.ToString();
    }
}
