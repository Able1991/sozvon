namespace Sozvon.Core.Calls;

/// <summary>The project and reflections filter of the Calls list.</summary>
public static class CallFilter
{
    /// <summary>The filter's choice for reflections instead of a project: a tag no project slug can have.</summary>
    public const string Reflections = "\0reflections";

    public static bool Matches(Call call, string filter) =>
        filter == Reflections ? call.Info.Reflection : call.Info.Profile == filter;

    /// <summary>In the filtered project, or the live call, which is shown under "Now" whatever the filter.</summary>
    public static bool IsShown(Call call, string filter, bool isLive) =>
        filter.Length == 0 || Matches(call, filter) || isLive;

    public static List<Call> Apply(IEnumerable<Call> calls, string filter) =>
        (filter.Length == 0 ? calls : calls.Where(c => Matches(c, filter))).ToList();
}

/// <summary>Day groups of the Calls list.</summary>
public static class CallDays
{
    public sealed record Labels(string Today, string Yesterday, string Undated, Func<DateTimeOffset, string> Format);

    /// <summary>Groups by local day in the order of first appearance.</summary>
    public static List<(string Title, List<Call> Calls)> Group(IEnumerable<Call> calls, DateTimeOffset now, Labels labels)
    {
        var groups = new List<(string Title, List<Call> Calls)>();
        var today = now.ToLocalTime().Date;
        foreach (var call in calls)
        {
            var title = call.Date is not { } date ? labels.Undated
                : date.ToLocalTime().Date == today ? labels.Today
                : date.ToLocalTime().Date == today.AddDays(-1) ? labels.Yesterday
                : labels.Format(date);
            var index = groups.FindIndex(g => g.Title == title);
            if (index >= 0) groups[index].Calls.Add(call);
            else groups.Add((title, [call]));
        }
        return groups;
    }
}
