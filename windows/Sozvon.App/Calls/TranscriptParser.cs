using System.Globalization;
using System.Text.RegularExpressions;

namespace Sozvon.App.Calls;

public sealed record TranscriptLine(double Start, string Time, string Speaker, string Text, bool IsMe)
{
    public string SpeakerLabel => Speaker + ":";

    public override string ToString() => $"{Time} {Speaker}: {Text}";
}

/// <summary>transcript.txt, one paragraph per "[MM:SS] Name: text" line.</summary>
public static partial class TranscriptParser
{
    public static IReadOnlyList<TranscriptLine> Parse(string transcript, string myName) =>
        transcript.Split('\n')
            .Select(line => Line().Match(line.TrimEnd('\r')))
            .Where(m => m.Success)
            .Select(m => Build(m, myName))
            .ToList();

    private static TranscriptLine Build(Match match, string myName)
    {
        var speaker = match.Groups[2].Value;
        var isMe = speaker is "Я" or "Me" || (myName.Length > 0 && speaker.Equals(myName, StringComparison.OrdinalIgnoreCase));
        var start = Seconds(match.Groups[1].Value);
        return new TranscriptLine(start, CallFormat.Clock(start), speaker, match.Groups[3].Value, isMe);
    }

    private static double Seconds(string time) =>
        time.Split(':').Aggregate(0.0, (total, part) => total * 60 + double.Parse(part, CultureInfo.InvariantCulture));

    [GeneratedRegex(@"^\[(\d{1,2}:\d{2}(?::\d{2})?)\] ([^:]+): ?(.*)$")]
    private static partial Regex Line();
}
