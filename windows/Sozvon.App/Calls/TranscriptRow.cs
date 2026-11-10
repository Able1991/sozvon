using CommunityToolkit.Mvvm.ComponentModel;
using Sozvon.Core.Calls;

namespace Sozvon.App.Calls;

/// <summary>
/// One transcript paragraph as the card shows it: its time, speaker and text without the engine's star, and what
/// the find bar and the player mark on it.
/// </summary>
public sealed partial class TranscriptRow(TranscriptLine line, int ordinal, int occurrence, bool unconfirmed, bool voiced) : ObservableObject
{
    public TranscriptLine Line { get; } = line;

    /// <summary>The paragraph's number in the transcript.</summary>
    public int Ordinal { get; } = ordinal;

    /// <summary>How many equal paragraphs come before this one: edits find the line by it.</summary>
    public int Occurrence { get; } = occurrence;

    public string Time => CallFormat.Clock(Line.Start);

    public string Speaker => Line.Speaker;

    public string Text => IsStarred ? Line.Text[..^TranscriptFind.Star.Length] : Line.Text;

    /// <summary>Marked as important during the recording.</summary>
    public bool IsStarred => Line.Text.EndsWith(TranscriptFind.Star, StringComparison.Ordinal);

    /// <summary>A named speaker whose voice is not saved yet: the name is coral, so it is clear whom to confirm.</summary>
    public bool IsUnconfirmed { get; } = unconfirmed;

    /// <summary>The speaker's voice is saved: Sozvon recognises them in the next calls.</summary>
    public bool IsVoiced { get; } = voiced;

    /// <summary>The call has audio: a click plays from this line.</summary>
    public bool CanPlay { get; set; }

    /// <summary>Not being recorded or transcribed: the line can be renamed or fixed.</summary>
    public bool CanEdit { get; set; }

    /// <summary>Matches of the open find bar in this paragraph.</summary>
    [ObservableProperty] public partial IReadOnlyList<TranscriptFind.Match> Found { get; set; } = [];

    /// <summary>The current match when it is in this paragraph.</summary>
    [ObservableProperty] public partial TranscriptFind.Match? CurrentFound { get; set; }

    /// <summary>The player is in this paragraph.</summary>
    [ObservableProperty] public partial bool IsPlaying { get; set; }

    /// <summary>Paragraphs of transcript.txt; speakers without a saved voice are worked out once for the whole call.</summary>
    public static List<TranscriptRow> Parse(string transcript, IReadOnlyCollection<string> unsaved, string me)
    {
        var rows = new List<TranscriptRow>();
        var seen = new Dictionary<TranscriptLine, int>();
        foreach (var line in Transcript.Lines(transcript))
        {
            var occurrence = seen.GetValueOrDefault(line);
            seen[line] = occurrence + 1;
            var unconfirmed = unsaved.Contains(line.Speaker.Trim());
            var voiced = !unconfirmed && !Voices.IsGenericLabel(line.Speaker, me);
            rows.Add(new TranscriptRow(line, rows.Count, occurrence, unconfirmed, voiced));
        }
        return rows;
    }

    /// <summary>"[0:42] Anna: text", for Copy.</summary>
    public override string ToString() => $"[{Time}] {Speaker}: {Line.Text}";
}
