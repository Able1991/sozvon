using System.Text.Json.Nodes;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Calls;

public enum CallNoteFailure { Empty, TooLong, TooMany, Corrupt }

public sealed class CallNoteException(CallNoteFailure failure) : Exception(failure.ToString())
{
    public CallNoteFailure Failure { get; } = failure;
}

/// <summary>A note on a call, added by an assistant over MCP or in the Calls window. Append-only.</summary>
public sealed record CallNote(string Id, string At, string Text, string Source)
{
    public DateTimeOffset? Date => Iso8601.Parse(At);

    internal JsonObject ToJson() => new() { ["id"] = Id, ["at"] = At, ["text"] = Text, ["source"] = Source };

    /// <summary>A valid note from call.json, by the engine's rule; null for anything else.</summary>
    internal static CallNote? From(JsonNode? node)
    {
        if (node is not JsonObject o || o.Text("id") is not { } id || !CallNotes.ValidId(id)) return null;
        if (o.Text("at") is not { } at || at.Trim().Length == 0 || at.Length > 40) return null;
        if (o.Text("text") is not { } text || text.Trim().Length == 0 || CallNotes.CodePoints(text) > CallNotes.MaxText) return null;
        var source = o.Text("source") ?? "";
        return new CallNote(id, at, text, source.Length is 0 or > 40 ? "assistant" : source);
    }
}

/// <summary>Notes in call.json (contract section 4).</summary>
public static class CallNotes
{
    public const int MaxText = 4000;
    public const int MaxNotes = 200;
    public const string DeletedKey = "notes_deleted";

    /// <summary>Valid notes, each id once, oldest first.</summary>
    public static List<CallNote> List(JsonObject call)
    {
        if (call["notes"] is not JsonArray raw) return [];
        var seen = new HashSet<string>();
        return raw.Select(CallNote.From).OfType<CallNote>().Where(n => seen.Add(n.Id))
                  .OrderBy(n => n.At, StringComparer.Ordinal).ToList();
    }

    /// <summary>Ids of deleted notes, the tombstones sync carries to the server.</summary>
    public static List<string> Deleted(JsonObject call)
    {
        if (call[DeletedKey] is not JsonArray raw) return [];
        var seen = new HashSet<string>();
        return raw.OfType<JsonValue>().Select(v => v.TryGetValue<string>(out var s) ? s : null)
                  .OfType<string>().Where(id => ValidId(id) && seen.Add(id)).ToList();
    }

    public static List<CallNote> Read(string dir) => List(CallFile.Read(dir));

    /// <summary>Appends a note under the call.json lock. A broken call.json is left alone.</summary>
    public static CallNote Add(string text, string dir, string source = "app", DateTimeOffset? now = null)
    {
        var body = text.Trim();
        if (body.Length == 0) throw new CallNoteException(CallNoteFailure.Empty);
        if (CodePoints(body) > MaxText) throw new CallNoteException(CallNoteFailure.TooLong);
        var note = new CallNote(Guid.NewGuid().ToString(), Iso8601.Seconds(now ?? DateTimeOffset.UtcNow), body, source);
        Editing(dir, c =>
        {
            var have = List(c);
            if (have.Count >= MaxNotes) throw new CallNoteException(CallNoteFailure.TooMany);
            c["notes"] = ToJson(have.Append(note));
            return true;
        });
        return note;
    }

    /// <summary>Deletes a note: its id goes to <c>notes_deleted</c>, so no copy brings it back. Whether it was there.</summary>
    public static bool Delete(string id, string dir) => Editing(dir, c =>
    {
        var have = List(c);
        if (have.All(n => n.Id != id)) return false;
        c["notes"] = ToJson(have.Where(n => n.Id != id));
        var gone = Deleted(c);
        if (!gone.Contains(id)) gone.Add(id);
        c[DeletedKey] = gone.ToJsonArray();
        return true;
    });

    internal static bool ValidId(string id) => id.Length is > 0 and <= 64 && id.All(ch => char.IsAsciiLetterOrDigit(ch) || ch == '-');

    internal static int CodePoints(string text) => text.EnumerateRunes().Count();

    private static JsonArray ToJson(IEnumerable<CallNote> notes) => new(notes.Select(n => (JsonNode?)n.ToJson()).ToArray());

    private static bool Editing(string dir, Func<JsonObject, bool> change)
    {
        try
        {
            return CallFile.Edit(dir, change);
        }
        catch (CallFileCorruptException)
        {
            throw new CallNoteException(CallNoteFailure.Corrupt);
        }
    }
}

public enum CallWarningStep { Summary, Names }

public sealed record CallWarning(CallWarningStep Step, string Error);

/// <summary>call.json <c>warnings</c>: steps that failed on the engine's last run although the call is done.</summary>
public static class CallWarnings
{
    public const string Key = "warnings";

    public static List<CallWarning> List(JsonObject c)
    {
        if (c[Key] is not JsonArray raw) return [];
        var list = new List<CallWarning>();
        foreach (var o in raw.OfType<JsonObject>())
        {
            CallWarningStep? step = o.Text("step") switch
            {
                "summary" => CallWarningStep.Summary,
                "names" => CallWarningStep.Names,
                _ => null,
            };
            if (step is { } known) list.Add(new CallWarning(known, o.Text("error") ?? ""));
        }
        return list;
    }

    /// <summary>Why the summary failed on the last run, on one line; null when it did not.</summary>
    public static string? Summary(JsonObject c) =>
        List(c).FirstOrDefault(w => w.Step == CallWarningStep.Summary) is { } warning ? TextRules.Squeeze(warning.Error) : null;
}
