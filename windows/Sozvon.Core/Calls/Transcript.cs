using System.Text.RegularExpressions;

namespace Sozvon.Core.Calls;

/// <summary>One transcript paragraph: start in seconds from the start of the call, speaker label, text.</summary>
public sealed record TranscriptLine(double Start, string Speaker, string Text);

/// <summary>
/// Transcript lines: "[MM:SS] Name: text" (transcript.txt) and "**[MM:SS] Name:** text" (transcript.md), both
/// written by the engine. Pure text functions; line ends may be LF or CRLF and are kept as they were.
/// </summary>
public static class Transcript
{
    private const string PeopleDot = " · ";
    private const string Colon = ": ";

    /// <summary>"05:07" is 307; "1:02:03" and "01:02:03" are 3723. Anything else: null.</summary>
    public static double? Timestamp(string text)
    {
        var parts = text.Split(':');
        if (parts.Length is not (2 or 3)) return null;
        if (parts.Any(p => p.Length is 0 or > 2 || !p.All(char.IsAsciiDigit))) return null;
        var numbers = parts.Select(int.Parse).ToArray();
        // Fields after the first are two digits, as render.py pads them.
        if (parts.Skip(1).Any(p => p.Length != 2) || numbers.Skip(1).Any(n => n >= 60)) return null;
        return numbers.Aggregate(0, (total, n) => total * 60 + n);
    }

    /// <summary>A transcript line in either format, otherwise null. Prefix is everything before the text.</summary>
    public static (TranscriptLine Line, string Prefix)? Parse(string raw)
    {
        var bold = raw.StartsWith("**[", StringComparison.Ordinal);
        var s = bold ? raw[2..] : raw;
        if (!s.StartsWith('[')) return null;
        var close = s.IndexOf(']');
        if (close < 0 || Timestamp(s[1..close]) is not { } start) return null;
        var rest = s[(close + 1)..];
        if (!rest.StartsWith(' ')) return null;
        rest = rest[1..];

        var separator = bold ? ":** " : Colon;
        var ending = bold ? ":**" : ":";
        string speaker, text;
        var at = rest.IndexOf(separator, StringComparison.Ordinal);
        if (at >= 0)
        {
            speaker = rest[..at];
            text = rest[(at + separator.Length)..];
        }
        else if (rest.EndsWith(ending, StringComparison.Ordinal))
        {
            speaker = rest[..^ending.Length];
            text = "";
        }
        else
        {
            return null;
        }
        if (speaker.Length == 0 || speaker.StartsWith(' ')) return null;
        return (new TranscriptLine(start, speaker, text), raw[..^text.Length]);
    }

    public static List<TranscriptLine> Lines(string text)
    {
        var lines = new List<TranscriptLine>();
        foreach (var row in Rows(text))
            if (Parse(row) is { } parsed) lines.Add(parsed.Line);
        return lines;
    }

