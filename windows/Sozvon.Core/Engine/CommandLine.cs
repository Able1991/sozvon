using System.Text;

namespace Sozvon.Core.Engine;

/// <summary>Builds the strings CreateProcess takes.</summary>
internal static class CommandLine
{
    /// <summary>One argument, quoted so that CommandLineToArgvW reads it back unchanged.</summary>
    internal static string Quote(string argument)
    {
        if (argument.Length > 0 && argument.IndexOfAny([' ', '\t', '"']) < 0) return argument;
        var quoted = new StringBuilder("\"");
        var backslashes = 0;
        foreach (var ch in argument)
        {
            if (ch == '\\')
            {
                backslashes++;
                continue;
            }
            quoted.Append('\\', ch == '"' ? backslashes * 2 + 1 : backslashes).Append(ch);
            backslashes = 0;
        }
        return quoted.Append('\\', backslashes * 2).Append('"').ToString();
    }

    internal static string Join(string executable, IEnumerable<string> arguments) =>
        string.Join(' ', arguments.Prepend(executable).Select(Quote));

    /// <summary>A Unicode environment block: sorted, each entry ended by a zero, ended by one more zero.</summary>
    internal static char[] EnvironmentBlock(IReadOnlyDictionary<string, string> environment)
    {
        var block = new StringBuilder();
        foreach (var (key, value) in environment.OrderBy(e => e.Key, StringComparer.OrdinalIgnoreCase))
            block.Append(key).Append('=').Append(value).Append('\0');
        return block.Append('\0').ToString().ToCharArray();
    }
}
