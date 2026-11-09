using System.Text;
using System.Text.Json.Nodes;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Calls;

public enum TranscriptEditFailure { BadName, NotFound }

public sealed class TranscriptEditException(TranscriptEditFailure failure) : Exception(failure.ToString())
{
    public TranscriptEditFailure Failure { get; } = failure;
}

/// <summary>
/// Edits of transcript.md and transcript.txt, written atomically. summary.md is not regenerated.
/// </summary>
public static class TranscriptEdit
{
    public static readonly string[] Files = ["transcript.md", "transcript.txt"];
    private const string TracksKey = "speaker_tracks";

    /// <summary>Renames a speaker in both files and in call.json <c>names</c>. Whether anything changed.</summary>
    public static bool RenameSpeaker(string dir, string from, string newName)
    {
        var to = Transcript.CleanSpeaker(newName) ?? throw new TranscriptEditException(TranscriptEditFailure.BadName);
        if (to == from) return false;
        var newSpeaks = Speaks(to, dir);
        Rewrite(dir, text => Transcript.RenameSpeaker(text, from, to));
        if (CallFile.Exists(dir))
        {
            CallFile.Edit(dir, c =>
            {
                var tracksChanged = MoveTrack(c, from, to, newSpeaks, keepOld: false);
                if (c.Texts("names") is not { } names || !names.Contains(from)) return tracksChanged;
                c["names"] = names.Select(n => n == from ? to : n).Distinct().ToJsonArray();
                return true;
            });
        }
        return true;
    }

    /// <summary>Swaps two speakers in both files and in call.json <c>names</c>. Whether anything changed.</summary>
    public static bool SwapSpeakers(string dir, string a, string b)
    {
        if (a == b) return false;
        Rewrite(dir, text => Transcript.SwapSpeakers(text, a, b));
        if (CallFile.Exists(dir))
        {
            CallFile.Edit(dir, c =>
            {
                var tracksChanged = SwapTracks(c, a, b);
                if (c.Texts("names") is not { } names || (!names.Contains(a) && !names.Contains(b))) return tracksChanged;
                c["names"] = names.Select(n => n == a ? b : n == b ? a : n).ToJsonArray();
                return true;
            });
        }
        return true;
    }

    /// <summary>Gives one line to another speaker in both files. Whether anything changed.</summary>
    public static bool ReassignLine(string dir, TranscriptLine line, int occurrence, string newName)
    {
        var to = Transcript.CleanSpeaker(newName) ?? throw new TranscriptEditException(TranscriptEditFailure.BadName);
        if (to == line.Speaker) return false;
        var newSpeaks = Speaks(to, dir);
        RewriteOptional(dir, text => Transcript.Reassign(text, line, occurrence, to));
        if (CallFile.Read(dir).ContainsKey(TracksKey))
            CallFile.Edit(dir, c => MoveTrack(c, line.Speaker, to, newSpeaks, keepOld: true));
        return true;
    }

    /// <summary>Fixes a word or phrase in one line of both files.</summary>
    public static bool FixWord(string dir, TranscriptLine line, int occurrence, string wrong, string replacement)
    {
        var right = replacement.Trim();
        if (wrong.Length == 0 || right.Length == 0 || right.Contains('\n'))
            throw new TranscriptEditException(TranscriptEditFailure.BadName);
        RewriteOptional(dir, text => Transcript.Fix(text, line, occurrence, wrong, right));
        return true;
    }

    private static void Rewrite(string dir, Func<string, string> edit)
    {
        RewriteOptional(dir, text => edit(text) is var result && result != text ? result : null);
    }

    private static void RewriteOptional(string dir, Func<string, string?> edit)
    {
        var changed = false;
        foreach (var file in Files)
        {
            var path = Path.Combine(dir, file);
            if (SharedFile.ReadText(path) is not { } text || edit(text) is not { } result) continue;
            AtomicFile.Write(path, new UTF8Encoding(false).GetBytes(result));
            changed = true;
        }
        if (!changed) throw new TranscriptEditException(TranscriptEditFailure.NotFound);
    }

    private static bool Speaks(string speaker, string dir) =>
        SharedFile.ReadText(Path.Combine(dir, "transcript.txt")) is { } text
        && Transcript.Lines(text).Any(l => l.Speaker == speaker);

    private static Dictionary<string, string>? Tracks(JsonObject c)
    {
        if (c.Object(TracksKey) is not { } o) return null;
        var tracks = new Dictionary<string, string>();
        foreach (var (label, _) in o)
        {
            if (o.Text(label) is not { } track) return null;
            tracks[label] = track;
        }
        return tracks;
    }

