using System.Text.RegularExpressions;

namespace Sozvon.App.Calls;

public enum SummaryPieceKind { Paragraph, Heading, Bullet, Task }

public sealed record SummaryPiece(SummaryPieceKind Kind, string Text, string Owner = "", bool Done = false);

public sealed record SummaryBlock(string Title, IReadOnlyList<SummaryPiece> Pieces);

/// <summary>summary.md split into the cards of the feed, by the same rules as the Mac's SummaryBlocks and ActionItems.</summary>
public static partial class SummaryParser
{
    public static IReadOnlyList<SummaryBlock> Parse(string markdown)
    {
        var blocks = new List<(string Title, List<SummaryPiece> Pieces)>();
        foreach (var raw in markdown.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line == "---")
            {
                continue;
            }
            if (line.StartsWith("# ", StringComparison.Ordinal) || line.StartsWith("## ", StringComparison.Ordinal))
            {
                blocks.Add((line.TrimStart('#').Trim(), []));
                continue;
            }
            if (blocks.Count == 0)
            {
                blocks.Add(("", []));
            }
            blocks[^1].Pieces.Add(ParseLine(line));
        }
        return blocks.Select(b => new SummaryBlock(b.Title, b.Pieces)).ToList();
    }

    private static SummaryPiece ParseLine(string line)
    {
        if (line.StartsWith("- [ ] ", StringComparison.Ordinal) || line.StartsWith("- [x] ", StringComparison.OrdinalIgnoreCase))
        {
            return ParseTask(line);
        }
        if (line.StartsWith("- ", StringComparison.Ordinal) || line.StartsWith("* ", StringComparison.Ordinal))
        {
            return new SummaryPiece(SummaryPieceKind.Bullet, Clean(line[2..]));
        }
        return line.StartsWith('#')
            ? new SummaryPiece(SummaryPieceKind.Heading, Clean(line.TrimStart('#').Trim()))
            : new SummaryPiece(SummaryPieceKind.Paragraph, Clean(line));
    }

    private static SummaryPiece ParseTask(string line)
    {
        var done = line[3] != ' ';
        var text = line[6..].Trim();
        var colon = text.IndexOf(':');
        if (colon > 0)
        {
            var owner = text[..colon].Replace("*", "").Trim();
            var after = text[(colon + 1)..];
            if (after.StartsWith("**", StringComparison.Ordinal))
            {
                after = after[2..];
            }
            if (IsOwner(owner, after) && Clean(after) is { Length: > 0 } task)
            {
                return new SummaryPiece(SummaryPieceKind.Task, task, owner, done);
            }
        }
        return new SummaryPiece(SummaryPieceKind.Task, Clean(text), "", done);
    }

    /// <summary>A name or a few names before ": ", not a sentence or a link that happens to contain a colon.</summary>
    private static bool IsOwner(string owner, string rest) =>
        rest.Length > 0 && char.IsWhiteSpace(rest[0])
        && owner.Length is > 0 and <= 60
        && owner.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length <= 4
        && !owner.Any(c => char.IsDigit(c) || c is '/' or '@')
        && !Domain().IsMatch(owner);

    private static string Clean(string text) => text.Replace("**", "").Trim();

    [GeneratedRegex(@"\.\p{L}{2,}")]
    private static partial Regex Domain();
}
