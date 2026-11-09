using System.Text.Json.Nodes;
using Sozvon.Core.Foundation;

namespace Sozvon.Core.Calls;

public sealed record PendingCall(string Dir, string Id, DateTimeOffset? Date);

/// <summary>Calls waiting for their description ("Later" in "What was the call about?").</summary>
public static class PendingInfo
{
    /// <summary>The flag is set and the call has not been transcribed some other way.</summary>
    public static bool IsPending(JsonObject c) =>
        c.Flag(CallFile.PendingKey) == true && c.Text("status") == CallStatus.Recorded.Key();

    /// <summary>Pending calls in the folder, oldest first.</summary>
    public static List<PendingCall> All(string root)
    {
        var pending = new List<PendingCall>();
        foreach (var dir in CallFile.Folders(root))
        {
            if (!CallFile.Exists(dir)) continue;
            var c = CallFile.Read(dir);
            if (!IsPending(c)) continue;
            var id = c.Text("id") is { Length: > 0 } stored ? stored : CallFolder.IdFromName(Path.GetFileName(dir));
            pending.Add(new PendingCall(dir, id, Call.ParseId(id)));
        }
        pending.Sort((a, b) =>
        {
            var byDate = Nullable.Compare(a.Date, b.Date);
            return byDate != 0 ? byDate : string.Compare(a.Id, b.Id, System.Globalization.CultureInfo.InvariantCulture,
                                                         System.Globalization.CompareOptions.NumericOrdering);
        });
        return pending;
    }
}

/// <summary>When to remind about pending calls: after 10 idle minutes, at most once an hour per call.</summary>
public sealed class ReminderPlanner(DateTimeOffset now)
{
    public static readonly TimeSpan IdleDelay = TimeSpan.FromMinutes(10);
    public static readonly TimeSpan RepeatEvery = TimeSpan.FromHours(1);

    private readonly Dictionary<string, DateTimeOffset> _reminded = [];

    /// <summary>Idle since; null while busy.</summary>
    public DateTimeOffset? IdleSince { get; private set; } = now;

    public void Activity(bool busy, DateTimeOffset at)
    {
        if (busy) IdleSince = null;
        else IdleSince ??= at;
    }

    /// <summary>Calls to remind about now, oldest first, remembering the time.</summary>
    public List<PendingCall> Due(IReadOnlyList<PendingCall> pending, DateTimeOffset at, bool busy)
    {
        Activity(busy, at);
        var ids = pending.Select(p => p.Id).ToHashSet();
        foreach (var gone in _reminded.Keys.Where(k => !ids.Contains(k)).ToList()) _reminded.Remove(gone);
        if (busy || IdleSince is not { } since || at - since < IdleDelay) return [];
        var due = pending.Where(p => !_reminded.TryGetValue(p.Id, out var last) || at - last >= RepeatEvery).ToList();
        foreach (var p in due) _reminded[p.Id] = at;
        return due;
    }
}