    private static void Store(JsonObject c, Dictionary<string, string> tracks)
    {
        var o = new JsonObject();
        foreach (var (label, track) in tracks) o[label] = track;
        c[TracksKey] = o;
    }

    private static bool SwapTracks(JsonObject c, string a, string b)
    {
        if (Tracks(c) is not { } tracks || tracks.GetValueOrDefault(a) == tracks.GetValueOrDefault(b)) return false;
        var (first, second) = (tracks.GetValueOrDefault(a), tracks.GetValueOrDefault(b));
        Assign(tracks, a, second);
        Assign(tracks, b, first);
        Store(c, tracks);
        return true;
    }

    /// <summary>Lines from two tracks under one label make it "both"; an unknown track stays unknown.</summary>
    private static bool MoveTrack(JsonObject c, string from, string to, bool newSpeaks, bool keepOld)
    {
        if (Tracks(c) is not { } tracks) return false;
        var before = new Dictionary<string, string>(tracks);
        var source = tracks.GetValueOrDefault(from);
        var target = newSpeaks ? tracks.GetValueOrDefault(to) : source;
        if (!keepOld) tracks.Remove(from);
        Assign(tracks, to, source == target ? source : source is null || target is null ? null : "both");
        if (tracks.Count == before.Count && !tracks.Except(before).Any()) return false;
        Store(c, tracks);
        return true;
    }

    private static void Assign(Dictionary<string, string> tracks, string label, string? track)
    {
        if (track is null) tracks.Remove(label);
        else tracks[label] = track;
    }
}

public enum ReplacementFailure { Empty, NoProject, Corrupt }

public sealed class ReplacementException(ReplacementFailure failure) : Exception(failure.ToString())
{
    public ReplacementFailure Failure { get; } = failure;
}

/// <summary>
/// Auto-replacements the engine applies to new transcripts, in profiles/&lt;slug&gt;.json or the shared vocab.json,
/// by the engine's rule: an entry with the same left side, ignoring case, gets the new right side.
/// </summary>
public static class ReplacementStore
{
    /// <summary>Adds to a project, which must exist, or with an empty slug to the shared vocabulary.</summary>
    public static void Add(string wrong, string right, string slug, string dataFolder)
    {
        if (slug.Length == 0)
        {
            Add(wrong, right, Path.Combine(dataFolder, "vocab.json"), create: true);
            return;
        }
        if (!Project.IsValidSlug(slug)) throw new ReplacementException(ReplacementFailure.NoProject);
        Add(wrong, right, Path.Combine(dataFolder, "profiles", slug + ".json"), create: false);
    }

    public static void Add(string wrong, string right, string file, bool create)
    {
        var (w, r) = (wrong.Trim(), right.Trim());
        if (w.Length == 0 || r.Length == 0) throw new ReplacementException(ReplacementFailure.Empty);
        if (!create && !File.Exists(file)) throw new ReplacementException(ReplacementFailure.NoProject);
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        FileLock.With(file, () =>
        {
            var o = JsonFile.Read(file, out var exists);
            if (exists && o is null) throw new ReplacementException(ReplacementFailure.Corrupt);
            if (!exists && !create) throw new ReplacementException(ReplacementFailure.NoProject);
            o ??= [];
            o["schema"] = 1;
            o["replacements"] = Set(o["replacements"] as JsonArray ?? [], w, r);
            JsonFile.WriteAtomic(file, o);
            return true;
        });
    }

    internal static JsonArray Set(JsonArray existing, string wrong, string right)
    {
        static string Key(string s) => s.Trim().ToLowerInvariant();
        var result = new JsonArray();
        var found = false;
        foreach (var entry in existing)
        {
            if (entry is JsonArray { Count: 2 } pair && pair[0]?.GetValueKind() == System.Text.Json.JsonValueKind.String
                && pair[1]?.GetValueKind() == System.Text.Json.JsonValueKind.String
                && pair[0]!.GetValue<string>().Length > 0 && pair[1]!.GetValue<string>().Length > 0
                && Key(pair[0]!.GetValue<string>()) == Key(wrong))
            {
                if (!found) result.Add(new JsonArray(wrong, right));
                found = true;
                continue;
            }
            result.Add(entry?.DeepClone());
        }
        if (!found) result.Add(new JsonArray(wrong, right));
        return result;
    }
}
