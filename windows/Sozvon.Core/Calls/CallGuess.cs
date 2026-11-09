using Sozvon.Core.Foundation;

namespace Sozvon.Core.Calls;

public sealed record CalendarAttendee(string Name, string Email = "", bool IsMe = false);

public sealed record CalendarEvent(string Title, DateTimeOffset Start, DateTimeOffset End, bool IsAllDay = false,
                                   IReadOnlyList<CalendarAttendee>? AttendeeList = null, bool HasCallLink = false)
{
    public IReadOnlyList<CalendarAttendee> Attendees => AttendeeList ?? [];
}

/// <summary>The calendar event of a recording: pure matching, the app reads the events.</summary>
public static class CalendarMatch
{
    public static readonly TimeSpan Slack = TimeSpan.FromMinutes(15);

    public static readonly IReadOnlyList<string> CallHosts =
    [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "telemost.yandex", "whereby.com",
        "webex.com", "jitsi", "meet.jit.si", "skype.com",
    ];

    public static bool HasCallLink(IEnumerable<string> texts) =>
        texts.Any(t => CallHosts.Any(h => t.Contains(h, StringComparison.OrdinalIgnoreCase)));

    /// <summary>The event the recording most likely belongs to: a call link first, then attendees, then the closest start.</summary>
    public static CalendarEvent? Best(IEnumerable<CalendarEvent> events, DateTimeOffset recordingStart) =>
        events.Where(e => !e.IsAllDay && e.Start - Slack <= recordingStart && recordingStart <= e.End + Slack
                          && e.End - e.Start <= TimeSpan.FromHours(8))
              .OrderBy(e => e.HasCallLink ? 0 : 1)
              .ThenBy(e => e.Attendees.Any(a => !a.IsMe) ? 0 : 1)
              .ThenBy(e => Math.Abs((e.Start - recordingStart).TotalSeconds))
              .FirstOrDefault();

    /// <summary>Attendee names without the user: a bare email becomes its local part.</summary>
    public static List<string> People(CalendarEvent e)
    {
        var people = new List<string>();
        foreach (var attendee in e.Attendees.Where(a => !a.IsMe))
        {
            var name = attendee.Name.Trim();
            if (name.Length == 0 || name.Contains('@'))
                name = (name.Contains('@') ? name : attendee.Email).Split('@')[0];
            if (name.Length > 0 && !people.Contains(name)) people.Add(name);
        }
        return people;
    }

    /// <summary>The project title in the event title wins, then the most attendees known in a project.</summary>
    public static Project? ProjectFor(CalendarEvent e, IReadOnlyList<Project> projects)
    {
        var title = e.Title.ToLowerInvariant();
        var named = projects.FirstOrDefault(p => new[] { p.Title, p.ShortTitle }
            .Any(t => t.Length >= 3 && title.Contains(t.ToLowerInvariant(), StringComparison.Ordinal)));
        if (named is not null) return named;

        static string First(string s) => s.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToLowerInvariant() ?? "";
        var names = People(e).Select(First).Where(n => n.Length > 0).ToHashSet();
        if (names.Count == 0) return null;
        Project? best = null;
        var bestScore = 0;
        foreach (var project in projects)
        {
            var score = project.People.Select(First).Where(names.Contains).Distinct().Count();
            if (score > 0 && score >= bestScore) (best, bestScore) = (project, score);
        }
        return best;
    }

    /// <summary>Topic and participants only where empty; the project when the user typed neither.</summary>
    public static CallInfo Fill(CallInfo info, CalendarEvent e, IReadOnlyList<Project> projects)
    {
        var result = info with { };
        var untouched = info.Topic.Trim().Length == 0 && info.Names.Trim().Length == 0;
        if (result.Topic.Trim().Length == 0) result.Topic = e.Title.Trim();
        if (result.Names.Trim().Length == 0) result.Names = string.Join(", ", People(e));
        if (untouched && ProjectFor(e, projects) is { } project) result.Profile = project.Slug;
        return result;
    }
}

/// <summary>Someone the live voice match heard during the recording.</summary>
public sealed record HeardVoice(string Name, string Profile = "", double Seconds = 0, bool Unsure = false);

/// <summary>After a recording: project and participants from what Sozvon already knows, and whether to ask.</summary>
public static class CallGuess
{
    /// <summary>Seconds the form waits before transcribing by itself.</summary>
    public const int FormCountdown = 10;

    /// <summary>Heard this long, a voice is enough to transcribe without asking.</summary>
    public const double SureSeconds = 30;

    /// <summary>A recording may start this long before the meeting and still be that meeting.</summary>
    public static readonly TimeSpan SureEarly = TimeSpan.FromMinutes(5);

    /// <param name="defaultProfile">The last used project the form starts with: it says nothing about this call.</param>
    public static (CallInfo Info, bool Sure) Fill(CallInfo info, string defaultProfile, DateTimeOffset startedAt, CalendarEvent? calendarEvent,
                                                  IReadOnlyList<HeardVoice> heard, IReadOnlyList<Project> projects)
    {
        var baseInfo = info with { };
        if (baseInfo.Profile == defaultProfile) baseInfo.Profile = "";
        var typedProfile = baseInfo.Profile;
        var typedNames = baseInfo.Names.Trim().Length > 0;
        var typedAnything = typedNames || typedProfile.Length > 0 || baseInfo.Topic.Trim().Length > 0;

        var result = calendarEvent is null ? baseInfo : CalendarMatch.Fill(baseInfo, calendarEvent, projects);
        if (typedProfile.Length > 0) result.Profile = typedProfile; // chosen during the call: not the calendar's to change
        var fromCalendar = typedProfile.Length == 0 ? result.Profile : "";

        if (!typedNames)
        {
            var names = Split(result.Names);
            foreach (var voice in heard.Where(v => !v.Unsure))
                if (!names.Any(n => Same(n, voice.Name))) names.Add(voice.Name);
            result.Names = string.Join(", ", names);
        }

        var voiced = VoicedProject(heard, projects);
        if (result.Profile.Length == 0 && !typedAnything && voiced is not null) result.Profile = voiced;

        var conflict = fromCalendar.Length > 0 && voiced is not null && voiced != fromCalendar;
        var meetingNow = calendarEvent is not null && startedAt >= calendarEvent.Start - SureEarly && startedAt <= calendarEvent.End;
        var voiceHeard = heard.Any(v => !v.Unsure && v.Seconds >= SureSeconds);
        var sure = result.Profile.Length > 0 && projects.Any(p => p.Slug == result.Profile) && Split(result.Names).Count > 0
                   && (meetingNow || voiceHeard || typedAnything) && !conflict && !info.Reflection;
        if (result.Profile.Length == 0) result.Profile = defaultProfile; // the form's usual default
        return (result, sure);
    }

    internal static bool Same(string a, string b)
    {
        var (x, y) = (a.ToLowerInvariant(), b.ToLowerInvariant());
        return x == y || x.Split(' ')[0] == y || y.Split(' ')[0] == x;
    }

    /// <summary>The project most of the heard speech belongs to; only projects that exist.</summary>
    private static string? VoicedProject(IEnumerable<HeardVoice> heard, IReadOnlyList<Project> projects) =>
        heard.Where(v => v.Profile.Length > 0 && projects.Any(p => p.Slug == v.Profile))
             .GroupBy(v => v.Profile)
             .OrderByDescending(g => g.Sum(v => v.Seconds)).ThenBy(g => g.Key, StringComparer.Ordinal)
             .FirstOrDefault()?.Key;

    private static List<string> Split(string names) =>
        names.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).ToList();
}
