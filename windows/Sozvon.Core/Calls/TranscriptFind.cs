using System.Globalization;

namespace Sozvon.Core.Calls;

/// <summary>Find inside one transcript (Ctrl+F on the Transcript tab). Search across calls is the list's.</summary>
public static class TranscriptFind
{
    /// <summary>A match: the paragraph's number and where in its text, in UTF-16 units.</summary>
    public sealed record Match(int Line, int Start, int Length);

    /// <summary>The engine's end-of-paragraph mark for a line starred during the recording: not the words of the call.</summary>
    public const string Star = " ⭐";

    private const CompareOptions Loose = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace | CompareOptions.IgnoreWidth;

    /// <summary>Every occurrence, in reading order. Case and diacritics don't count, so "счет" finds "Счёт".</summary>
    public static List<Match> Matches(string query, IReadOnlyList<string> lines)
    {
        var q = query.Trim();
        var found = new List<Match>();
        if (q.Length == 0) return found;
        var compare = CultureInfo.InvariantCulture.CompareInfo;
        for (var n = 0; n < lines.Count; n++)
        {
            var line = lines[n];
            var end = line.EndsWith(Star, StringComparison.Ordinal) ? line.Length - Star.Length : line.Length;
            var from = 0;
            while (from < end)
            {
                var at = compare.IndexOf(line.AsSpan(from, end - from), q, Loose, out var length);
                if (at < 0 || length == 0) break;
                found.Add(new Match(n, from + at, length));
                from += at + length;
            }
        }
        return found;
    }

    /// <summary>Next (+1) or Previous (-1), going round at the ends.</summary>
    public static int Step(int index, int delta, int count) =>
        count <= 0 ? 0 : ((index + delta) % count + count) % count;
}
