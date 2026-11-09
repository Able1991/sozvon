using System.Text.Json.Nodes;
using Sozvon.Core.Engine;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Calls;

/// <summary>The queue in call.json: <c>queued_at</c> while waiting, <c>retries</c> for a run interrupted by a crash.</summary>
public static partial class CallFile
{
    public const string QueuedAtKey = "queued_at";
    public const string QueuedSummaryOnlyKey = "queued_summary_only";
    public const string RetriesKey = "retries";

    /// <summary>A run interrupted by a crash goes back in the queue this many times, then the call is failed.</summary>
    public const int MaxRetries = 1;

    /// <summary>When the call entered the queue; null if it is not waiting or the field is broken.</summary>
    public static DateTimeOffset? QueuedAt(JsonObject c) => Iso8601.Parse(c.Text(QueuedAtKey));

    /// <summary>A time: the call starts waiting. Null: it started or was taken out of the queue.</summary>
    public static bool SetQueued(string dir, DateTimeOffset? at, bool summaryOnly = false) => Update(dir, c =>
    {
        c.Remove(QueuedSummaryOnlyKey);
        if (at is { } time)
        {
            c[QueuedAtKey] = Iso8601.Milliseconds(time);
            if (summaryOnly) c[QueuedSummaryOnlyKey] = true;
        }
        else
        {
            c.Remove(QueuedAtKey);
        }
    });

    /// <summary>The run ended by itself, or the user asked for a new one: the next interruption gets its retry again.</summary>
    public static bool ClearRetries(string dir) => Update(dir, c => c.Remove(RetriesKey));

    /// <summary>
    /// At launch: what goes back in the queue, in order. A call left processing by a crash is requeued
    /// <see cref="MaxRetries"/> times and goes first, because it was already running; after that it is failed, so a
    /// call that kills the app cannot do so forever.
    /// </summary>
    public static List<ProcessingJob> RecoverQueue(string root, DateTimeOffset? now = null)
    {
        var interrupted = new List<ProcessingJob>();
        var waiting = new List<(DateTimeOffset At, ProcessingJob Job)>();
        foreach (var dir in Folders(root))
        {
            if (!Exists(dir)) continue;
            var call = Read(dir);
            if (call.Text("status") == CallStatus.Processing.Key())
            {
                if (Requeue(dir, call.Int(RetriesKey) ?? 0, now ?? DateTimeOffset.UtcNow))
                    interrupted.Add(new ProcessingJob(dir, ProcessingKind.Transcribe));
            }
            else if (QueuedAt(call) is { } at)
            {
                var kind = call.Flag(QueuedSummaryOnlyKey) == true ? ProcessingKind.SummaryOnly : ProcessingKind.Transcribe;
                waiting.Add((at, new ProcessingJob(dir, kind)));
            }
        }
        waiting.Sort((a, b) => a.At != b.At ? a.At.CompareTo(b.At) : string.CompareOrdinal(a.Job.Dir, b.Job.Dir));
        return interrupted.Concat(waiting.Select(w => w.Job)).ToList();
    }

    private static bool Requeue(string dir, int retries, DateTimeOffset now)
    {
        if (retries >= MaxRetries)
        {
            Update(dir, c =>
            {
                c["status"] = CallStatus.Failed.Key();
                c.Remove(QueuedAtKey);
                c.Remove(QueuedSummaryOnlyKey);
            });
            return false;
        }
        // No longer processing while it waits: a second crash before its turn must not use up the retry.
        Update(dir, c =>
        {
            c[RetriesKey] = retries + 1;
            c["status"] = CallStatus.Recorded.Key();
            c[QueuedAtKey] = Iso8601.Milliseconds(now);
            c.Remove(QueuedSummaryOnlyKey);
        });
        return true;
    }

    /// <summary>Subfolders of the calls folder, in name order.</summary>
    internal static IEnumerable<string> Folders(string root)
    {
        if (!Directory.Exists(root)) return [];
        try
        {
            return Directory.GetDirectories(root).OrderBy(d => d, StringComparer.Ordinal);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }
}
