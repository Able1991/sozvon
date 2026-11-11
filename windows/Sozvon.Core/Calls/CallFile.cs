using System.Text.Json.Nodes;
using Sozvon.Core.Foundation;
using Sozvon.Core.Settings;

namespace Sozvon.Core.Calls;

/// <summary>call.json exists but is not a JSON object: left for the user, never overwritten.</summary>
public sealed class CallFileCorruptException(string path) : IOException($"not a JSON object: {path}");

/// <summary>
/// call.json: metadata and the permanent call id. Every read-modify-write runs under the <c>call.json.lock</c> the
/// engine takes too, and the file is replaced atomically, keeping every field this code does not know.
/// </summary>
public static partial class CallFile
{
    public const int Schema = 1;
    public const string Name = "call.json";
    public const string LockName = "call.json.lock";
    public const string PendingKey = "info_pending";

    public static string PathIn(string dir) => Path.Combine(dir, Name);

    public static bool Exists(string dir) => File.Exists(PathIn(dir));

    public static JsonObject Read(string dir) => JsonFile.Read(PathIn(dir)) ?? [];

    /// <summary>The permanent id: from call.json, otherwise from the folder name.</summary>
    public static string CallId(string dir) =>
        Read(dir).Text("id") is { Length: > 0 } id ? id : CallFolder.IdFromName(Path.GetFileName(dir));

    /// <summary>
    /// Read-modify-write under the lock. <paramref name="change"/> returns whether to write; a throw writes nothing.
    /// Strict: an existing call.json that is not a JSON object is never replaced. A folder that is gone is never recreated.
    /// A call.json that is there but cannot be read (another program holds it) is never taken for a missing one.
    /// </summary>
    public static bool Edit(string dir, Func<JsonObject, bool> change, bool strict = true)
    {
        if (!Directory.Exists(dir)) throw new DirectoryNotFoundException(dir);
        var file = PathIn(dir);
        return FileLock.With(file, () =>
        {
            var call = JsonFile.Read(file, out var exists);
            if (!exists && File.Exists(file)) throw new IOException($"cannot read {file}");
            if (call is null && exists && strict) throw new CallFileCorruptException(file);
            call ??= [];
            if (!change(call)) return false;
            PutSchemaFirst(call);
            JsonFile.WriteAtomic(file, call);
            return true;
        });
    }

    /// <summary>Like <see cref="Edit"/>, not strict. False when the write failed.</summary>
    public static bool Update(string dir, Action<JsonObject> change)
    {
        try
        {
            return Edit(dir, c =>
            {
                change(c);
                return true;
            }, strict: false);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>On recording stop: schema, id, start time, tracks, "recorded" status.</summary>
    public static bool RecordStopped(string dir, DateTimeOffset startedAt, AudioTimes audio) => Update(dir, c =>
    {
        c["schema"] = Schema;
        EnsureId(c, dir);
        c["created_at"] = Iso8601.Seconds(startedAt);
        c["audio"] = audio.ToJson();
        c["status"] = CallStatus.Recorded.Key();
    });

    /// <summary>Everything written right after a recording stops. False if any write failed.</summary>
    public static bool SaveStopped(string dir, DateTimeOffset startedAt, AudioTimes audio, CallInfo info)
    {
        var stopped = RecordStopped(dir, startedAt, audio);
        var answers = WriteInfo(dir, info);
        return stopped && answers;
    }

    /// <summary>Answers from "What was the call about?": the engine reads them from call.json, not from arguments.</summary>
    public static bool WriteInfo(string dir, CallInfo info) => Update(dir, c =>
    {
        EnsureId(c, dir);
        Apply(info, c);
    });

    public static void Apply(CallInfo info, JsonObject c)
    {
        c["schema"] = Schema;
        c["profile"] = info.Profile;
        c["names"] = TextRules.SplitList(info.Names).ToJsonArray();
        c["topic"] = info.Topic.Trim();
        c["terms"] = info.Terms.Trim();
        c["languages"] = SpeechLanguages.Serialize(info.Languages.ToList());
        c["summary"] = info.Summary;
        if (info.Reflection) c["kind"] = "reflection"; else c.Remove("kind");
    }

    public static bool SetStatus(string dir, CallStatus status) => Update(dir, c => c["status"] = status.Key());

    /// <summary>A run stopped or died: failed, unless the engine had already finished the call.</summary>
    public static bool SetFailedUnlessDone(string dir) => Update(dir, c =>
    {
        if (c.Text("status") != CallStatus.Done.Key()) c["status"] = CallStatus.Failed.Key();
    });

    /// <summary>"Later" in the call prompt. False removes the field: it is never written as false.</summary>
    public static bool SetInfoPending(string dir, bool pending) => Update(dir, c =>
    {
        if (pending) c[PendingKey] = true; else c.Remove(PendingKey);
    });

    /// <summary>Answers from call.json. A missing field keeps the value of <paramref name="fallback"/>.</summary>
    public static CallInfo Info(JsonObject c, CallInfo? fallback = null)
    {
        var info = (fallback ?? new CallInfo()) with { };
        if (c.Text("profile") is { } profile) info.Profile = profile;
        if (c.Texts("names") is { } names) info.Names = string.Join(", ", names);
        else if (c.Text("names") is { } text) info.Names = text;
        if (c.Text("topic") is { } topic) info.Topic = topic;
        if (c.Text("terms") is { } terms) info.Terms = terms;
        if (c.Text("languages") is { } languages) info.Languages = SpeechLanguages.Parse(languages);
        if (c.Flag("summary") is { } summary) info.Summary = summary;
        info.Reflection = c.Text("kind") == "reflection";
        return info;
    }

    private static void EnsureId(JsonObject c, string dir)
    {
        if (string.IsNullOrEmpty(c.Text("id"))) c["id"] = CallFolder.IdFromName(Path.GetFileName(dir));
    }

    private static void PutSchemaFirst(JsonObject c)
    {
        if (!c.TryGetPropertyValue("schema", out var schema) || c.GetPropertyName(0) == "schema") return;
        c.Remove("schema");
        c.Insert(0, "schema", schema);
    }

    private static string GetPropertyName(this JsonObject c, int index) => c.GetAt(index).Key;
}