    /// <summary>Index of the line being played at a time: the last one started at or before it.</summary>
    public static int? LineIndex(double time, IReadOnlyList<double> starts)
    {
        int lo = 0, hi = starts.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (starts[mid] <= time) lo = mid + 1;
            else hi = mid;
        }
        return lo == 0 ? null : lo - 1;
    }

    /// <summary>A label that keeps the format readable: trimmed, non-empty, no ":", "*", "[" or line breaks.</summary>
    public static string? CleanSpeaker(string text)
    {
        var t = text.Trim();
        return t.Length is 0 or > 80 || t.Any(":*[]\n\r\t".Contains) ? null : t;
    }

    /// <summary>Renames a speaker everywhere, plus the participant list in the transcript.md header.</summary>
    public static string RenameSpeaker(string text, string from, string to)
    {
        var seenLine = false;
        return MapRows(text, raw =>
        {
            if (Parse(raw) is { } parsed)
            {
                seenLine = true;
                return parsed.Line.Speaker == from ? WithSpeaker(parsed.Line, parsed.Prefix, to) : raw;
            }
            return seenLine ? raw : RenamePeople(raw, from, to);
        });
    }

    /// <summary>Swaps two speakers everywhere, and their places in the participant list.</summary>
    public static string SwapSpeakers(string text, string a, string b)
    {
        if (a == b) return text;
        var placeholder = "\u0001swap:" + Guid.NewGuid(); // cannot be a label: CleanSpeaker forbids ":"
        return RenameSpeaker(RenameSpeaker(RenameSpeaker(text, a, placeholder), b, a), placeholder, b);
    }

    /// <summary>Gives the n-th line equal to the target to another speaker. Null when there is no such line.</summary>
    public static string? Reassign(string text, TranscriptLine target, int occurrence, string to)
    {
        if (target.Speaker == to || occurrence < 0) return null;
        var (rows, ending) = Split(text);
        var seen = 0;
        for (var i = 0; i < rows.Count; i++)
        {
            if (Parse(rows[i]) is not { } parsed || parsed.Line != target) continue;
            if (seen++ < occurrence) continue;
            rows[i] = WithSpeaker(parsed.Line, parsed.Prefix, to);
            return Join(SyncPeople(rows), ending);
        }
        return null;
    }

    /// <summary>Whether renaming merges two speakers: the new name already speaks in the call.</summary>
    public static bool RenameMerges(IEnumerable<TranscriptLine> lines, string from, string to) =>
        CleanSpeaker(to) is { } name && name != from && lines.Any(l => l.Speaker == name);

    public static bool ContainsWord(string text, string word) => word.Length > 0 && WholeWord(word).IsMatch(text);

    /// <summary>The text with every whole-word match replaced, or null when there is none.</summary>
    public static string? ReplaceWord(string text, string wrong, string right) =>
        ContainsWord(text, wrong) ? WholeWord(wrong).Replace(text, _ => right) : null;

    /// <summary>Replaces a whole word in the n-th line equal to the target. Null when nothing was replaced.</summary>
    public static string? Fix(string text, TranscriptLine target, int occurrence, string wrong, string right)
    {
        if (wrong.Length == 0 || wrong == right || occurrence < 0) return null;
        var (rows, ending) = Split(text);
        var seen = 0;
        for (var i = 0; i < rows.Count; i++)
        {
            if (Parse(rows[i]) is not { } parsed || parsed.Line != target) continue;
            if (seen++ < occurrence) continue;
            if (ReplaceWord(parsed.Line.Text, wrong, right) is not { } fixedText) return null;
            rows[i] = parsed.Prefix + fixedText;
            return Join(rows, ending);
        }
        return null;
    }

    private static Regex WholeWord(string word) =>
        new(@"(?<![\p{L}\p{N}_])" + Regex.Escape(word) + @"(?![\p{L}\p{N}_])");

    private static string WithSpeaker(TranscriptLine line, string prefix, string speaker)
    {
        var bold = prefix.StartsWith("**", StringComparison.Ordinal);
        var body = bold ? prefix[2..] : prefix;
        var head = (bold ? "**" : "") + body[..(body.IndexOf(']') + 1)] + " " + speaker + (bold ? ":**" : ":");
        return line.Text.Length == 0 ? head : head + " " + line.Text;
    }

    /// <summary>"Duration: 05:00 · People: Anna, Me" with one name replaced.</summary>
    private static string RenamePeople(string raw, string from, string to)
    {
        if (PeopleStart(raw) is not { } start) return raw;
        var names = raw[start..].Split(", ");
        if (!names.Contains(from)) return raw;
        return raw[..start] + string.Join(", ", names.Select(n => n == from ? to : n).Distinct());
    }

    /// <summary>The header line with the people rebuilt from the speakers, in the order they first speak.</summary>
    private static List<string> SyncPeople(List<string> rows)
    {
        var speakers = rows.Select(Parse).Where(p => p is not null).Select(p => p!.Value.Line.Speaker).Distinct().ToList();
        for (var i = 0; i < rows.Count && Parse(rows[i]) is null; i++)
        {
            if (PeopleStart(rows[i]) is not { } start) continue;
            rows[i] = rows[i][..start] + string.Join(", ", speakers);
            break;
        }
        return rows;
    }

    /// <summary>Where the list of names starts in a "Label: 05:00 · Label: names" header line.</summary>
    private static int? PeopleStart(string raw)
    {
        var dot = raw.LastIndexOf(PeopleDot, StringComparison.Ordinal);
        var first = raw.IndexOf(Colon, StringComparison.Ordinal);
        if (dot < 0 || first < 0 || first + Colon.Length > dot) return null;
        if (Timestamp(raw[(first + Colon.Length)..dot]) is null) return null;
        var colon = raw.IndexOf(Colon, dot + PeopleDot.Length, StringComparison.Ordinal);
        return colon < 0 ? null : colon + Colon.Length;
    }

    private static IEnumerable<string> Rows(string text) => text.Split('\n').Select(r => r.TrimEnd('\r'));

    private static (List<string> Rows, string Ending) Split(string text) =>
        (Rows(text).ToList(), text.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n");

    private static string Join(IEnumerable<string> rows, string ending) => string.Join(ending, rows);

    private static string MapRows(string text, Func<string, string> map)
    {
        var (rows, ending) = Split(text);
        return Join(rows.Select(map), ending);
    }
}

/// <summary>Track start offsets for playback: each track starts this many seconds after the earliest one.</summary>
public sealed record TrackOffsets(double Mic, double System)
{
    public static TrackOffsets From(AudioTimes a)
    {
        var starts = new[] { a.MicStart, a.SystemStart }.OfType<double>().ToArray();
        var t0 = starts.Length > 0 ? starts.Min() : 0;
        return new TrackOffsets((a.MicStart ?? t0) - t0, (a.SystemStart ?? t0) - t0);
    }
}
