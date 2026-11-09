using System.Text.Json.Nodes;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Calls;

/// <summary>
/// Who took part. <c>names</c> holds only what the user typed; <c>participants</c> is derived from the transcript by
/// the engine and, after a transcript edit, here. The same rule as the engine's names.participants
/// (Tests/Fixtures/participants.json).
/// </summary>
public static class CallParticipants
{
    public const string Key = "participants";

    /// <summary>Every speaker that names a person in speaking order, then the typed names that never spoke.</summary>
    public static List<string> Derived(IEnumerable<string> typed, IReadOnlyList<string> speakers, string me)
    {
        var all = new List<string>();
        var seen = new HashSet<string>();
        foreach (var raw in speakers.Concat(typed))
        {
            var name = TextRules.Squeeze(raw);
            if (!Voices.IsGenericLabel(name, me) && seen.Add(name.ToLowerInvariant())) all.Add(name);
        }
        var spoken = speakers.Select(s => TextRules.Squeeze(s).ToLowerInvariant()).ToHashSet();
        return all.Where(n => !Folded(n, all, spoken)).ToList();
    }

    public static List<string> Typed(JsonObject c) => c.Texts("names") ?? TextRules.SplitList(c.Text("names") ?? "");

    public static List<string>? Stored(JsonObject c) => c.Texts(Key);

    public static List<string> List(JsonObject c) => Stored(c) ?? Typed(c);

    /// <summary>The speakers of the call's transcript, in transcript order.</summary>
    public static List<string> Speakers(string dir)
    {
        foreach (var name in TranscriptEdit.Files.Reverse())
        {
            if (SharedFile.ReadText(Path.Combine(dir, name)) is { } text)
                return Transcript.Lines(text).Select(l => l.Speaker).ToList();
        }
        return [];
    }

    /// <summary>After a user edit of the transcript: <c>participants</c> recomputed. Whether call.json changed.</summary>
    public static bool Update(string dir, string me)
    {
        if (!CallFile.Exists(dir)) return false;
        var speakers = Speakers(dir);
        if (speakers.Count == 0) return false;
        return CallFile.Edit(dir, c =>
        {
            var all = Derived(Typed(c), speakers, me);
            if (Stored(c) is { } stored && stored.SequenceEqual(all)) return false;
            c[Key] = all.ToJsonArray();
            return true;
        });
    }

    /// <summary>A typed single first name that is the first word of exactly one speaking name is that person.</summary>
    private static bool Folded(string name, List<string> all, HashSet<string> spoken)
    {
        var low = name.ToLowerInvariant();
        if (spoken.Contains(low) || name.Contains(' ')) return false;
        return all.Count(n => spoken.Contains(n.ToLowerInvariant()) && n.ToLowerInvariant().Split(' ')[0] == low) == 1;
    }
}
